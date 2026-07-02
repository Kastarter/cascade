import Foundation
import Testing

@testable import AppShell
@testable import ProviderKit

private func appGroup(_ id: String, _ action: CUAction) -> CUActionGroup {
    CUActionGroup(
        toolUseID: id,
        toolName: "computer",
        kindToken: ComputerUseAgent.actionKindToken(action),
        actions: [action]
    )
}

@MainActor
struct ActionChunkExecutionTests {
    @Test func stopBetweenActionsHaltsBeforeSecondAction() async {
        var executed: [CUAction] = []
        let result = await CascadeAppModel.executeActionChunkGroups(
            [
                appGroup("first", .click(x: 1, y: 1)),
                appGroup("second", .key("return")),
            ],
            shouldStop: { executed.count >= 1 },
            execute: { action in
                executed.append(action)
                return true
            },
            modalTitle: { nil }
        )

        #expect(executed.count == 1)
        #expect(result.executedToolUseIDs == Set(["first"]))
        #expect(result.breakReason == .stop)
        #expect(result.status == "stop")
    }

    @Test func modalBreakPreventsRemainingGroups() async {
        var executed = 0
        let result = await CascadeAppModel.executeActionChunkGroups(
            [
                appGroup("first", .click(x: 1, y: 1)),
                appGroup("second", .key("return")),
            ],
            shouldStop: { false },
            execute: { _ in
                executed += 1
                return true
            },
            modalTitle: { executed == 1 ? "Aperture-Delta payroll modal" : nil }
        )

        #expect(executed == 1)
        #expect(result.executedToolUseIDs == Set(["first"]))
        #expect(result.breakReason == .modal)
        #expect(result.status == "modal")
    }

    @Test func noEffectAfterGroupPreventsRemainingGroups() async {
        var executed = 0
        let result = await CascadeAppModel.executeActionChunkGroups(
            [
                appGroup("first", .click(x: 1, y: 1)),
                appGroup("second", .key("return")),
            ],
            shouldStop: { false },
            execute: { _ in
                executed += 1
                return true
            },
            modalTitle: { nil },
            noEffectAfterGroup: { completed in completed.count == 1 }
        )

        #expect(executed == 1)
        #expect(result.executedToolUseIDs == Set(["first"]))
        #expect(result.breakReason == .noEffect)
        #expect(result.status == "no_effect")
    }

    @Test func chunkAndCompactionAuditDetailsContainOnlyCountsAndHashes() {
        let rawText = "Aperture-Delta payroll seed"
        let rawURL = "https://example.com/private/payroll"
        let detail = CascadeAppModel.actionChunkAuditDetail(
            length: 3,
            groups: 2,
            kindTokens: ["type.\(rawText)", "open_url.\(rawURL)"],
            status: "modal"
        )

	        #expect(detail.contains("length=3"))
	        #expect(detail.contains("groups=2"))
	        #expect(detail.contains("kindsHash="))
	        #expect(detail.contains("status=modal"))
            #expect(detail.contains("deferred=0"))
	        #expect(!detail.contains(rawText))
	        #expect(!detail.contains(rawURL))

        let deferred = CascadeAppModel.actionChunkAuditDetail(
            length: 1,
            groups: 1,
            kindTokens: ["computer.click", "computer.open_url.\(rawURL)"],
            status: "deferred",
            deferred: 1,
            breakReason: .nonAllowlisted
        )
        #expect(deferred.contains("status=deferred"))
        #expect(deferred.contains("deferred=1"))
        #expect(deferred.contains("breakReason=nonAllowlisted"))
        #expect(!deferred.contains(rawURL))

        let compacted = CascadeAppModel.historyCompactedAuditDetail(.init(
            turns: 12,
            count: 12,
            bytesBefore: 40_000,
            bytesAfter: 8_000,
            window: 6,
            imageKeep: 8
        ))
        #expect(compacted == "turns=12 count=12 bytesBefore=40000 bytesAfter=8000 window=6 imageKeep=8")
        #expect(!compacted.contains(rawText))
    }
}
