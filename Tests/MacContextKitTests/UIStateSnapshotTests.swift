import CoreGraphics
@testable import MacContextKit
import Testing

private func field(
    value: String = "A",
    title: String = "Amount",
    focused: Bool = false,
    selected: Bool = false,
    enabled: Bool = true,
    x: CGFloat = 0,
    children: [UIStateSnapshot.Node] = []
) -> UIStateSnapshot.Node {
    UIStateSnapshot.Node(
        key: "field",
        role: "textField",
        title: title,
        value: value,
        isFocused: focused,
        isSelected: selected,
        isEnabled: enabled,
        frame: CGRect(x: x, y: 0, width: 100, height: 24),
        children: children
    )
}

private func root(children: [UIStateSnapshot.Node]) -> UIStateSnapshot {
    UIStateSnapshot(root: UIStateSnapshot.Node(key: "root", role: "window", title: "Main", children: children))
}

@Test
func snapshotComputesStableMerkleAndChildHashes() {
    let first = root(children: [field(value: "A")])
    let same = root(children: [field(value: "A")])
    let changed = root(children: [field(value: "B")])

    #expect(first.rootHash == same.rootHash)
    #expect(first.root.childHashes == same.root.childHashes)
    #expect(first.rootHash != changed.rootHash)
    #expect(first.root.childHashes != changed.root.childHashes)
}

@Test
func deltaDetectsValueFocusAndSelectionChanges() {
    let before = root(children: [field(value: "A")])
    let after = root(children: [field(value: "B", focused: true, selected: true)])
    let delta = UIStateDelta.between(before, after)

    #expect(delta.contains(.value, key: "field"))
    #expect(delta.contains(.focus, key: "field"))
    #expect(delta.contains(.selection, key: "field"))
    #expect(delta.changes.count == 3)
}

@Test
func deltaDetectsMoveAndRenameChanges() {
    let before = root(children: [field(title: "Amount", x: 0)])
    let after = root(children: [field(title: "Total", x: 80)])
    let delta = UIStateDelta.between(before, after)

    #expect(delta.contains(.rename, key: "field"))
    #expect(delta.contains(.move, key: "field"))
    #expect(delta.changes.count == 2)
}

@Test
func deltaDetectsInsertAndRemoveChanges() {
    let before = root(children: [
        UIStateSnapshot.Node(key: "old", role: "button", title: "Remove"),
        UIStateSnapshot.Node(key: "kept", role: "button", title: "Keep")
    ])
    let after = root(children: [
        UIStateSnapshot.Node(key: "kept", role: "button", title: "Keep"),
        UIStateSnapshot.Node(key: "new", role: "button", title: "Add")
    ])
    let delta = UIStateDelta.between(before, after)

    #expect(delta.contains(.remove, key: "old"))
    #expect(delta.contains(.insert, key: "new"))
    #expect(!delta.contains(.remove, key: "kept"))
    #expect(!delta.contains(.insert, key: "kept"))
}

@Test
func axStableKeyPrefersIdentifierThenTitleThenPathFrameBucket() {
    let identified = UIStateSnapshot.snapshot(fromAXNodes: [
        UIStateSnapshot.AXNodeInput(identifier: "primary.save", role: "AXButton", title: "Save")
    ])!
    let titled = UIStateSnapshot.snapshot(fromAXNodes: [
        UIStateSnapshot.AXNodeInput(role: "AXButton", title: " Save\nNow ")
    ], rootKey: "AXWindow:Main")!
    let bucket = UIStateSnapshot.FrameBucket(CGRect(x: 9, y: 17, width: 101, height: 33))
    let fallback = UIStateSnapshot.stableKey(
        identifier: nil,
        role: "AXButton",
        title: nil,
        containerKey: nil,
        treePath: "0/2",
        frameBucket: bucket
    )

    #expect(identified.root.key == "id|primary.save")
    #expect(titled.root.key == "label|axbutton|save now|axwindow:main")
    #expect(fallback == "path|axbutton|0/2|1,2,13,4")
}

@Test
func axBuilderRespectsNodeAndDepthLimits() {
    let snapshot = UIStateSnapshot.snapshot(fromAXNodes: [
        UIStateSnapshot.AXNodeInput(
            role: "AXWindow",
            title: "Main",
            children: [
                UIStateSnapshot.AXNodeInput(role: "AXButton", title: "One", children: [
                    UIStateSnapshot.AXNodeInput(role: "AXStaticText", title: "Grandchild")
                ]),
                UIStateSnapshot.AXNodeInput(role: "AXButton", title: "Two")
            ])
    ], options: UIStateSnapshot.AXBuildOptions(nodeLimit: 2, maxDepth: 1))!

    #expect(snapshot.root.children.count == 1)
    #expect(snapshot.root.children[0].children.isEmpty)
}

@Test
func deltaMeaningfulSummaryHashesKeysWithoutRawLabels() {
    let before = root(children: [UIStateSnapshot.Node(key: "secret payroll approve button", role: "button", title: "Approve")])
    let after = root(children: [UIStateSnapshot.Node(key: "secret payroll approve button", role: "button", title: "Approved")])
    let delta = UIStateDelta.between(before, after)
    let summary = delta.privacySafeSummary

    #expect(delta.hasMeaningfulChange)
    #expect(summary.contains("rename=1"))
    #expect(!summary.contains("secret payroll"))
    #expect(!summary.contains("approve button"))
}
