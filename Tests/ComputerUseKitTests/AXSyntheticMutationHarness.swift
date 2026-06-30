import CascadeMemory
import CoreGraphics
import Foundation

@testable import ComputerUseKit

struct AXSyntheticNode: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var role: String
    var identifier: String?
    var frame: CGRect
    var children: [AXSyntheticNode]

    init(
        id: String,
        label: String,
        role: String = "AXButton",
        identifier: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 80, height: 28),
        children: [AXSyntheticNode] = []
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.identifier = identifier
        self.frame = frame
        self.children = children
    }

    func candidates(ancestorPath: [String] = []) -> [AXElementResolver.Candidate] {
        let container = ancestorPath.last
        let descriptor = AXTargetDescriptorV2(
            label: label,
            role: role,
            identifier: identifier,
            container: container,
            ancestorPath: ancestorPath,
            siblingRoleIndex: 0,
            frameBucket: frameBucket(frame),
            frame: frameString(frame),
            pathHash: AuditIdentity.hash((ancestorPath + [role, label]).joined(separator: "|")),
            subtreeHash: AuditIdentity.hash("\(role)|\(label)|\(children.count)"),
            semanticTextHash: AXTargetDescriptorV2.semanticTextHash(for: AXTargetDescriptorV2.semanticPhrase(
                label: label,
                role: role,
                container: container,
                ancestorPath: ancestorPath,
                neighborLabels: [],
                windowTitle: nil
            )),
            createdFrom: "synthetic"
        )
        let selfCandidate = AXElementResolver.Candidate(
            id: id,
            descriptor: descriptor,
            center: CGPoint(x: frame.midX, y: frame.midY),
            frame: frame,
            source: .synthetic
        )
        let childPath = ancestorPath + [AXTargetDescriptor.container(role: role, title: label) ?? role]
        return [selfCandidate] + children.flatMap { $0.candidates(ancestorPath: childPath) }
    }
}

enum AXSyntheticMutationHarness {
    static func move(_ node: AXSyntheticNode, by delta: CGVector) -> AXSyntheticNode {
        var copy = node
        copy.frame = copy.frame.offsetBy(dx: delta.dx, dy: delta.dy)
        return copy
    }

    static func rename(_ node: AXSyntheticNode, to label: String) -> AXSyntheticNode {
        var copy = node
        copy.label = label
        return copy
    }

    static func removeIdentifier(_ node: AXSyntheticNode) -> AXSyntheticNode {
        var copy = node
        copy.identifier = nil
        return copy
    }

    static func reorderSiblings(_ node: AXSyntheticNode) -> AXSyntheticNode {
        var copy = node
        copy.children.reverse()
        return copy
    }

    static func retitleParent(_ node: AXSyntheticNode, to label: String) -> AXSyntheticNode {
        rename(node, to: label)
    }

    static func duplicateLabel(_ node: AXSyntheticNode, duplicate: AXSyntheticNode) -> AXSyntheticNode {
        var copy = node
        copy.children.append(duplicate)
        return copy
    }

    static func localize(_ node: AXSyntheticNode, to label: String) -> AXSyntheticNode {
        rename(node, to: label)
    }
}

private func frameBucket(_ frame: CGRect) -> String {
    [
        Int((frame.minX / 20).rounded()),
        Int((frame.minY / 20).rounded()),
        Int((frame.width / 20).rounded()),
        Int((frame.height / 20).rounded()),
    ].map(String.init).joined(separator: ",")
}

private func frameString(_ frame: CGRect) -> String {
    [
        Int(frame.minX.rounded()),
        Int(frame.minY.rounded()),
        Int(frame.width.rounded()),
        Int(frame.height.rounded()),
    ].map(String.init).joined(separator: ",")
}
