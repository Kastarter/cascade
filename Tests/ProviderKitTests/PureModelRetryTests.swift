import Foundation
import ProviderKit
import Testing

private enum FlakyOutcome: Sendable {
    case success(String)
    case transientHTTP
    case nonTransientHTTP
}

private actor FlakyMessageClient {
    private var outcomes: [FlakyOutcome]
    private(set) var count = 0

    init(outcomes: [FlakyOutcome]) {
        self.outcomes = outcomes
    }

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        count += 1
        let outcome = outcomes.isEmpty ? .success(validStepJSON) : outcomes.removeFirst()
        switch outcome {
        case .success(let text):
            return text
        case .transientHTTP:
            throw AnthropicError.http(503, "temporarily unavailable")
        case .nonTransientHTTP:
            throw AnthropicError.http(400, "bad request")
        }
    }
}

private struct FlakyMessageCompleter: MessageCompleting {
    let client: FlakyMessageClient

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        try await client.complete(system: system, user: user, model: model, maxTokens: maxTokens)
    }
}

@Test
func enabledPureModelRetryRecoversOneTransientFailure() async throws {
    let client = FlakyMessageClient(outcomes: [.transientHTTP, .success(validStepJSON)])
    let planner = ClaudeSingleStepPlanner(
        client: FlakyMessageCompleter(client: client),
        model: AnthropicModel.sonnet,
        retryPolicy: RetryBackoffPolicy(maxRetries: 1, baseDelay: 0, maxDelay: 0)
    )

    let step = try await planner.proposeNextStep(goal: "finish", contexts: [])

    #expect(step.action == .done("ok"))
    #expect(await client.count == 2)
}

@Test
func nilPureModelRetryPolicyPreservesOneAttempt() async throws {
    let client = FlakyMessageClient(outcomes: [.transientHTTP, .success(validStepJSON)])
    let planner = ClaudeSingleStepPlanner(
        client: FlakyMessageCompleter(client: client),
        model: AnthropicModel.sonnet
    )

    do {
        _ = try await planner.proposeNextStep(goal: "finish", contexts: [])
        Issue.record("Expected the transient failure to be returned without retry.")
    } catch AnthropicError.http(let statusCode, _) {
        #expect(statusCode == 503)
    } catch {
        Issue.record("Expected Anthropic HTTP error, got \(error).")
    }
    #expect(await client.count == 1)
}

@Test
func nonTransientPureModelErrorsDoNotRetry() async throws {
    let client = FlakyMessageClient(outcomes: [.nonTransientHTTP, .success(validStepJSON)])
    let planner = ClaudeSingleStepPlanner(
        client: FlakyMessageCompleter(client: client),
        model: AnthropicModel.sonnet,
        retryPolicy: RetryBackoffPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
    )

    do {
        _ = try await planner.proposeNextStep(goal: "finish", contexts: [])
        Issue.record("Expected the nontransient failure to be returned without retry.")
    } catch AnthropicError.http(let statusCode, _) {
        #expect(statusCode == 400)
    } catch {
        Issue.record("Expected Anthropic HTTP error, got \(error).")
    }
    #expect(await client.count == 1)
}

@Test
func pureModelRetrySeededJitterIsDeterministic() throws {
    let key = try ActionIdempotencyKey(
        retryClass: .pureModelCall,
        operation: "ClaudeSingleStepPlanner.proposeNextStep",
        model: AnthropicModel.sonnet,
        prompt: "claude-single-step-planner.prompt.v1",
        schema: "claude-single-step-planner.schema.v1",
        payload: ["user": "finish"]
    )
    let first = RetryBackoffPolicy(maxRetries: 2, baseDelay: 0.5, maxDelay: 2, jitterFraction: 0.25, jitterSeed: 99)
    let second = RetryBackoffPolicy(maxRetries: 2, baseDelay: 0.5, maxDelay: 2, jitterFraction: 0.25, jitterSeed: 99)
    let differentSeed = RetryBackoffPolicy(maxRetries: 2, baseDelay: 0.5, maxDelay: 2, jitterFraction: 0.25, jitterSeed: 100)

    let firstDelay = first.delay(afterRetryCount: 0, retryClass: .pureModelCall, classification: .transient, key: key)
    let secondDelay = second.delay(afterRetryCount: 0, retryClass: .pureModelCall, classification: .transient, key: key)
    let differentSeedDelay = differentSeed.delay(afterRetryCount: 0, retryClass: .pureModelCall, classification: .transient, key: key)

    #expect(firstDelay == secondDelay)
    #expect(firstDelay != differentSeedDelay)
}

private let validStepJSON = #"{"rationale":"done","confidence":1,"action":{"kind":"done","summary":"ok"}}"#
