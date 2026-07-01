import Foundation
import Testing

@testable import ProviderKit

private func snapshotImage(_ token: String) -> [String: Any] {
    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": token]]
}

private func snapshotRequestMessages() -> [[String: Any]] {
    [
        [
            "role": "user",
            "content": [
                ["type": "text", "text": "Task: fixture task"],
                ["type": "text", "text": "Runtime context:\nFixture runtime"],
                snapshotImage("first"),
            ] as [[String: Any]]
        ],
        [
            "role": "assistant",
            "content": [[
                "type": "tool_use",
                "id": "tool-1",
                "name": "computer",
                "input": ["action": "left_click", "coordinate": [10, 20]],
            ] as [String: Any]]
        ],
        [
            "role": "user",
            "content": [[
                "type": "tool_result",
                "tool_use_id": "tool-1",
                "content": [
                    ["type": "text", "text": "Frontmost app: FixtureApp\n{\"status\":\"ok\"}"],
                    snapshotImage("second"),
                ] as [[String: Any]],
            ] as [String: Any]]
        ],
    ]
}

struct ComputerUseAgentRequestSnapshotTests {
    @Test func flagsOffRequestBodyMatchesFixture() throws {
        let pruned = ComputerUseAgent.pruned(
            snapshotRequestMessages(),
            keep: 8,
            threshold: 8,
            historyCompaction: .off
        )
        let messages = ComputerUseAgent.withMovingCacheBreakpoints(pruned)
        let body = try AnthropicMessagesClient.bodyData(
            model: "snapshot-model",
            maxTokens: 128,
            system: "snapshot-system",
            messages: messages,
            tools: [],
            stream: true
        )
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/computer_use_default_request_body_flags_off.json")
        let fixture = try Data(contentsOf: fixtureURL)

        #expect(body == fixture)
    }
}
