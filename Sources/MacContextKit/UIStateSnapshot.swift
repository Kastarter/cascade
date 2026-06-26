import CoreGraphics
import Foundation

/// AX/DOM-agnostic semantic state for a UI tree.
///
/// The node stores deterministic hashes for potentially sensitive labels and
/// values, plus bucketed geometry and child Merkle hashes so no-effect checks
/// can reason about structure before falling back to pixels.
public struct UIStateSnapshot: Sendable, Equatable {
    public let root: Node
    public let rootHash: UInt64

    public init(root: Node) {
        self.root = root
        self.rootHash = root.merkleHash
    }

    public struct Node: Sendable, Equatable {
        public let key: String
        public let roleHash: UInt64
        public let titleHash: UInt64
        public let valueHash: UInt64
        public let isFocused: Bool
        public let isSelected: Bool
        public let isEnabled: Bool
        public let frameBucket: FrameBucket
        public let children: [Node]
        public let childHashes: [UInt64]
        public let merkleHash: UInt64

        public init(
            key: String,
            role: String? = nil,
            title: String? = nil,
            value: String? = nil,
            isFocused: Bool = false,
            isSelected: Bool = false,
            isEnabled: Bool = true,
            frame: CGRect = .zero,
            frameBucketSize: CGFloat = 8,
            children: [Node] = []
        ) {
            self.key = key
            self.roleHash = StableHash.string(role)
            self.titleHash = StableHash.string(title)
            self.valueHash = StableHash.string(value)
            self.isFocused = isFocused
            self.isSelected = isSelected
            self.isEnabled = isEnabled
            self.frameBucket = FrameBucket(frame, bucketSize: frameBucketSize)
            self.children = children
            self.childHashes = children.map(\.merkleHash)
            self.merkleHash = StableHash.combine([
                StableHash.string(key),
                roleHash,
                titleHash,
                valueHash,
                StableHash.bool(isFocused),
                StableHash.bool(isSelected),
                StableHash.bool(isEnabled),
                frameBucket.hashValue,
                StableHash.combine(childHashes)
            ])
        }
    }

    public struct FrameBucket: Sendable, Equatable, Hashable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public init(_ frame: CGRect, bucketSize: CGFloat = 8) {
            let divisor = bucketSize.isFinite && bucketSize > 0 ? bucketSize : 1
            self.init(
                x: Self.bucket(frame.origin.x, divisor),
                y: Self.bucket(frame.origin.y, divisor),
                width: Self.bucket(frame.size.width, divisor),
                height: Self.bucket(frame.size.height, divisor)
            )
        }

        public var hashValue: UInt64 {
            StableHash.combine([
                StableHash.int(x),
                StableHash.int(y),
                StableHash.int(width),
                StableHash.int(height)
            ])
        }

        private static func bucket(_ value: CGFloat, _ divisor: CGFloat) -> Int {
            guard value.isFinite else { return 0 }

            let rounded = (value / divisor).rounded(.toNearestOrAwayFromZero)
            guard rounded.isFinite else { return 0 }

            let lowerBound = CGFloat(Int.min)
            let upperBound = CGFloat(Int.max)
            if rounded <= lowerBound {
                return Int.min
            }
            if rounded >= upperBound {
                return Int.max
            }

            return Int(rounded)
        }
    }
}

public struct UIStateDelta: Sendable, Equatable {
    public enum ChangeKind: String, Sendable, Equatable {
        case insert
        case remove
        case value
        case focus
        case selection
        case move
        case rename
        case enabled
    }

    public struct Change: Sendable, Equatable {
        public let kind: ChangeKind
        public let key: String
        public let beforeHash: UInt64?
        public let afterHash: UInt64?
        public let beforeFrame: UIStateSnapshot.FrameBucket?
        public let afterFrame: UIStateSnapshot.FrameBucket?
        public let beforeFlag: Bool?
        public let afterFlag: Bool?

        public init(
            kind: ChangeKind,
            key: String,
            beforeHash: UInt64? = nil,
            afterHash: UInt64? = nil,
            beforeFrame: UIStateSnapshot.FrameBucket? = nil,
            afterFrame: UIStateSnapshot.FrameBucket? = nil,
            beforeFlag: Bool? = nil,
            afterFlag: Bool? = nil
        ) {
            self.kind = kind
            self.key = key
            self.beforeHash = beforeHash
            self.afterHash = afterHash
            self.beforeFrame = beforeFrame
            self.afterFrame = afterFrame
            self.beforeFlag = beforeFlag
            self.afterFlag = afterFlag
        }
    }

    public let changes: [Change]
    public var isEmpty: Bool { changes.isEmpty }

    public init(changes: [Change]) {
        self.changes = changes
    }

    public static func between(_ before: UIStateSnapshot, _ after: UIStateSnapshot) -> UIStateDelta {
        let beforeNodes = before.root.flattenedByKey()
        let afterNodes = after.root.flattenedByKey()
        let beforeKeys = Set(beforeNodes.keys)
        let afterKeys = Set(afterNodes.keys)
        let sharedKeys = beforeKeys.intersection(afterKeys).sorted()

        var changes: [Change] = []
        for key in beforeKeys.subtracting(afterKeys).sorted() {
            changes.append(Change(kind: .remove, key: key, beforeHash: beforeNodes[key]?.merkleHash))
        }
        for key in afterKeys.subtracting(beforeKeys).sorted() {
            changes.append(Change(kind: .insert, key: key, afterHash: afterNodes[key]?.merkleHash))
        }
        for key in sharedKeys {
            guard let beforeNode = beforeNodes[key], let afterNode = afterNodes[key] else { continue }
            changes.append(contentsOf: classifyChanges(key: key, before: beforeNode, after: afterNode))
        }
        return UIStateDelta(changes: changes)
    }

    public func contains(_ kind: ChangeKind, key: String) -> Bool {
        changes.contains { $0.kind == kind && $0.key == key }
    }

    private static func classifyChanges(
        key: String,
        before: UIStateSnapshot.Node,
        after: UIStateSnapshot.Node
    ) -> [Change] {
        var changes: [Change] = []
        if before.valueHash != after.valueHash {
            changes.append(Change(kind: .value, key: key, beforeHash: before.valueHash, afterHash: after.valueHash))
        }
        if before.titleHash != after.titleHash {
            changes.append(Change(kind: .rename, key: key, beforeHash: before.titleHash, afterHash: after.titleHash))
        }
        if before.isFocused != after.isFocused {
            changes.append(Change(kind: .focus, key: key, beforeFlag: before.isFocused, afterFlag: after.isFocused))
        }
        if before.isSelected != after.isSelected {
            changes.append(Change(kind: .selection, key: key, beforeFlag: before.isSelected, afterFlag: after.isSelected))
        }
        if before.isEnabled != after.isEnabled {
            changes.append(Change(kind: .enabled, key: key, beforeFlag: before.isEnabled, afterFlag: after.isEnabled))
        }
        if before.frameBucket != after.frameBucket {
            changes.append(Change(kind: .move, key: key, beforeFrame: before.frameBucket, afterFrame: after.frameBucket))
        }
        return changes
    }
}

private extension UIStateSnapshot.Node {
    func flattenedByKey() -> [String: UIStateSnapshot.Node] {
        var result: [String: UIStateSnapshot.Node] = [key: self]
        for child in children {
            result.merge(child.flattenedByKey()) { _, new in new }
        }
        return result
    }
}

private enum StableHash {
    private static let offset: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3

    static func string(_ text: String?) -> UInt64 {
        guard let text else { return combine([0x9e3779b97f4a7c15]) }
        var hash = offset
        hash = append(0x01, to: hash)
        for byte in text.utf8 {
            hash = append(byte, to: hash)
        }
        return hash
    }

    static func bool(_ value: Bool) -> UInt64 {
        value ? 0x6eed0e9da4d94a4f : 0x207a6f0f6d421f5d
    }

    static func int(_ value: Int) -> UInt64 {
        var bits = UInt64(bitPattern: Int64(value))
        var hash = offset
        for _ in 0..<8 {
            hash = append(UInt8(truncatingIfNeeded: bits), to: hash)
            bits >>= 8
        }
        return hash
    }

    static func combine(_ values: [UInt64]) -> UInt64 {
        var hash = offset
        for value in values {
            var bits = value
            for _ in 0..<8 {
                hash = append(UInt8(truncatingIfNeeded: bits), to: hash)
                bits >>= 8
            }
        }
        return hash
    }

    private static func append(_ byte: UInt8, to hash: UInt64) -> UInt64 {
        (hash ^ UInt64(byte)) &* prime
    }
}
