import CascadeMemory
import Foundation
import Testing
@testable import WasteDetection

private let suggestionRankingBase = Date(timeIntervalSince1970: 1_710_000_000)

private func rankedWaste(_ signature: String, app: String = "Mail") -> DetectedWaste {
    DetectedWaste(
        title: signature,
        apps: [app],
        occurrences: 3,
        estimatedSecondsPerRun: 20,
        estimatedTotalSeconds: 60,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .click, appName: app),
            RecipeStep(order: 1, kind: .key, key: "s", modifiers: ["command"], appName: app),
        ]),
        evidence: [],
        confidence: 0.7,
        signature: signature,
        lastSeenAt: suggestionRankingBase
    )
}

@Test
func detectedWasteRankingPromotesAcceptedAndDemotesDeclinedWithoutFiltering() {
    var model = PreferenceModel()
    for _ in 0..<4 { model.record("accepted", accepted: true) }
    for _ in 0..<4 { model.record("declined", accepted: false) }
    let candidates = [rankedWaste("declined"), rankedWaste("neutral"), rankedWaste("accepted")]

    let ranked = SuggestionRanker().rankDetectedWaste(candidates, using: model, now: suggestionRankingBase)

    #expect(ranked.map(\.signature).count == candidates.count)
    #expect(ranked.map(\.signature).contains("declined"))
    #expect(ranked.first?.signature == "accepted")
    #expect(ranked.last?.signature == "declined")
}

@Test
func detectedWasteRankingKeepsStableTies() {
    let candidates = [rankedWaste("b"), rankedWaste("a"), rankedWaste("c")]

    let ranked = SuggestionRanker(preferenceWeight: 0)
        .rankDetectedWaste(candidates, using: PreferenceModel(), now: suggestionRankingBase)

    #expect(ranked.map(\.signature) == ["b", "a", "c"])
}

@Test
func proactiveNextActionOfferRequiresPredictionAndInterruptibility() {
    let predictor = NextActionPredictor()
    let history = ["A", "B", "C", "A", "B", "C", "A", "B"]
    let gate = InterruptibilityGate(minConfidence: 0.6, cooldownSeconds: 120, maxRecentDismissalsBeforeMute: 3)

    #expect(predictor.proactiveOffer(
        history: history,
        secondsSinceLastOffer: 300,
        recentDismissals: 0,
        userIsActivelyTyping: false,
        gate: gate
    )?.token == "C")
    #expect(predictor.proactiveOffer(
        history: history,
        secondsSinceLastOffer: 10,
        recentDismissals: 0,
        userIsActivelyTyping: false,
        gate: gate
    ) == nil)
    #expect(predictor.proactiveOffer(
        history: history,
        secondsSinceLastOffer: 300,
        recentDismissals: 0,
        userIsActivelyTyping: true,
        gate: gate
    ) == nil)
}
