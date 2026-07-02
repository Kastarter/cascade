import CoreGraphics
import Foundation
import Testing

@testable import ProviderKit

private func group(_ id: String, _ action: CUAction, tool: String = "computer") -> CUActionGroup {
    CUActionGroup(
        toolUseID: id,
        toolName: tool,
        kindToken: "\(tool).\(ComputerUseAgent.actionKindToken(action))",
        actions: [action]
    )
}

struct ActionChunkingTests {
    @Test func safeClickKeyTypeReturnChainIsAccepted() {
        let groups = [
            group("a", .click(x: 10, y: 20)),
            group("b", .key("cmd+a")),
            group("c", .type("Quarterly plan")),
            group("d", .key("return")),
        ]

        let plan = ComputerUseAgent.actionChunkPlan(for: groups)

        #expect(plan.groups == groups)
        #expect(plan.deferredToolUseIDs.isEmpty)
        #expect(plan.breakReason == nil)
        #expect(plan.actions.count == 4)
    }

    @Test func scrollAndWaitChainIsAccepted() {
        let groups = [
            group("scroll", .scroll(x: 40, y: 50, direction: "down", amount: 3)),
            group("wait", .wait, tool: "wait"),
        ]

        let plan = ComputerUseAgent.actionChunkPlan(for: groups)

        #expect(plan.groups == groups)
        #expect(plan.deferredToolUseIDs.isEmpty)
        #expect(plan.breakReason == nil)
    }

    @Test func fillFieldExpandedActionsReuseSameClassifier() {
        let actions = ComputerUseAgent.fillActions(
            at: CGPoint(x: 5, y: 6),
            text: "Invoice 12",
            double: false,
            submit: "tab"
        )
        let fill = CUActionGroup(
            toolUseID: "fill",
            toolName: "fill_field",
            kindToken: "fill_field",
            actions: actions
        )

        let plan = ComputerUseAgent.actionChunkPlan(for: [fill])

        #expect(plan.groups == [fill])
        #expect(plan.actions == actions)
        #expect(plan.breakReason == nil)
    }

    @Test func riskyTextPasteAndIrreversibleKeysBreakAndDefer() {
        let risky = ComputerUseAgent.actionChunkPlan(for: [
            group("safe", .click(x: 1, y: 1)),
            group("risky", .type("submit the wire transfer")),
        ])
        #expect(risky.groups.compactMap(\.toolUseID) == ["safe"])
        #expect(risky.deferredToolUseIDs == ["risky"])
        #expect(risky.breakReason == .riskGate)

        let paste = ComputerUseAgent.actionChunkPlan(for: [group("paste", .key("cmd+v"))])
        #expect(paste.groups.isEmpty)
        #expect(paste.deferredToolUseIDs == ["paste"])
        #expect(paste.breakReason == .pasteGate)

        let quit = ComputerUseAgent.actionChunkPlan(for: [group("quit", .key("cmd+q"))])
        #expect(quit.groups.isEmpty)
        #expect(quit.deferredToolUseIDs == ["quit"])
        #expect(quit.breakReason == .irreversibleGate)
    }

    @Test func runtimeApprovedPasteAndIrreversibleKeysRemainExecutable() {
        let paste = ComputerUseAgent.actionChunkPlan(
            for: [group("paste", .key("cmd+v"))],
            pasteKeysAllowed: true
        )
        #expect(paste.groups.compactMap(\.toolUseID) == ["paste"])
        #expect(paste.deferredToolUseIDs.isEmpty)
        #expect(paste.breakReason == nil)

        let quit = ComputerUseAgent.actionChunkPlan(
            for: [group("quit", .key("cmd+q"))],
            irreversibleKeysAllowed: true
        )
        #expect(quit.groups.compactMap(\.toolUseID) == ["quit"])
        #expect(quit.deferredToolUseIDs.isEmpty)
        #expect(quit.breakReason == nil)
    }

    @Test func nonAllowlistedActionsFallBackToOneActionThenDeferTail() {
        let front = ComputerUseAgent.actionChunkPlan(for: [
            group("open", .openURL("https://example.com/path")),
            group("click", .click(x: 1, y: 1)),
        ])
        #expect(front.groups.compactMap(\.toolUseID) == ["open"])
        #expect(front.deferredToolUseIDs == ["click"])
        #expect(front.breakReason == .nonAllowlisted)

        let tail = ComputerUseAgent.actionChunkPlan(for: [
            group("click", .click(x: 1, y: 1)),
            group("drag", .drag(fromX: 1, fromY: 1, toX: 2, toY: 2)),
            group("after", .key("return")),
        ])
        #expect(tail.groups.compactMap(\.toolUseID) == ["click"])
        #expect(tail.deferredToolUseIDs == ["drag", "after"])
        #expect(tail.breakReason == .nonAllowlisted)
    }

    @Test func groundingMissBreaksAndDefersWithoutParallelMechanism() {
        let miss = CUActionGroup(
            toolUseID: "miss",
            toolName: "click_target",
            kindToken: "click_target.miss",
            actions: [.click(x: 1, y: 1)],
            chunkEligible: false,
            breakReason: .groundingMiss
        )

        let plan = ComputerUseAgent.actionChunkPlan(for: [
            group("safe", .click(x: 3, y: 4)),
            miss,
            group("later", .key("return")),
        ])

        #expect(plan.groups.compactMap(\.toolUseID) == ["safe"])
        #expect(plan.deferredToolUseIDs == ["miss", "later"])
        #expect(plan.breakReason == .groundingMiss)
    }
}
