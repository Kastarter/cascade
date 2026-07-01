import Foundation
import Testing

@testable import ProviderKit

private struct CapturedCompletion: Sendable {
    let system: String?
    let user: String
    let model: String
    let maxTokens: Int
    let options: AnthropicCompletionOptions?
}

private actor CompletionCapture {
    private var storage: [CapturedCompletion] = []

    func record(_ completion: CapturedCompletion) {
        storage.append(completion)
    }

    func only() -> CapturedCompletion? {
        storage.count == 1 ? storage[0] : nil
    }
}

private struct CapturingCompleter: MessageCompleting {
    let canned: String
    let capture: CompletionCapture

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        await capture.record(CapturedCompletion(system: system, user: user, model: model, maxTokens: maxTokens, options: nil))
        return canned
    }

    func complete(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions
    ) async throws -> String {
        await capture.record(CapturedCompletion(system: system, user: user, model: model, maxTokens: maxTokens, options: options))
        return canned
    }
}

private struct CompatibilityCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        "legacy path still works"
    }
}

@Test
func purePlannerCallsCarryDeterministicOptions() async throws {
    let capture = CompletionCapture()
    let planner = ClaudeSingleStepPlanner(
        client: CapturingCompleter(
            canned: #"{"rationale":"done","confidence":1,"action":{"kind":"done","summary":"ok"}}"#,
            capture: capture
        )
    )

    _ = try await planner.proposeNextStep(goal: "finish", contexts: [])

    let request = try #require(await capture.only())
    #expect(request.options == .deterministic(
        promptVersion: ClaudeSingleStepPlanner.promptVersion,
        schemaVersion: ClaudeSingleStepPlanner.schemaVersion,
        callsite: "ClaudeSingleStepPlanner.proposeNextStep"
    ))
    #expect(request.options?.temperature == 0)
    #expect(request.maxTokens == 700)
}

@Test
func pureAnswererCallsCarryDeterministicOptions() async throws {
    let capture = CompletionCapture()
    let answerer = ClaudeGroundedAnswerer(
        client: CapturingCompleter(canned: "Grounded answer.", capture: capture)
    )

    let answer = try await answerer.answer(question: "What happened?", grounding: ChatGrounding())

    #expect(answer == "Grounded answer.")
    let request = try #require(await capture.only())
    #expect(request.options == .deterministic(
        promptVersion: ClaudeGroundedAnswerer.promptVersion,
        schemaVersion: ClaudeGroundedAnswerer.schemaVersion,
        callsite: "ClaudeGroundedAnswerer.answer"
    ))
    #expect(request.options?.temperature == 0)
    #expect(request.maxTokens == 300)
}

@Test
func promptAndSchemaVersionsParticipateInRequestHash() throws {
    let body = Data(#"{"messages":[{"role":"user","content":"Plan"}]}"#.utf8)
    let base = try AnthropicCompletionOptions.deterministic(
        promptVersion: "planner.prompt.v1",
        schemaVersion: "planner.schema.v1",
        callsite: "planner"
    ).cacheRequest(model: AnthropicModel.sonnet, maxTokens: 256, body: body)
    let promptChanged = try AnthropicCompletionOptions.deterministic(
        promptVersion: "planner.prompt.v2",
        schemaVersion: "planner.schema.v1",
        callsite: "planner"
    ).cacheRequest(model: AnthropicModel.sonnet, maxTokens: 256, body: body)
    let schemaChanged = try AnthropicCompletionOptions.deterministic(
        promptVersion: "planner.prompt.v1",
        schemaVersion: "planner.schema.v2",
        callsite: "planner"
    ).cacheRequest(model: AnthropicModel.sonnet, maxTokens: 256, body: body)

    #expect(base.temperature == 0)
    #expect(base.promptVersion == "planner.prompt.v1")
    #expect(base.schemaVersion == "planner.schema.v1")
    #expect(promptChanged.canonicalRequestHash != base.canonicalRequestHash)
    #expect(schemaChanged.canonicalRequestHash != base.canonicalRequestHash)
}

@Test
func compatibilityCompletionOverloadStillCompiles() async throws {
    let text = try await CompatibilityCompleter().complete(
        system: nil,
        user: "hello",
        model: AnthropicModel.haiku,
        maxTokens: 12
    )

    #expect(text == "legacy path still works")
}
