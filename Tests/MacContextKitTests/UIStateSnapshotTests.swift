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
