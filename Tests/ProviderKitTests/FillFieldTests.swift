import Foundation
import Testing

@testable import ProviderKit

/// Pins `fill_field` — the on-screen agent's one-turn text-entry tool. It is the
/// structural fix for the chronic one-action-per-turn pattern: a vision-located
/// click followed by coordinate-free keys the model otherwise splits across four
/// screenshot-gated turns (the 2026-06-22 Keynote run: doubleClick → cmd+a →
/// type → cmd+return ran as four separate ~5s turns despite the skill saying
/// "all one turn"). Here it expands to ONE batch executed before the next frame.
@MainActor
struct FillFieldTests {
    @Test func expandsToClickSelectAllTypeSubmit() {
        let agent = ComputerUseAgent()
        let actions = agent.parseFillField([
            "coordinate": [100, 200], "text": "Market Entry", "click": "double", "submit": "cmd_return",
        ])
        #expect(actions?.count == 4)
        guard let actions, actions.count == 4 else { return }
        if case .doubleClick = actions[0] {} else { Issue.record("placeholder fill must double-click") }
        #expect(actions[1] == .key("cmd+a"))  // select existing content so type REPLACES
        #expect(actions[2] == .type("Market Entry"))
        #expect(actions[3] == .key("cmd+return"))  // finish editing without a newline
    }

    @Test func defaultsToSingleClickAndReturn() {
        let agent = ComputerUseAgent()
        let actions = agent.parseFillField(["coordinate": [10, 20], "text": "hi"])
        #expect(actions?.count == 4)
        guard let actions, !actions.isEmpty else { return }
        if case .click = actions[0] {} else { Issue.record("default click must be single") }
        #expect(actions.last == .key("return"))
    }

    @Test func submitNoneLeavesFocusInPlace() {
        let agent = ComputerUseAgent()
        let actions = agent.parseFillField(["coordinate": [10, 20], "text": "x", "submit": "none"])
        #expect(actions?.count == 3)  // click, cmd+a, type — no finishing key
        #expect(actions?.last == .type("x"))
    }

    @Test func tabMovesToNextField() {
        let agent = ComputerUseAgent()
        let actions = agent.parseFillField(["coordinate": [10, 20], "text": "x", "submit": "tab"])
        #expect(actions?.last == .key("tab"))
    }

    @Test func malformedCallReturnsNil() {
        let agent = ComputerUseAgent()
        #expect(agent.parseFillField(["text": "no coordinate"]) == nil)
        #expect(agent.parseFillField(["coordinate": [1, 2]]) == nil)  // no text
        #expect(agent.parseFillField(["coordinate": [1], "text": "bad"]) == nil)  // 1-element coord
    }
}
