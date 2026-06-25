import Foundation
import Testing

@testable import ProviderKit

/// Pins GroqClient's pure request-shaping and response-parsing — the OpenAI-
/// compatible seam that routes text components (planner, validators) to a Groq
/// model. Live calls are runtime-unverified (need a Groq key + network); these
/// guard the wire shape. See [[cascade-cu-downgrade-research]].
struct GroqClientTests {
    @Test func requestBodyOrdersSystemThenUser() {
        let body = GroqClient.requestBody(model: GroqModel.llama33_70b, system: "be terse", user: "hi", maxTokens: 256)
        #expect(body["model"] as? String == "llama-3.3-70b-versatile")
        #expect(body["max_tokens"] as? Int == 256)
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[0]["content"] == "be terse")
        #expect(messages?[1]["role"] == "user")
        #expect(messages?[1]["content"] == "hi")
    }

    @Test func requestBodyOmitsEmptySystem() {
        let nilSystem = GroqClient.requestBody(model: "m", system: nil, user: "u", maxTokens: 8)
        #expect((nilSystem["messages"] as? [[String: String]])?.count == 1)
        let emptySystem = GroqClient.requestBody(model: "m", system: "", user: "u", maxTokens: 8)
        #expect((emptySystem["messages"] as? [[String: String]])?.first?["role"] == "user")
    }

    @Test func parsesChoiceContent() {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"  VERIFIED  "}}]}"#
        #expect(GroqClient.parseContent(Data(json.utf8)) == "VERIFIED")
    }

    @Test func parsesArrayContent() {
        let json = #"{"choices":[{"message":{"content":[{"type":"text","text":"step one"}]}}]}"#
        #expect(GroqClient.parseContent(Data(json.utf8)) == "step one")
    }

    @Test func missingChoicesIsNil() {
        #expect(GroqClient.parseContent(Data(#"{"error":{"message":"bad key"}}"#.utf8)) == nil)
    }

    @Test func errorMessageReadsGroqEnvelope() {
        let msg = GroqClient.errorMessage(from: Data(#"{"error":{"message":"rate limited"}}"#.utf8), status: 429)
        #expect(msg == "rate limited")
    }

    @Test func plannerModelResolvesSmarterBrainsAndDefaultsToScout() {
        // A smarter planner than Scout, selectable via `cascade.scoutModel`.
        #expect(GroqModel.plannerModel(for: "maverick") == GroqModel.llama4Maverick)
        #expect(GroqModel.plannerModel(for: "Maverick") == GroqModel.llama4Maverick)
        #expect(GroqModel.plannerModel(for: "qwen3-32b") == GroqModel.qwen3_32b)
        #expect(GroqModel.plannerModel(for: "qwen") == GroqModel.qwen3_32b)
        #expect(GroqModel.plannerModel(for: "scout") == GroqModel.llama4Scout)
        // Unknown / unset → the proven Scout default, so a typo can't break a run.
        #expect(GroqModel.plannerModel(for: nil) == GroqModel.llama4Scout)
        #expect(GroqModel.plannerModel(for: "gpt-9") == GroqModel.llama4Scout)
    }
}
