import CascadeMemory
import Foundation
import Testing
import WasteDetection

// MARK: - Preference model

@Test
func unseenKeySitsAtThePriorMean() {
    let model = PreferenceModel(priorAlpha: 1, priorBeta: 1)
    #expect(abs(model.preference("never-seen") - 0.5) < 1e-9)
}

@Test
func preferenceRisesWithAcceptsAndFallsWithDeclines() {
    var model = PreferenceModel()
    let neutral = model.preference("mail")
    for _ in 0..<5 { model.record("mail", accepted: true) }
    #expect(model.preference("mail") > neutral)
    for _ in 0..<10 { model.record("slack", accepted: false) }
    #expect(model.preference("slack") < neutral)
}

// MARK: - Ranker

@Test
func rankingReordersByLearnedPreference() {
    var model = PreferenceModel()
    // Same intrinsic relevance, but the user loves "mail" suggestions and hates "slack".
    for _ in 0..<8 { model.record("mail", accepted: true) }
    for _ in 0..<8 { model.record("slack", accepted: false) }
    let ranker = SuggestionRanker(preferenceWeight: 1.0)
    let ranked = ranker.rank([("slack", 1.0), ("mail", 1.0), ("notes", 1.0)], using: model)
    #expect(ranked.first?.key == "mail")     // accepted-history rises
    #expect(ranked.last?.key == "slack")     // declined-history sinks
}

@Test
func zeroPreferenceWeightPreservesRelevanceOrder() {
    var model = PreferenceModel()
    for _ in 0..<8 { model.record("slack", accepted: true) }   // would normally float up
    let ranker = SuggestionRanker(preferenceWeight: 0)          // personalization off
    let ranked = ranker.rank([("a", 0.9), ("slack", 0.5)], using: model)
    #expect(ranked.first?.key == "a")        // pure relevance wins
}

@Test
func personalizedThresholdAdaptsToHistory() {
    var model = PreferenceModel()
    let ranker = SuggestionRanker()
    // Neutral key → base unchanged.
    #expect(ranker.personalizedThreshold("new", base: 3, span: 2, using: model) == 3)
    // Loved key → lower bar (surface sooner), never below 2.
    for _ in 0..<20 { model.record("rename", accepted: true) }
    #expect(ranker.personalizedThreshold("rename", base: 3, span: 2, using: model) < 3)
    // Hated key → higher bar.
    for _ in 0..<20 { model.record("autosend", accepted: false) }
    #expect(ranker.personalizedThreshold("autosend", base: 3, span: 2, using: model) > 3)
}

@Test
func durablePreferenceEventsReplayHashedWorkflowSignatures() {
    let events = [
        PreferenceEvent(kind: .agentApproved, reward: 1, workflowSignature: AuditIdentity.hash("mail-flow")),
        PreferenceEvent(kind: .agentRunCompleted, reward: 0.7, workflowSignature: AuditIdentity.hash("mail-flow")),
        PreferenceEvent(kind: .agentDeclined, reward: -1, workflowSignature: AuditIdentity.hash("slack-flow")),
    ]
    let model = PreferenceModel(events: events)
    let ranked = SuggestionRanker().rank([("slack-flow", 1), ("mail-flow", 1)], using: model)

    #expect(ranked.first?.key == "mail-flow")
    #expect(ranked.last?.key == "slack-flow")
}

@Test
func contextualBucketsPromoteAcceptedAppAndSurfaceFamilies() {
    let events = [
        PreferenceEvent(
            kind: .proactiveAccepted,
            reward: 0.8,
            surface: "proactive",
            appName: "safari",
            workflowSignature: AuditIdentity.hash("offer-a"),
            featureJSON: #"{"candidateType":"backgroundWebAgent","backgroundCapable":"true"}"#
        ),
        PreferenceEvent(
            kind: .proactiveDismissed,
            reward: -0.6,
            surface: "proactive",
            appName: "slack",
            workflowSignature: AuditIdentity.hash("offer-b"),
            featureJSON: #"{"candidateType":"backgroundWebAgent","backgroundCapable":"true"}"#
        ),
    ]
    let model = PreferenceModel(events: events)
    let ranker = SuggestionRanker()
    let ranked = ranker.rankElements(
        ["candidate-b", "candidate-a"],
        key: { $0 },
        base: { _ in 1 },
        context: {
            PreferenceContext(
                appName: $0 == "candidate-a" ? "safari" : "slack",
                surface: "proactive",
                candidateType: "backgroundWebAgent",
                backgroundCapable: true
            )
        },
        using: model
    )

    #expect(ranked == ["candidate-a", "candidate-b"])
}

@Test
func personalizationThresholdReturnsRepeatsSecondsAndConfidence() {
    var model = PreferenceModel()
    let ranker = SuggestionRanker()
    for _ in 0..<3 { model.record("accepted", accepted: true) }
    for _ in 0..<3 { model.record("declined", accepted: false) }

    let accepted = ranker.personalizationThreshold("accepted", baseRepeats: 3, baseObservedSeconds: 30, using: model)
    let declined = ranker.personalizationThreshold("declined", baseRepeats: 3, baseObservedSeconds: 30, using: model)
    let neutral = ranker.personalizationThreshold("neutral", baseRepeats: 3, baseObservedSeconds: 30, using: model)

    #expect(accepted.minRepeats == 2)
    #expect(accepted.minObservedSeconds < 30)
    #expect(declined.minRepeats > 3)
    #expect(declined.minObservedSeconds > 30)
    #expect(neutral.minRepeats == 3)
    #expect(neutral.minObservedSeconds == 30)
    #expect(accepted.confidence > 0)
}
