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
