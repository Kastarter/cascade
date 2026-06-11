import Foundation
import Testing

@testable import ProviderKit

/// Pins the SSE block reassembly: streamed content must come out byte-shaped
/// like the non-streaming API's blocks, because it goes straight back into the
/// message history (and thinking blocks must replay with their signature).
struct StreamReassemblyTests {
    @Test func reassemblesToolUseInputFromPartialJSON() {
        var block = ComputerUseAgent.OpenBlock(
            header: ["type": "tool_use", "id": "tu_1", "name": "computer", "input": [String: Any]()]
        )
        // input_json_delta arrives as arbitrary string fragments.
        block.json = "{\"action\":\"left_cl"
        block.json += "ick\",\"coordinate\":[12,34]}"
        let out = ComputerUseAgent.finishedBlock(block)
        #expect(out["type"] as? String == "tool_use")
        #expect(out["id"] as? String == "tu_1")
        let input = out["input"] as? [String: Any]
        #expect(input?["action"] as? String == "left_click")
        #expect((input?["coordinate"] as? [NSNumber])?.count == 2)
    }

    @Test func emptyToolInputBecomesEmptyObject() {
        // A no-argument tool call streams zero input_json_delta events — the
        // placeholder from content_block_start must not survive as-is.
        let block = ComputerUseAgent.OpenBlock(
            header: ["type": "tool_use", "id": "tu_2", "name": "computer", "input": [String: Any]()]
        )
        let out = ComputerUseAgent.finishedBlock(block)
        #expect((out["input"] as? [String: Any])?.isEmpty == true)
    }

    @Test func thinkingKeepsSignatureForReplay() {
        var block = ComputerUseAgent.OpenBlock(header: ["type": "thinking"])
        block.text = "planning the click"
        block.signature = "sig123"
        let out = ComputerUseAgent.finishedBlock(block)
        #expect(out["type"] as? String == "thinking")
        #expect(out["thinking"] as? String == "planning the click")
        #expect(out["signature"] as? String == "sig123")
    }

    @Test func textBlockUsesAccumulatedDeltas() {
        var block = ComputerUseAgent.OpenBlock(header: ["type": "text", "text": ""])
        block.text = "opening the reply"
        let out = ComputerUseAgent.finishedBlock(block)
        #expect(out["text"] as? String == "opening the reply")
    }

    @Test func unknownBlockTypesPassThrough() {
        let block = ComputerUseAgent.OpenBlock(
            header: ["type": "redacted_thinking", "data": "opaque"]
        )
        let out = ComputerUseAgent.finishedBlock(block)
        #expect(out["type"] as? String == "redacted_thinking")
        #expect(out["data"] as? String == "opaque")
    }
}
