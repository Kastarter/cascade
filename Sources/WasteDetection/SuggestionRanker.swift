import Foundation

/// Learns, on-device, which kinds of suggestions a user actually wants from their
/// accept/decline history, and uses it to RANK suggestions — never to generate or
/// suppress them. "It learns how I work" is the retention moat (SEQ-20).
///
/// A Beta-Bernoulli preference per key (Thompson-sampling's conjugate model used
/// for its posterior mean): the learned weight is the smoothed acceptance rate, so
/// an unseen key sits at the neutral prior and only moves with evidence.
public struct PreferenceModel: Sendable, Equatable {
    public struct Outcome: Sendable, Equatable {
        public var accepts: Int
        public var declines: Int
        public init(accepts: Int = 0, declines: Int = 0) {
            self.accepts = accepts
            self.declines = declines
        }
    }

    public let priorAlpha: Double
    public let priorBeta: Double
    private var outcomes: [String: Outcome]

    public init(priorAlpha: Double = 1, priorBeta: Double = 1) {
        self.priorAlpha = max(priorAlpha, 0.001)
        self.priorBeta = max(priorBeta, 0.001)
        self.outcomes = [:]
    }

    /// Record a user's response to a suggestion of this key (e.g. app/category/
    /// recipe-signature). Accept = approved/ran; decline = dismissed.
    public mutating func record(_ key: String, accepted: Bool) {
        var outcome = outcomes[key] ?? Outcome()
        if accepted { outcome.accepts += 1 } else { outcome.declines += 1 }
        outcomes[key] = outcome
    }

    /// Posterior-mean acceptance probability for this key — the learned preference
    /// weight in 0…1. Unseen keys return the prior mean.
    public func preference(_ key: String) -> Double {
        let outcome = outcomes[key] ?? Outcome()
        return (Double(outcome.accepts) + priorAlpha)
            / (Double(outcome.accepts + outcome.declines) + priorAlpha + priorBeta)
    }

    public func outcome(_ key: String) -> Outcome { outcomes[key] ?? Outcome() }
}

/// Ranks candidate suggestions by combining their intrinsic relevance with the
/// learned per-key preference, and adapts how-repetitive-before-surfacing per key.
public struct SuggestionRanker: Sendable {
    /// Exponent on the preference weight — higher = personalization dominates,
    /// lower = relevance dominates. 0 disables personalization.
    public let preferenceWeight: Double

    public init(preferenceWeight: Double = 1.0) {
        self.preferenceWeight = max(0, preferenceWeight)
    }

    public struct Scored: Sendable, Equatable {
        public let key: String
        public let score: Double
    }

    /// Rank `candidates` (key + intrinsic relevance) by `base × preference^weight`,
    /// descending, with the key as a stable tiebreak. Generation is unchanged —
    /// only the order is personalized.
    public func rank(_ candidates: [(key: String, base: Double)], using model: PreferenceModel) -> [Scored] {
        candidates
            .map { Scored(key: $0.key, score: $0.base * pow(model.preference($0.key), preferenceWeight)) }
            .sorted { $0.score == $1.score ? $0.key < $1.key : $0.score > $1.score }
    }

    /// Rank arbitrary suggestion-like values by a key and intrinsic relevance score.
    /// Equal personalized scores keep the input order, so enabling personalization
    /// cannot reshuffle neutral ties.
    public func rankElements<Element>(
        _ candidates: [Element],
        key: (Element) -> String,
        base: (Element) -> Double,
        using model: PreferenceModel
    ) -> [Element] {
        let scored = candidates.enumerated().map { item in
            let element = item.element
            let intrinsic = max(0, base(element))
            let personalized = pow(model.preference(key(element)), preferenceWeight)
            return RankedElement(index: item.offset, element: element, score: intrinsic * personalized)
        }
        return scored
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
            }
            .map(\.element)
    }

    /// Rank detected workflow candidates without suppressing any of them. This is the
    /// pure integration point for the app's default-off personalization experiment.
    public func rankDetectedWaste(_ candidates: [DetectedWaste], using model: PreferenceModel, now: Date = Date()) -> [DetectedWaste] {
        rankElements(
            candidates,
            key: \.signature,
            base: { WasteDetector.rankingScore($0, now: now) },
            using: model
        )
    }

    private struct RankedElement<Element> {
        let index: Int
        let element: Element
        let score: Double
    }

    /// Personalized repetition threshold: a user who accepts this key's suggestions
    /// gets them sooner (lower bar); one who declines gets a higher bar. Bounded
    /// around `base` by ±`span`, never below 2.
    public func personalizedThreshold(_ key: String, base: Int, span: Int = 2, using model: PreferenceModel) -> Int {
        let preference = model.preference(key)            // 0…1, 0.5 = neutral
        let delta = Int((Double(span) * (0.5 - preference) * 2).rounded())
        return max(2, base + delta)
    }
}
