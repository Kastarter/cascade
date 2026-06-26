import Foundation

public enum ScreenElementIndex {
    public enum Source: String, Sendable, CaseIterable {
        case accessibility
        case visual
        case ocr

        var rank: Int {
            switch self {
            case .accessibility: 3
            case .visual: 2
            case .ocr: 1
            }
        }
    }

    public enum Role: String, Sendable, Equatable {
        case button
        case link
        case checkbox
        case textField
        case menuItem
        case option
        case text
        case image
        case container
        case unknown

        var isInteractive: Bool {
            switch self {
            case .button, .link, .checkbox, .textField, .menuItem, .option:
                true
            case .text, .image, .container, .unknown:
                false
            }
        }
    }

    public enum ClickSafety: String, Sendable, Equatable {
        case safe
        case passive
        case unsafe
    }

    public struct Bounds: Sendable, Hashable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var area: Double { max(0, width) * max(0, height) }
        public var isValid: Bool { width > 0 && height > 0 && x.isFinite && y.isFinite && width.isFinite && height.isFinite }

        func union(_ other: Bounds) -> Bounds {
            let minX = min(x, other.x)
            let minY = min(y, other.y)
            let maxX = max(self.maxX, other.maxX)
            let maxY = max(self.maxY, other.maxY)
            return Bounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        func intersectionArea(with other: Bounds) -> Double {
            let overlapWidth = max(0, min(maxX, other.maxX) - max(x, other.x))
            let overlapHeight = max(0, min(maxY, other.maxY) - max(y, other.y))
            return overlapWidth * overlapHeight
        }

        func intersectionOverUnion(with other: Bounds) -> Double {
            let intersection = intersectionArea(with: other)
            let unionArea = area + other.area - intersection
            guard unionArea > 0 else { return 0 }
            return intersection / unionArea
        }

        func containmentOverlap(with other: Bounds) -> Double {
            let smallerArea = min(area, other.area)
            guard smallerArea > 0 else { return 0 }
            return intersectionArea(with: other) / smallerArea
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let bounds: Bounds
        public let label: String
        public let role: Role
        public let source: Source
        public let confidence: Double
        public let trust: Double
        public let clickSafety: ClickSafety

        public init(
            bounds: Bounds,
            label: String,
            role: Role,
            source: Source,
            confidence: Double,
            trust: Double? = nil,
            clickSafety: ClickSafety? = nil
        ) {
            self.bounds = bounds
            self.label = label
            self.role = role
            self.source = source
            self.confidence = confidence.clampedToUnit
            self.trust = (trust ?? source.defaultTrust).clampedToUnit
            self.clickSafety = clickSafety ?? (role.isInteractive ? .safe : .passive)
        }
    }

    public struct SetOfMark: Sendable, Equatable {
        public let number: Int
        public let label: String
        public let isSafeToClick: Bool

        public init(number: Int, label: String, isSafeToClick: Bool) {
            self.number = number
            self.label = label
            self.isSafeToClick = isSafeToClick
        }
    }

    public struct IndexedCandidate: Sendable, Equatable {
        public let id: String
        public let bounds: Bounds
        public let label: String
        public let role: Role
        public let source: Source
        public let confidence: Double
        public let trust: Double
        public let clickSafety: ClickSafety
        public let contributingSources: [Source]
        public let mark: SetOfMark

        public var isSafeToClick: Bool {
            clickSafety == .safe && role.isInteractive
        }

        public init(
            id: String,
            bounds: Bounds,
            label: String,
            role: Role,
            source: Source,
            confidence: Double,
            trust: Double,
            clickSafety: ClickSafety,
            contributingSources: [Source],
            mark: SetOfMark
        ) {
            self.id = id
            self.bounds = bounds
            self.label = label
            self.role = role
            self.source = source
            self.confidence = confidence
            self.trust = trust
            self.clickSafety = clickSafety
            self.contributingSources = contributingSources
            self.mark = mark
        }

        fileprivate func withMark(_ mark: SetOfMark) -> IndexedCandidate {
            IndexedCandidate(
                id: id,
                bounds: bounds,
                label: label,
                role: role,
                source: source,
                confidence: confidence,
                trust: trust,
                clickSafety: clickSafety,
                contributingSources: contributingSources,
                mark: mark)
        }
    }

    public struct Configuration: Sendable, Equatable {
        public let overlapThreshold: Double
        public let containmentThreshold: Double
        public let rowTolerance: Double

        public init(
            overlapThreshold: Double = 0.55,
            containmentThreshold: Double = 0.80,
            rowTolerance: Double = 12
        ) {
            self.overlapThreshold = overlapThreshold
            self.containmentThreshold = containmentThreshold
            self.rowTolerance = rowTolerance
        }

        public static let `default` = Configuration()
    }

    public static func build(
        from candidates: [Candidate],
        configuration: Configuration = .default
    ) -> [IndexedCandidate] {
        let validCandidates = candidates.filter { $0.bounds.isValid }
        guard !validCandidates.isEmpty else { return [] }

        let clusters = cluster(validCandidates, configuration: configuration)
        let indexed = clusters.map { merge(cluster: $0) }
            .sorted { readingOrderPrecedes($0, $1, rowTolerance: configuration.rowTolerance) }

        return indexed.enumerated().map { offset, candidate in
            let mark = SetOfMark(
                number: offset + 1,
                label: String(offset + 1),
                isSafeToClick: candidate.isSafeToClick)
            return candidate.withMark(mark)
        }
    }
}

private extension ScreenElementIndex {
    static func cluster(
        _ candidates: [Candidate],
        configuration: Configuration
    ) -> [[Candidate]] {
        let ordered = candidates.sorted(by: candidateSortPrecedes)
        var parent = Array(0..<ordered.count)

        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }

        func union(_ left: Int, _ right: Int) {
            let leftRoot = root(left)
            let rightRoot = root(right)
            guard leftRoot != rightRoot else { return }
            parent[max(leftRoot, rightRoot)] = min(leftRoot, rightRoot)
        }

        for left in ordered.indices {
            for right in ordered.indices where right > left {
                if shouldMerge(ordered[left], ordered[right], configuration: configuration) {
                    union(left, right)
                }
            }
        }

        var grouped: [Int: [Candidate]] = [:]
        for index in ordered.indices {
            grouped[root(index), default: []].append(ordered[index])
        }

        return grouped.values
            .map { $0.sorted(by: candidateSortPrecedes) }
            .sorted { candidateSortPrecedes($0[0], $1[0]) }
    }

    static func shouldMerge(
        _ left: Candidate,
        _ right: Candidate,
        configuration: Configuration
    ) -> Bool {
        let hasOverlap = left.bounds.intersectionOverUnion(with: right.bounds) >= configuration.overlapThreshold
            || left.bounds.containmentOverlap(with: right.bounds) >= configuration.containmentThreshold
        guard hasOverlap else { return false }
        guard labelsCompatible(left.label, right.label) else { return false }
        return rolesCompatible(left.role, right.role)
    }

    static func labelsCompatible(_ left: String, _ right: String) -> Bool {
        let lhs = normalizedLabel(left)
        let rhs = normalizedLabel(right)
        if lhs.isEmpty || rhs.isEmpty { return true }
        if lhs == rhs { return true }
        guard min(lhs.count, rhs.count) >= 4 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    static func rolesCompatible(_ left: Role, _ right: Role) -> Bool {
        if left == right || left == .unknown || right == .unknown {
            return true
        }
        if left == .text || right == .text {
            return true
        }
        return false
    }

    static func merge(cluster: [Candidate]) -> IndexedCandidate {
        let ordered = cluster.sorted(by: candidateSortPrecedes)
        let primary = ordered.max(by: candidateQualityPrecedes) ?? ordered[0]
        let bounds = ordered.dropFirst().reduce(ordered[0].bounds) { partial, candidate in
            partial.union(candidate.bounds)
        }
        let label = bestLabel(in: ordered, fallback: primary.label)
        let confidence = ordered.map(\.confidence).max() ?? primary.confidence
        let trust = ordered.map(\.trust).max() ?? primary.trust
        let clickSafety: ClickSafety = ordered.contains { $0.clickSafety == .unsafe } ? .unsafe : primary.clickSafety
        let sources = Array(Set(ordered.map(\.source))).sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return $0.rawValue < $1.rawValue
        }
        let id = stableID(bounds: bounds, label: label, role: primary.role)

        return IndexedCandidate(
            id: id,
            bounds: bounds,
            label: label,
            role: primary.role,
            source: primary.source,
            confidence: confidence,
            trust: trust,
            clickSafety: clickSafety,
            contributingSources: sources,
            mark: SetOfMark(number: 0, label: "", isSafeToClick: false))
    }

    static func bestLabel(in candidates: [Candidate], fallback: String) -> String {
        candidates
            .filter { !normalizedLabel($0.label).isEmpty }
            .max {
                if $0.trust != $1.trust { return $0.trust < $1.trust }
                if $0.confidence != $1.confidence { return $0.confidence < $1.confidence }
                if $0.source.rank != $1.source.rank { return $0.source.rank < $1.source.rank }
                return $0.label.count < $1.label.count
            }?
            .label ?? fallback
    }

    static func candidateSortPrecedes(_ left: Candidate, _ right: Candidate) -> Bool {
        let leftKey = candidateStableKey(left)
        let rightKey = candidateStableKey(right)
        return leftKey < rightKey
    }

    static func candidateQualityPrecedes(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.trust != right.trust { return left.trust < right.trust }
        if left.confidence != right.confidence { return left.confidence < right.confidence }
        if left.source.rank != right.source.rank { return left.source.rank < right.source.rank }
        if left.role.isInteractive != right.role.isInteractive { return !left.role.isInteractive && right.role.isInteractive }
        return candidateStableKey(left) > candidateStableKey(right)
    }

    static func readingOrderPrecedes(
        _ left: IndexedCandidate,
        _ right: IndexedCandidate,
        rowTolerance: Double
    ) -> Bool {
        if abs(left.bounds.y - right.bounds.y) > rowTolerance {
            return left.bounds.y < right.bounds.y
        }
        if left.bounds.x != right.bounds.x {
            return left.bounds.x < right.bounds.x
        }
        return left.id < right.id
    }

    static func stableID(bounds: Bounds, label: String, role: Role) -> String {
        let key = [
            normalizedLabel(label),
            role.rawValue,
            String(quantized(bounds.x)),
            String(quantized(bounds.y)),
            String(quantized(bounds.width)),
            String(quantized(bounds.height)),
        ].joined(separator: "|")
        return "se_\(fnv1a64(key))"
    }

    static func candidateStableKey(_ candidate: Candidate) -> String {
        [
            normalizedLabel(candidate.label),
            candidate.role.rawValue,
            String(quantized(candidate.bounds.x)),
            String(quantized(candidate.bounds.y)),
            String(quantized(candidate.bounds.width)),
            String(quantized(candidate.bounds.height)),
            candidate.source.rawValue,
            String(quantized(candidate.confidence * 1_000)),
            String(quantized(candidate.trust * 1_000)),
        ].joined(separator: "|")
    }

    static func normalizedLabel(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func quantized(_ value: Double) -> Int {
        Int(value.rounded())
    }

    static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 36)
    }
}

private extension ScreenElementIndex.Source {
    var defaultTrust: Double {
        switch self {
        case .accessibility: 0.95
        case .visual: 0.70
        case .ocr: 0.55
        }
    }
}

private extension Double {
    var clampedToUnit: Double {
        min(1, max(0, self))
    }
}
