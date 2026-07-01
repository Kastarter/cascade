import Foundation
import Testing

@testable import ProviderKit

private func historyImageBlock(_ token: String = "abc") -> [String: Any] {
    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": token]]
}

private func historyFirstTurn() -> [String: Any] {
    [
        "role": "user",
        "content": [
            ["type": "text", "text": "Task: reconcile the July close"],
            ["type": "text", "text": "Runtime context:\nSandboxed test runtime"],
            ["type": "text", "text": "Frontmost app: Numbers"],
            historyImageBlock("first"),
        ] as [[String: Any]]
    ]
}

private func historyAssistantTurn(_ index: Int) -> [String: Any] {
    [
        "role": "assistant",
        "content": [
            ["type": "text", "text": "checking row \(index)"],
            [
                "type": "tool_use",
                "id": "tool-\(index)",
                "name": "computer",
                "input": ["action": "left_click", "coordinate": [100 + index, 200 + index]],
            ] as [String: Any],
        ] as [[String: Any]]
    ]
}

private func historyResultTurn(_ index: Int) -> [String: Any] {
    let bulky = String(repeating: "bounded status payload \(index) ", count: 80)
    return [
        "role": "user",
        "content": [[
            "type": "tool_result",
            "tool_use_id": "tool-\(index)",
            "content": [
                ["type": "text", "text": "Frontmost app: Safari — Close checklist\n{\"status\":\"ok\"}\n\(bulky)"],
                historyImageBlock("img-\(index)"),
            ] as [[String: Any]],
        ] as [String: Any]]
    ]
}

private func syntheticHistory(turns: Int = 20) -> [[String: Any]] {
    var messages = [historyFirstTurn()]
    for index in 1...turns {
        messages.append(historyAssistantTurn(index))
        messages.append(historyResultTurn(index))
    }
    return messages
}

private func canonicalHistoryData(_ messages: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])
}

private func textBlocks(in message: [String: Any]) -> [String] {
    guard let content = message["content"] as? [[String: Any]] else { return [] }
    return content.compactMap { $0["text"] as? String }
}

struct HistoryCompactionTests {
    @Test func compactionShrinksOldTranscriptAndPreservesRecentTurns() throws {
        let messages = syntheticHistory()
        let current = ComputerUseAgent.pruned(messages, keep: 8, threshold: 8, historyCompaction: .off)
        let compacted = ComputerUseAgent.pruned(
            messages,
            keep: 8,
            threshold: 8,
            historyCompaction: .init(enabled: true, recentTurns: 6, imageKeep: 8)
        )

        let currentEstimate = ComputerUseAgent.estimatedHistoryTokenCount(current)
        let compactedEstimate = ComputerUseAgent.estimatedHistoryTokenCount(compacted)
        #expect(compactedEstimate < Int(Double(currentEstimate) * 0.70))

        let currentRecent = Array(current.suffix(16))
        let compactedRecent = Array(compacted.suffix(16))
        #expect(try canonicalHistoryData(currentRecent) == canonicalHistoryData(compactedRecent))
    }

    @Test func compactionPreservesFirstTurnAndImageKeepWindow() {
        let messages = syntheticHistory()
        let compacted = ComputerUseAgent.pruned(
            messages,
            keep: 8,
            threshold: 8,
            historyCompaction: .init(enabled: true, recentTurns: 6, imageKeep: 8)
        )

        let firstTexts = textBlocks(in: compacted[0])
        #expect(firstTexts.contains("Task: reconcile the July close"))
        #expect(firstTexts.contains("Runtime context:\nSandboxed test runtime"))
        #expect(firstTexts.contains("Frontmost app: Numbers"))
        #expect(ComputerUseAgent.imageTurnCount(in: compacted) == 8)
    }

    @Test func compactedOutputHasNoOrphanedToolResultsOrToolUses() {
        let compacted = ComputerUseAgent.pruned(
            syntheticHistory(),
            keep: 8,
            threshold: 8,
            historyCompaction: .init(enabled: true, recentTurns: 6, imageKeep: 8)
        )
        var toolUseIDs = Set<String>()
        var toolResultIDs = Set<String>()
        var compactSummaryCount = 0

        for message in compacted {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                    toolUseIDs.insert(id)
                }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    toolResultIDs.insert(id)
                }
                if block["type"] as? String == "text",
                   (block["text"] as? String)?.contains("\"episode_state\":\"compacted_history_turn\"") == true {
                    compactSummaryCount += 1
                }
            }
        }

        #expect(toolResultIDs.isSubset(of: toolUseIDs))
        #expect(toolUseIDs.isSubset(of: toolResultIDs))
        #expect(compactSummaryCount == 12)
    }

    @Test func cacheBreakpointsStayOnLastThreeUserTurnsAfterCompaction() {
        let compacted = ComputerUseAgent.pruned(
            syntheticHistory(),
            keep: 8,
            threshold: 8,
            historyCompaction: .init(enabled: true, recentTurns: 6, imageKeep: 8)
        )
        let marked = ComputerUseAgent.withMovingCacheBreakpoints(compacted)
        #expect(marked.map { $0["role"] as? String } == compacted.map { $0["role"] as? String })

        let userIndices = marked.indices.filter { marked[$0]["role"] as? String == "user" }
        let expected = Set(userIndices.suffix(3))
        var actual = Set<Int>()
        for index in userIndices {
            guard let content = marked[index]["content"] as? [[String: Any]],
                  let last = content.last,
                  last["cache_control"] != nil else { continue }
            actual.insert(index)
        }
        #expect(actual == expected)
    }
}
