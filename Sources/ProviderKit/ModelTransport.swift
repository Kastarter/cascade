import Foundation
import os

/// Turn-scoped side-effect fence for the on-screen CU model send (plan §3.3 + §5).
///
/// Once the turn's FIRST action has EXECUTED on the real screen, retrying the
/// model call is forbidden — a retry would generate a fresh plan against a
/// half-acted screen (the 0c98387 guarantee). The ban is STRUCTURAL, not
/// advisory: an armed fence maps to `ActionRetryClass.nonIdempotentAction`,
/// whose `allowsAutomaticRetry == false`, so `RetryBackoffPolicy.delay` returns
/// nil and no retry loop can fire. Salvage of already-completed blocks remains
/// the caller's job (`ComputerUseAgent.salvage`), which is stricter still — a
/// completed-but-unexecuted tool_use block also blocks retry there.
@MainActor
public final class SideEffectFence {
    public private(set) var isArmed = false

    public init() {}

    /// Called when a streamed action has actually EXECUTED. Irreversible for the turn.
    public func arm() { isArmed = true }

    /// The retry class this turn's model call currently belongs to. Armed ⇒
    /// `.nonIdempotentAction` — the structural retry ban.
    public var retryClass: ActionRetryClass {
        isArmed ? .nonIdempotentAction : .pureModelCall
    }
}

/// One failed model-send attempt, classified with TODAY'S streaming rule:
/// transport error / 408 / 429 / >=500 are transient (retryable), any other
/// HTTP status is a real 4xx and never retried.
///
/// Deliberately NOT `RetryErrorClassifier.classify(httpStatusCode:)` — that
/// table calls 502 (and other 5xx defaults) nonTransient, which would make the
/// ON path REFUSE retries the shipped streaming code performs today.
public struct ModelTransportFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case transport
        case http(status: Int)

        var logDescription: String {
            switch self {
            case .transport: return "transport"
            case .http(let status): return "HTTP \(status)"
            }
        }
    }

    public let kind: Kind
    /// Server-suggested wait (Retry-After), used as a FLOOR on the backoff delay.
    public let retryAfter: TimeInterval?

    public init(kind: Kind, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.retryAfter = retryAfter
    }

    public var isTransient: Bool {
        switch kind {
        case .transport:
            return true
        case .http(let status):
            return status == 408 || status == 429 || status >= 500
        }
    }
}

/// What one send attempt produced: a complete (or salvaged) stream, a
/// classified failure the transport may retry, or a fatal condition that ends
/// the turn immediately.
public enum ModelTransportAttemptOutcome<Stream> {
    case success(Stream)
    case failure(ModelTransportFailure)
    case fatal
}

/// Owns the retry loop around one turn's model send (plan §3.3). The caller
/// supplies the attempt closure (which performs one streamed request and arms
/// the fence when an action executes); the transport decides whether and when
/// to try again. Behind `cascade.transportPolicy` — with the flag OFF the
/// agent's transport is nil and this protocol is never touched.
@MainActor
public protocol ModelTransporting {
    func send<Stream>(
        fence: SideEffectFence,
        attempt: @MainActor () async -> ModelTransportAttemptOutcome<Stream>
    ) async -> Stream?
}

/// Default transport: ≤2 retries with jittered exponential backoff (reusing
/// `RetryBackoffPolicy`), retrying ONLY transient transport/5xx/429 failures
/// (never a real 4xx), and never after the fence armed (salvage-only).
@MainActor
public struct DefaultModelTransport: ModelTransporting {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "modeltransport")

    let policy: RetryBackoffPolicy
    private let sleeper: @MainActor (TimeInterval) async -> Void

    /// `policy` MUST carry a non-nil `jitterSeed` or `RetryBackoffPolicy`
    /// silently disables jitter — the default seeds one randomly per transport.
    public init(
        policy: RetryBackoffPolicy = RetryBackoffPolicy(
            maxRetries: 2,
            baseDelay: 0.5,
            maxDelay: 5,
            jitterFraction: 0.25,
            jitterSeed: UInt64.random(in: UInt64.min ... UInt64.max)
        ),
        sleeper: (@MainActor (TimeInterval) async -> Void)? = nil
    ) {
        self.policy = policy
        self.sleeper = sleeper ?? { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    /// The delay before retry number `retryCount + 1`, or nil when no retry is
    /// allowed (fence armed, non-transient failure, or retries exhausted).
    /// Jittered exponential backoff, floored by the server's Retry-After,
    /// capped at `policy.maxDelay`.
    func retryDelay(
        afterRetryCount retryCount: Int,
        failure: ModelTransportFailure,
        retryClass: ActionRetryClass
    ) -> TimeInterval? {
        guard let base = policy.delay(
            afterRetryCount: retryCount,
            retryClass: retryClass,
            classification: failure.isTransient ? .transient : .nonTransient
        ) else { return nil }
        var delay = base
        if let after = failure.retryAfter { delay = max(delay, after) }
        return min(delay, policy.maxDelay)
    }

    public func send<Stream>(
        fence: SideEffectFence,
        attempt: @MainActor () async -> ModelTransportAttemptOutcome<Stream>
    ) async -> Stream? {
        var retryCount = 0
        while true {
            switch await attempt() {
            case .success(let stream):
                return stream
            case .fatal:
                return nil
            case .failure(let failure):
                guard let delay = retryDelay(
                    afterRetryCount: retryCount,
                    failure: failure,
                    retryClass: fence.retryClass
                ) else { return nil }
                Self.logger.notice(
                    "model transport retry \(retryCount + 1)/\(policy.maxRetries) in \(delay, format: .fixed(precision: 2))s — \(failure.kind.logDescription, privacy: .public)"
                )
                await sleeper(delay)
                retryCount += 1
            }
        }
    }
}
