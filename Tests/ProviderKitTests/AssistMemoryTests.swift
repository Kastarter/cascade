import Foundation
import Testing

@testable import ProviderKit

@MainActor
struct AssistMemoryTests {
    private func freshMemory() -> AssistMemory {
        let defaults = UserDefaults(suiteName: "AssistMemoryTests-\(UUID().uuidString)")!
        return AssistMemory(defaults: defaults)
    }

    @Test func remembersTurnsInOrder() {
        let memory = freshMemory()
        memory.remember(user: "highlight my WhatsApp messages", assistant: "Done — highlighted them.")
        memory.remember(user: "reply to the first one", assistant: "Replied.")
        let history = memory.historyForAPI()
        #expect(history.count == 2)
        #expect(history[0].user == "highlight my WhatsApp messages")
        #expect(history[1].assistant == "Replied.")
        #expect(memory.turns[0].provenance == .trustedUserInstruction)
        #expect(memory.turns[0].safeForControl == false)
    }

    @Test func compactsBeyondActiveLimitIntoArchive() {
        let memory = freshMemory()
        for index in 0..<(AssistMemory.activeTurnLimit + 3) {
            memory.remember(user: "question \(index)", assistant: "answer \(index)")
        }
        #expect(memory.turns.count == AssistMemory.activeTurnLimit)
        let history = memory.historyForAPI()
        // Archive rides along as one synthetic earliest exchange.
        #expect(history.count == AssistMemory.activeTurnLimit + 1)
        #expect(history[0].user == "[earlier conversation in this session]")
        #expect(history[0].assistant.contains("question 0"))
        // The oldest active turn is the first one that escaped compaction.
        #expect(history[1].user == "question 3")
    }

    @Test func failedTurnsAgeOutInsteadOfArchiving() {
        let memory = freshMemory()
        memory.remember(user: "broken ask", assistant: "I lost sight of the screen — try again.", ok: false)
        for index in 0..<AssistMemory.activeTurnLimit {
            memory.remember(user: "q\(index)", assistant: "a\(index)")
        }
        // The failed turn was pushed out of the active window and must NOT be in
        // the archive — stale failures poison future calls.
        let history = memory.historyForAPI()
        #expect(!history.contains { $0.assistant.contains("lost sight") })
        #expect(history.count == AssistMemory.activeTurnLimit)  // no archive entry created
    }

    @Test func ignoresEmptyUserText() {
        let memory = freshMemory()
        memory.remember(user: "   ", assistant: "noise")
        #expect(memory.historyForAPI().isEmpty)
    }

    @Test func pointedElementExpires() {
        let memory = freshMemory()
        memory.rememberPointed(label: "the Send button", globalPoint: CGPoint(x: 10, y: 20), at: Date(timeIntervalSinceNow: -300))
        #expect(memory.freshPointed() == nil)
        memory.rememberPointed(label: "the Send button", globalPoint: CGPoint(x: 10, y: 20))
        #expect(memory.freshPointed()?.label == "the Send button")
    }

    @Test func followUpWindowTracksLastTurn() {
        let memory = freshMemory()
        #expect(!memory.isFollowUpWindowOpen())
        memory.remember(user: "open notes", assistant: "Done.", at: Date(timeIntervalSinceNow: -1_000))
        #expect(!memory.isFollowUpWindowOpen())
        memory.remember(user: "open notes", assistant: "Done.")
        #expect(memory.isFollowUpWindowOpen())
    }

    @Test func capsOversizedTurnsSoHistoryStaysCheap() {
        let memory = freshMemory()
        memory.remember(user: String(repeating: "u", count: 1_000), assistant: String(repeating: "a", count: 2_000))
        let turn = memory.historyForAPI()[0]
        #expect(turn.user.count <= AssistMemory.userCharacterLimit + 1)      // +1 for the ellipsis
        #expect(turn.assistant.count <= AssistMemory.assistantCharacterLimit + 1)
    }

    @Test func contextMemoRendersRecentTurns() {
        let memory = freshMemory()
        memory.remember(user: "find flights", assistant: "Found three options.")
        let memo = memory.contextMemo()
        #expect(memo.contains("User: find flights"))
        #expect(memo.contains("Cascade: Found three options."))
    }

    @Test func clearWipesEverything() {
        let memory = freshMemory()
        for index in 0..<12 { memory.remember(user: "q\(index)", assistant: "a\(index)") }
        memory.rememberPointed(label: "x", globalPoint: .zero)
        memory.clear()
        #expect(memory.historyForAPI().isEmpty)
        #expect(memory.freshPointed() == nil)
    }
}
