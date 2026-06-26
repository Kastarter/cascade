import Foundation

/// Predicts the user's next action from their recent action stream so Cascade can
/// help *just in time* — "you've done A then B; you usually do C next — automate
/// it?" — instead of only surfacing repeated work in a daily digest (SEQ-18).
///
/// An online, back-off n-gram model: simple, fast, on-device, and (per the
/// next-activity-prediction literature) a strong baseline before any LSTM/LLM.
/// Tokens are opaque action labels (e.g. "click:Reply", "key:cmd+c", "app:Mail").
public struct NextActionPredictor: Sendable {
    public struct Prediction: Sendable, Equatable {
        public let token: String
        public let confidence: Double   // P(next = token | current context), 0…1
        public let support: Int         // how many times the context was seen
    }

    /// Longest context (n-1) the model conditions on before backing off.
    public let maxOrder: Int
    /// A context must have been seen at least this many times to predict from it.
    public let minSupport: Int

    public init(maxOrder: Int = 3, minSupport: Int = 2) {
        self.maxOrder = max(2, maxOrder)
        self.minSupport = max(2, minSupport)
    }

    /// Predict the most likely next token given the action `history`, conditioning
    /// on the longest recent suffix that has enough support and backing off to
    /// shorter contexts. Returns nil when nothing recurs strongly enough.
    public func predict(history: [String]) -> Prediction? {
        let n = history.count
        guard n >= 2 else { return nil }
        let maxK = min(maxOrder - 1, n - 1)
        for k in stride(from: maxK, through: 1, by: -1) {
            let context = Array(history.suffix(k))
            var following: [String: Int] = [:]
            var total = 0
            var i = 0
            // Count tokens that historically followed this context, excluding the
            // trailing occurrence (that's the one we're predicting FOR).
            while i + k < n {
                if Array(history[i..<i + k]) == context {
                    following[history[i + k], default: 0] += 1
                    total += 1
                }
                i += 1
            }
            if total >= minSupport,
               let best = following.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
                return Prediction(token: best.key, confidence: Double(best.value) / Double(total), support: total)
            }
        }
        return nil
    }
}

/// Decides WHETHER to surface a proactive offer — the hard part of proactivity is
/// not predicting, it's not being annoying. A false interruption costs trust, so
/// the gate is conservative: high confidence, off the active-typing path, past a
/// cooldown, and it mutes itself once the user has dismissed enough (learned
/// interruptibility — SEQ-18).
public struct InterruptibilityGate: Sendable {
    public var minConfidence: Double
    public var cooldownSeconds: TimeInterval
    public var maxRecentDismissalsBeforeMute: Int

    public init(minConfidence: Double = 0.6, cooldownSeconds: TimeInterval = 120, maxRecentDismissalsBeforeMute: Int = 3) {
        self.minConfidence = minConfidence
        self.cooldownSeconds = cooldownSeconds
        self.maxRecentDismissalsBeforeMute = maxRecentDismissalsBeforeMute
    }

    public enum Decision: Sendable, Equatable {
        case offer
        case suppress(reason: String)
    }

    public func decide(
        confidence: Double,
        secondsSinceLastOffer: TimeInterval,
        recentDismissals: Int,
        userIsActivelyTyping: Bool
    ) -> Decision {
        if userIsActivelyTyping { return .suppress(reason: "user is typing") }
        if confidence < minConfidence { return .suppress(reason: "confidence below threshold") }
        if secondsSinceLastOffer < cooldownSeconds { return .suppress(reason: "within cooldown") }
        if recentDismissals >= maxRecentDismissalsBeforeMute { return .suppress(reason: "muted after repeated dismissals") }
        return .offer
    }

    public func shouldOffer(
        confidence: Double, secondsSinceLastOffer: TimeInterval,
        recentDismissals: Int, userIsActivelyTyping: Bool
    ) -> Bool {
        decide(
            confidence: confidence, secondsSinceLastOffer: secondsSinceLastOffer,
            recentDismissals: recentDismissals, userIsActivelyTyping: userIsActivelyTyping
        ) == .offer
    }
}
