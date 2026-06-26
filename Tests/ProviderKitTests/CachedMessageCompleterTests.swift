import CascadeMemory
import Foundation
import Testing

@testable import ProviderKit

private struct CapturedMessageCall: Equatable, Sendable {
    let system: String?
    let user: String
    let model: String
    let maxTokens: Int
}

private actor CountingMessageClient {
    private var replies: [String]
    private let delayNanos: UInt64
    private(set) var calls: [CapturedMessageCall] = []

    init(replies: [String], delayNanos: UInt64 = 0) {
        self.replies = replies
        self.delayNanos = delayNanos
    }

    var count: Int { calls.count }

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        calls.append(CapturedMessageCall(system: system, user: user, model: model, maxTokens: maxTokens))
        if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
        }
        if replies.count > 1 {
            return replies.removeFirst()
        }
        return replies[0]
    }
}

private struct CountingMessageCompleter: MessageCompleting {
    let client: CountingMessageClient

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        try await client.complete(system: system, user: user, model: model, maxTokens: maxTokens)
    }
}

@Test
func nilPlannerCacheCallsClientEveryTime() async throws {
    let client = CountingMessageClient(replies: [validStepJSON])
    let planner = ClaudeSingleStepPlanner(client: CountingMessageCompleter(client: client))

    _ = try await planner.proposeNextStep(goal: "finish", contexts: [])
    _ = try await planner.proposeNextStep(goal: "finish", contexts: [])

    #expect(await client.count == 2)
}

@Test
func cachedMessageCompleterDedupesStoredAndInFlightRequests() async throws {
    let client = CountingMessageClient(replies: [validStepJSON], delayNanos: 50_000_000)
    let completer = CachedMessageCompleter(
        client: CountingMessageCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )
    let options = AnthropicCompletionOptions.deterministic(
        promptVersion: "planner.prompt.v1",
        schemaVersion: "planner.schema.v1",
        callsite: "planner"
    )

    async let first = completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: options, validating: validatePlannerStep)
    async let second = completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: options, validating: validatePlannerStep)
    async let third = completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: options, validating: validatePlannerStep)

    #expect(try await [first, second, third] == [validStepJSON, validStepJSON, validStepJSON])
    #expect(await client.count == 1)

    let cached = try await completer.complete(
        system: "system",
        user: "user",
        model: AnthropicModel.sonnet,
        maxTokens: 256,
        options: options,
        validating: validatePlannerStep
    )
    #expect(cached == validStepJSON)
    #expect(await client.count == 1)
}

@Test
func promptSchemaAndModelChangesMissCachedMessageCompleter() async throws {
    let client = CountingMessageClient(replies: [validStepJSON])
    let completer = CachedMessageCompleter(
        client: CountingMessageCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )
    let base = AnthropicCompletionOptions.deterministic(promptVersion: "p1", schemaVersion: "s1", callsite: "planner")
    let promptChanged = AnthropicCompletionOptions.deterministic(promptVersion: "p2", schemaVersion: "s1", callsite: "planner")
    let schemaChanged = AnthropicCompletionOptions.deterministic(promptVersion: "p1", schemaVersion: "s2", callsite: "planner")

    _ = try await completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: base, validating: validatePlannerStep)
    _ = try await completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: promptChanged, validating: validatePlannerStep)
    _ = try await completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: schemaChanged, validating: validatePlannerStep)
    _ = try await completer.complete(system: "system", user: "user", model: AnthropicModel.haiku, maxTokens: 256, options: base, validating: validatePlannerStep)

    #expect(await client.count == 4)

    _ = try await completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: base, validating: validatePlannerStep)
    #expect(await client.count == 4)
}

@Test
func validationFailuresAreNotCachedAsPlannerResponses() async throws {
    let client = CountingMessageClient(replies: ["not json", validStepJSON])
    let completer = CachedMessageCompleter(
        client: CountingMessageCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )
    let options = AnthropicCompletionOptions.deterministic(promptVersion: "p1", schemaVersion: "s1", callsite: "planner")

    do {
        _ = try await completer.complete(system: "system", user: "user", model: AnthropicModel.sonnet, maxTokens: 256, options: options, validating: validatePlannerStep)
        Issue.record("Expected the invalid response to throw.")
    } catch CachedMessageCompleterError.invalidResponse {
    }

    let recovered = try await completer.complete(
        system: "system",
        user: "user",
        model: AnthropicModel.sonnet,
        maxTokens: 256,
        options: options,
        validating: validatePlannerStep
    )
    #expect(recovered == validStepJSON)
    #expect(await client.count == 2)
}

private let validStepJSON = #"{"rationale":"done","confidence":1,"action":{"kind":"done","summary":"ok"}}"#

private func validatePlannerStep(_ text: String) throws {
    do {
        _ = try ClaudeSingleStepPlanner.parse(text)
    } catch {
        throw CachedMessageCompleterError.invalidResponse
    }
}
