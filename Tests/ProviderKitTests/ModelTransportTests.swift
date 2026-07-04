import XCTest
@testable import ProviderKit

/// Exercised ON-path for the `cascade.transportPolicy` transport (LAW 6: no
/// no-op-flag shapes) — DefaultModelTransport.send is driven with scripted
/// attempt closures and a seeded RetryBackoffPolicy so the retry/backoff/fence
/// contract is pinned deterministically.
@MainActor
final class ModelTransportTests: XCTestCase {
    private final class DelayRecorder {
        var delays: [TimeInterval] = []
    }

    private func makeTransport(
        policy: RetryBackoffPolicy,
        recorder: DelayRecorder
    ) -> DefaultModelTransport {
        DefaultModelTransport(policy: policy) { @MainActor delay in
            recorder.delays.append(delay)
        }
    }

    private static let seededPolicy = RetryBackoffPolicy(
        maxRetries: 2,
        baseDelay: 0.5,
        maxDelay: 5,
        jitterFraction: 0.25,
        jitterSeed: 42
    )

    // (a) Transient failure then success ⇒ exactly 1 retry with the
    // deterministic jittered delay from the seeded policy.
    func testTransientThenSuccessRetriesOnceWithDeterministicJitteredDelay() async {
        let recorder = DelayRecorder()
        let transport = makeTransport(policy: Self.seededPolicy, recorder: recorder)
        let fence = SideEffectFence()
        var attempts = 0

        let result = await transport.send(fence: fence) { () async -> ModelTransportAttemptOutcome<String> in
            attempts += 1
            if attempts == 1 { return .failure(ModelTransportFailure(kind: .transport)) }
            return .success("stream")
        }

        XCTAssertEqual(result, "stream")
        XCTAssertEqual(attempts, 2)
        let expected = Self.seededPolicy.delay(
            afterRetryCount: 0, retryClass: .pureModelCall, classification: .transient
        )
        XCTAssertNotNil(expected)
        XCTAssertEqual(recorder.delays, [min(expected!, Self.seededPolicy.maxDelay)])
        // The seeded jitter actually moved the delay off the raw base — proves
        // jitterSeed is honored (a nil seed silently disables jitter).
        XCTAssertNotEqual(expected!, Self.seededPolicy.baseDelay)
    }

    // (b) Persistent transient failure ⇒ nil after exactly 3 attempts (maxRetries 2).
    func testPersistentTransientFailureStopsAfterMaxRetries() async {
        let recorder = DelayRecorder()
        let transport = makeTransport(policy: Self.seededPolicy, recorder: recorder)
        let fence = SideEffectFence()
        var attempts = 0

        let result = await transport.send(fence: fence) { () async -> ModelTransportAttemptOutcome<String> in
            attempts += 1
            return .failure(ModelTransportFailure(kind: .http(status: 529)))
        }

        XCTAssertNil(result)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(recorder.delays.count, 2)
    }

    // (c) A real 4xx is NEVER retried — nil after exactly 1 attempt.
    func testRealClientErrorIsNeverRetried() async {
        let recorder = DelayRecorder()
        let transport = makeTransport(policy: Self.seededPolicy, recorder: recorder)
        let fence = SideEffectFence()
        var attempts = 0

        let result = await transport.send(fence: fence) { () async -> ModelTransportAttemptOutcome<String> in
            attempts += 1
            return .failure(ModelTransportFailure(kind: .http(status: 400)))
        }

        XCTAssertNil(result)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    // Fatal ends immediately with no retry regardless of budget.
    func testFatalOutcomeEndsImmediately() async {
        let recorder = DelayRecorder()
        let transport = makeTransport(policy: Self.seededPolicy, recorder: recorder)
        var attempts = 0

        let result = await transport.send(fence: SideEffectFence()) { () async -> ModelTransportAttemptOutcome<String> in
            attempts += 1
            return .fatal
        }

        XCTAssertNil(result)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    // (d) An armed fence forbids ALL retries, even on a transient failure —
    // salvage-only (the 0c98387 guarantee), enforced structurally via retryClass.
    func testArmedFenceForbidsRetryEvenOnTransientFailure() async {
        let recorder = DelayRecorder()
        let transport = makeTransport(policy: Self.seededPolicy, recorder: recorder)
        let fence = SideEffectFence()
        var attempts = 0

        let result = await transport.send(fence: fence) { () async -> ModelTransportAttemptOutcome<String> in
            attempts += 1
            fence.arm()  // the turn's first action EXECUTED mid-stream
            return .failure(ModelTransportFailure(kind: .transport))
        }

        XCTAssertNil(result)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    func testFenceRetryClassMapping() {
        let fence = SideEffectFence()
        XCTAssertFalse(fence.isArmed)
        XCTAssertEqual(fence.retryClass, .pureModelCall)
        XCTAssertTrue(fence.retryClass.allowsAutomaticRetry)
        fence.arm()
        XCTAssertTrue(fence.isArmed)
        XCTAssertEqual(fence.retryClass, .nonIdempotentAction)
        XCTAssertFalse(fence.retryClass.allowsAutomaticRetry)
    }

    // (e) Retry-After floors the backoff delay; maxDelay caps it.
    func testRetryAfterFloorsDelayAndMaxDelayCapsIt() {
        let policy = RetryBackoffPolicy(
            maxRetries: 2, baseDelay: 0.5, maxDelay: 5, jitterFraction: 0, jitterSeed: nil
        )
        let transport = DefaultModelTransport(policy: policy)

        // Base delay for retry 0 is 0.5s; Retry-After 2s floors it up.
        XCTAssertEqual(
            transport.retryDelay(
                afterRetryCount: 0,
                failure: ModelTransportFailure(kind: .http(status: 429), retryAfter: 2),
                retryClass: .pureModelCall
            ),
            2
        )
        // Retry-After 30s is capped at maxDelay 5s.
        XCTAssertEqual(
            transport.retryDelay(
                afterRetryCount: 0,
                failure: ModelTransportFailure(kind: .http(status: 503), retryAfter: 30),
                retryClass: .pureModelCall
            ),
            5
        )
        // No Retry-After ⇒ plain backoff.
        XCTAssertEqual(
            transport.retryDelay(
                afterRetryCount: 0,
                failure: ModelTransportFailure(kind: .transport),
                retryClass: .pureModelCall
            ),
            0.5
        )
        // Exhausted budget ⇒ nil.
        XCTAssertNil(
            transport.retryDelay(
                afterRetryCount: 2,
                failure: ModelTransportFailure(kind: .transport),
                retryClass: .pureModelCall
            )
        )
    }

    // Classification parity with TODAY'S streaming rule (transport||408||429||>=500)
    // — NOT RetryErrorClassifier's table, which calls 502 nonTransient and would
    // regress the shipped retry.
    func testFailureClassificationMatchesShippedStreamingRule() {
        XCTAssertTrue(ModelTransportFailure(kind: .transport).isTransient)
        XCTAssertTrue(ModelTransportFailure(kind: .http(status: 408)).isTransient)
        XCTAssertTrue(ModelTransportFailure(kind: .http(status: 429)).isTransient)
        XCTAssertTrue(ModelTransportFailure(kind: .http(status: 500)).isTransient)
        XCTAssertTrue(ModelTransportFailure(kind: .http(status: 502)).isTransient)
        XCTAssertTrue(ModelTransportFailure(kind: .http(status: 529)).isTransient)
        XCTAssertFalse(ModelTransportFailure(kind: .http(status: 400)).isTransient)
        XCTAssertFalse(ModelTransportFailure(kind: .http(status: 401)).isTransient)
        XCTAssertFalse(ModelTransportFailure(kind: .http(status: 404)).isTransient)
    }

    // (f) Flag resolution: unset ⇒ nil transport (today's exact behavior);
    // true ⇒ DefaultModelTransport; explicit injection always wins.
    func testFlagResolutionWiresTransportOnlyWhenEnabled() {
        let suiteName = "ModelTransportTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(ComputerUseAgent.resolveTransport(explicit: nil, defaults: suite))

        let offAgent = ComputerUseAgent(transportDefaults: suite)
        XCTAssertNil(offAgent.transportForTesting)

        suite.set(true, forKey: ComputerUseAgent.transportPolicyDefaultsKey)
        XCTAssertTrue(
            ComputerUseAgent.resolveTransport(explicit: nil, defaults: suite) is DefaultModelTransport
        )
        let onAgent = ComputerUseAgent(transportDefaults: suite)
        XCTAssertTrue(onAgent.transportForTesting is DefaultModelTransport)

        suite.set(false, forKey: ComputerUseAgent.transportPolicyDefaultsKey)
        XCTAssertNil(ComputerUseAgent.resolveTransport(explicit: nil, defaults: suite))
    }
}
