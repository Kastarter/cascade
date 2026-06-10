import Foundation
import Testing
@testable import ProviderKit

private func imageBlock() -> [String: Any] {
    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "abc"]]
}

private func toolResultTurn(note: String) -> [String: Any] {
    [
        "role": "user",
        "content": [[
            "type": "tool_result",
            "tool_use_id": "tool-1",
            "content": [["type": "text", "text": note], imageBlock()]
        ] as [String: Any]]
    ]
}

private func firstTurn() -> [String: Any] {
    [
        "role": "user",
        "content": [
            ["type": "text", "text": "Task: scale the cube"],
            ["type": "text", "text": "App skill: blender — instructions"],
            imageBlock()
        ] as [[String: Any]]
    ]
}

private func innerBlocks(of message: [String: Any]) -> [[String: Any]] {
    guard let content = message["content"] as? [[String: Any]],
          let first = content.first else { return [] }
    if first["type"] as? String == "tool_result" {
        return first["content"] as? [[String: Any]] ?? []
    }
    return content
}

struct ScreenshotPruneTests {
    @Test func pruneKeepsToolResultTextBlocks() {
        let messages = [firstTurn()] + (1...3).map { toolResultTurn(note: "note \($0)") }
        let pruned = ComputerUseAgent.pruned(messages, keep: 1, threshold: 2)

        // First turn: both text blocks survive, only the image is replaced.
        let first = innerBlocks(of: pruned[0])
        #expect(first.count == 3)
        #expect(first[0]["text"] as? String == "Task: scale the cube")
        #expect(first[1]["text"] as? String == "App skill: blender — instructions")
        #expect(first[2]["type"] as? String == "text")
        #expect(first[2]["text"] as? String == "[earlier screenshot omitted]")

        // Pruned tool_result turns: the grounding note text survives.
        let second = innerBlocks(of: pruned[1])
        #expect(second.first?["text"] as? String == "note 1")
        #expect(second.last?["text"] as? String == "[earlier screenshot omitted]")
        #expect(second.allSatisfy { $0["type"] as? String == "text" })
    }

    @Test func pruneKeepsRecentScreenshotsAndIsNoOpBelowThreshold() {
        let messages = [firstTurn()] + (1...3).map { toolResultTurn(note: "note \($0)") }

        // Most recent `keep` turns keep their images.
        let pruned = ComputerUseAgent.pruned(messages, keep: 1, threshold: 2)
        #expect(innerBlocks(of: pruned[3]).last?["type"] as? String == "image")
        #expect(innerBlocks(of: pruned[2]).last?["type"] as? String == "text")

        // At or below the threshold nothing changes.
        let untouched = ComputerUseAgent.pruned(messages, keep: 1, threshold: 4)
        for (index, message) in untouched.enumerated() {
            #expect(innerBlocks(of: message).last?["type"] as? String == innerBlocks(of: messages[index]).last?["type"] as? String)
            #expect(innerBlocks(of: message).last?["type"] as? String == "image")
        }
    }
}
