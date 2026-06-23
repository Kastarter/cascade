import Foundation
import Testing

@testable import ProviderKit

/// Pins GroqVisionClient's multimodal request shape — the perception channel for
/// the Scout thinker. Live calls are runtime-unverified (need a Groq key +
/// network). See [[cascade-cu-downgrade-research]].
struct GroqVisionClientTests {
    private let jpeg = Data([0xFF, 0xD8, 0x01, 0x02])

    @Test func bodyEndsWithUserTurnCarryingTextThenImage() {
        let body = GroqVisionClient.requestBody(
            model: GroqModel.llama4Scout, system: "drive the screen", user: "Goal: open Safari",
            imageJPEG: jpeg, maxTokens: 600
        )
        #expect(body["model"] as? String == GroqModel.llama4Scout)
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system")
        let last = messages?.last
        #expect(last?["role"] as? String == "user")
        let content = last?["content"] as? [[String: Any]]
        // Instruction text BEFORE the image (better grounding).
        #expect(content?.first?["type"] as? String == "text")
        #expect(content?.last?["type"] as? String == "image_url")
        let url = (content?.last?["image_url"] as? [String: Any])?["url"] as? String
        #expect(url?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func priorTurnsReplayAsTextBeforeCurrentFrame() {
        let body = GroqVisionClient.requestBody(
            model: "m", system: nil, user: "next", imageJPEG: jpeg, maxTokens: 8,
            prior: [(user: "Goal: x", assistant: "click → Save")]
        )
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.count == 3)  // prior user, prior assistant, current user
        #expect(messages?[0]["content"] as? String == "Goal: x")
        #expect(messages?[1]["role"] as? String == "assistant")
        #expect((messages?[2]["content"] as? [[String: Any]])?.count == 2)
    }
}
