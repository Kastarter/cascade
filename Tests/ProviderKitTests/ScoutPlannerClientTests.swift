import Foundation
import Testing

@testable import ProviderKit

/// Pins ScoutPlannerClient's request shape — the planning channel for the Scout
/// brain. Multimodal (text + image) when a screenshot is supplied (Qwen3.7 Plus
/// SEES the screen), plain text when it isn't (a text-only model like GLM-5.2).
/// Live calls are runtime-unverified (need an OpenRouter key + network). See
/// [[cascade-cu-downgrade-research]].
struct ScoutPlannerClientTests {
    private let jpeg = Data([0xFF, 0xD8, 0x01, 0x02])

    @Test func visionBodyEndsWithTextThenImage() {
        let body = ScoutPlannerClient.requestBody(
            model: ScoutModel.qwen37Plus, system: "drive the screen", user: "Goal: open Safari",
            imageJPEG: jpeg, maxTokens: 1500
        )
        #expect(body["model"] as? String == ScoutModel.qwen37Plus)
        #expect(body["temperature"] as? Int == 0)
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

    @Test func textOnlyBodyHasPlainStringUser_noImage() {
        // No image → a text-only model gets a plain string user turn, never a
        // multimodal array (which a text-only model would reject).
        let body = ScoutPlannerClient.requestBody(
            model: ScoutModel.glm5_2, system: nil, user: "Goal: open Safari",
            imageJPEG: nil, maxTokens: 1500
        )
        let last = (body["messages"] as? [[String: Any]])?.last
        #expect(last?["content"] as? String == "Goal: open Safari")
        #expect(last?["content"] as? [[String: Any]] == nil)
    }

    @Test func priorTurnsReplayAsTextBeforeCurrent() {
        let body = ScoutPlannerClient.requestBody(
            model: "m", system: nil, user: "next", imageJPEG: jpeg, maxTokens: 8,
            prior: [(user: "Goal: x", assistant: "click → Save")]
        )
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.count == 3)  // prior user, prior assistant, current user
        #expect(messages?[0]["content"] as? String == "Goal: x")
        #expect(messages?[1]["role"] as? String == "assistant")
        // The current turn is multimodal (text + image), prior turns are text.
        #expect((messages?[2]["content"] as? [[String: Any]])?.count == 2)
    }

    @Test func omitsEmptySystemMessage() {
        let nilSystem = ScoutPlannerClient.requestBody(model: "m", system: nil, user: "u", imageJPEG: nil, maxTokens: 8)
        #expect((nilSystem["messages"] as? [[String: Any]])?.count == 1)
        let emptySystem = ScoutPlannerClient.requestBody(model: "m", system: "", user: "u", imageJPEG: nil, maxTokens: 8)
        #expect((emptySystem["messages"] as? [[String: Any]])?.count == 1)
    }

    @Test func defaultScoutModelIsQwen37Plus() {
        // The default model id; the runtime override is `cascade.scout.model`.
        #expect(ScoutModel.qwen37Plus == "qwen/qwen3.7-plus")
        #expect(ScoutModel.glm5_2 == "z-ai/glm-5.2")
    }
}
