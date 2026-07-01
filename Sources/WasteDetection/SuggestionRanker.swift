import CascadeMemory
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
        public var accepts: Double
        public var declines: Double
        public init(accepts: Double = 0, declines: Double = 0) {
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

    public init(events: [PreferenceEvent], priorAlpha: Double = 1, priorBeta: Double = 1) {
        self.init(priorAlpha: priorAlpha, priorBeta: priorBeta)
        for event in events {
            record(event)
        }
    }

    /// Record a user's response to a suggestion of this key (e.g. app/category/
    /// recipe-signature). Accept = approved/ran; decline = dismissed.
    public mutating func record(_ key: String, accepted: Bool) {
        record(key, reward: accepted ? 1 : -1)
    }

    public mutating func record(_ key: String, reward: Double, weight: Double = 1) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, weight > 0 else { return }
        var outcome = outcomes[cleaned] ?? Outcome()
        if reward > 0 {
            outcome.accepts += min(1, reward) * weight
        } else if reward < 0 {
            outcome.declines += min(1, abs(reward)) * weight
        }
        outcomes[cleaned] = outcome
    }

    public mutating func record(_ event: PreferenceEvent) {
        let reward = event.reward
        let features = Self.featureMap(from: event.featureJSON)
        if let signature = event.workflowSignature {
            record(signature, reward: reward, weight: 1.4)
        }
        if let appName = event.appName { record("app:\(appName)", reward: reward, weight: 0.8) }
        if let surface = event.surface { record("surface:\(surface)", reward: reward, weight: 0.8) }
        record("kind:\(event.kind.rawValue)", reward: reward, weight: 0.45)
        let hour = Calendar.current.component(.hour, from: event.createdAt)
        record("hour:\(hour)", reward: reward, weight: 0.3)
        for key in ["candidateType", "backgroundCapable", "privacyRiskBucket", "appFamily", "surfaceFamily", "timingPreference", "backgroundPreference"] {
            if let value = features[key], !value.isEmpty {
                record("\(key):\(value)", reward: reward, weight: 0.65)
            }
        }
    }

    /// Posterior-mean acceptance probability for this key — the learned preference
    /// weight in 0…1. Unseen keys return the prior mean.
    public func preference(_ key: String) -> Double {
        let outcome = outcomes[key] ?? outcomes[AuditIdentity.hash(key)] ?? Outcome()
        return (outcome.accepts + priorAlpha)
            / (outcome.accepts + outcome.declines + priorAlpha + priorBeta)
    }

    public func outcome(_ key: String) -> Outcome { outcomes[key] ?? Outcome() }

    public func evidenceCount(_ key: String) -> Double {
        let outcome = outcomes[key] ?? outcomes[AuditIdentity.hash(key)] ?? Outcome()
        return outcome.accepts + outcome.declines
    }

    public func preference(for key: String, context: PreferenceContext) -> Double {
        var weighted = preference(key) * 2.0
        var totalWeight = 2.0
        for bucket in context.bucketKeys {
            weighted += preference(bucket)
            totalWeight += 1
        }
        return weighted / totalWeight
    }

    private static func featureMap(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var output: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String:
                output[key] = string
            case let bool as Bool:
                output[key] = bool ? "true" : "false"
            case let number as NSNumber:
                output[key] = number.stringValue
            default:
                continue
            }
        }
        return output
    }
}

public struct PreferenceContext: Sendable, Equatable {
    public var appName: String?
    public var surface: String?
    public var candidateType: String?
    public var hourBucket: Int?
    public var backgroundCapable: Bool?
    public var privacyRiskBucket: String?
    public var additionalBuckets: [String]

    public init(
        appName: String? = nil,
        surface: String? = nil,
        candidateType: String? = nil,
        hourBucket: Int? = nil,
        backgroundCapable: Bool? = nil,
        privacyRiskBucket: String? = nil,
        additionalBuckets: [String] = []
    ) {
        self.appName = appName
        self.surface = surface
        self.candidateType = candidateType
        self.hourBucket = hourBucket
        self.backgroundCapable = backgroundCapable
        self.privacyRiskBucket = privacyRiskBucket
        self.additionalBuckets = additionalBuckets
    }

    public var bucketKeys: [String] {
        var keys: [String] = []
        if let appName { keys.append("app:\(Self.safeBucket(appName))") }
        if let surface { keys.append("surface:\(Self.safeBucket(surface))") }
        if let candidateType { keys.append("candidateType:\(Self.safeBucket(candidateType))") }
        if let hourBucket { keys.append("hour:\(hourBucket)") }
        if let backgroundCapable { keys.append("backgroundCapable:\(backgroundCapable ? "true" : "false")") }
        if let privacyRiskBucket { keys.append("privacyRiskBucket:\(Self.safeBucket(privacyRiskBucket))") }
        keys.append(contentsOf: additionalBuckets)
        return keys
    }

    private static func safeBucket(_ value: String) -> String {
        AuditIdentity.safeToken(value.lowercased())
    }
}

public struct PersonalizationThreshold: Sendable, Equatable {
    public let minRepeats: Int
    public let minObservedSeconds: Int
    public let confidence: Double

    public init(minRepeats: Int, minObservedSeconds: Int, confidence: Double) {
        self.minRepeats = minRepeats
        self.minObservedSeconds = minObservedSeconds
        self.confidence = max(0, min(1, confidence))
    }
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
        context: (Element) -> PreferenceContext = { _ in PreferenceContext() },
        using model: PreferenceModel
    ) -> [Element] {
        let scored = candidates.enumerated().map { item in
            let element = item.element
            let intrinsic = max(0, base(element))
            let personalized = pow(model.preference(for: key(element), context: context(element)), preferenceWeight)
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
            context: Self.detectedWasteContext,
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
    public func personalizationThreshold(
        _ key: String,
        baseRepeats: Int,
        baseObservedSeconds: Int,
        using model: PreferenceModel,
        context: PreferenceContext = PreferenceContext()
    ) -> PersonalizationThreshold {
        let preference = model.preference(for: key, context: context)
        let evidence = model.evidenceCount(key)
        let confidence = min(1, evidence / 6)
        var repeats = baseRepeats
        var seconds = baseObservedSeconds
        if evidence >= 2, preference >= 0.67 {
            repeats -= 1
            seconds = max(20, baseObservedSeconds - 10)
        } else if evidence >= 2, preference <= 0.33 {
            repeats += 2
            seconds = baseObservedSeconds + 30
        } else if preference > 0.58 {
            seconds = max(25, baseObservedSeconds - 5)
        } else if preference < 0.42 {
            seconds = baseObservedSeconds + 15
        }
        return PersonalizationThreshold(
            minRepeats: max(2, repeats),
            minObservedSeconds: max(1, seconds),
            confidence: confidence
        )
    }

    public func personalizedThreshold(_ key: String, base: Int, span: Int = 2, using model: PreferenceModel) -> Int {
        let threshold = personalizationThreshold(key, baseRepeats: base, baseObservedSeconds: 30, using: model)
        return min(base + span, max(2, threshold.minRepeats))
    }

    private static func detectedWasteContext(_ waste: DetectedWaste) -> PreferenceContext {
        PreferenceContext(
            appName: waste.apps.first,
            surface: "manager.review",
            candidateType: "detectedWaste",
            hourBucket: Calendar.current.component(.hour, from: waste.lastSeenAt),
            backgroundCapable: waste.apps.allSatisfy { browserNames.contains($0.lowercased()) },
            privacyRiskBucket: Self.privacyRiskBucket(waste.quality?.privacyPenalty)
        )
    }

    private static func privacyRiskBucket(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        if value >= 0.55 { return "high" }
        if value >= 0.25 { return "medium" }
        return "low"
    }

    private static let browserNames: Set<String> = [
        "safari", "google chrome", "chrome", "arc", "firefox", "microsoft edge", "brave browser"
    ]
}
