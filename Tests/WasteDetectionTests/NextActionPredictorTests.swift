import Foundation
import Testing
import WasteDetection

// MARK: - Predictor

@Test
func predictsRepeatedNextActionWithHighConfidence() {
    let predictor = NextActionPredictor()
    // A,B,C repeated — after the current [A,B] the user always did C.
    let history = ["A", "B", "C", "A", "B", "C", "A", "B"]
    let prediction = predictor.predict(history: history)
    #expect(prediction?.token == "C")
    #expect(prediction?.confidence == 1.0)
    #expect((prediction?.support ?? 0) >= 2)
}

@Test
func backsOffToShorterContext() {
    let predictor = NextActionPredictor(maxOrder: 3)
    // The trigram context [X,B] is unseen earlier, but the bigram context [B] is
    // followed by C twice — back-off should still predict C.
    let history = ["B", "C", "Q", "B", "C", "Z", "X", "B"]
    let prediction = predictor.predict(history: history)
    #expect(prediction?.token == "C")
}

@Test
func returnsNilWhenNothingRecurs() {
    let predictor = NextActionPredictor()
    #expect(predictor.predict(history: ["A", "B", "C", "D"]) == nil)
    #expect(predictor.predict(history: ["A"]) == nil)
    #expect(predictor.predict(history: []) == nil)
}

@Test
func confidenceReflectsBranching() {
    let predictor = NextActionPredictor()
    // After [A], C appears twice and D once → P(C)=2/3.
    let history = ["A", "C", "A", "D", "A", "C", "A"]
    let prediction = predictor.predict(history: history)
    #expect(prediction?.token == "C")
    #expect(abs((prediction?.confidence ?? 0) - 2.0 / 3.0) < 1e-9)
}

// MARK: - Interruptibility gate

@Test
func gateOffersOnlyWhenItIsWelcome() {
    let gate = InterruptibilityGate(minConfidence: 0.6, cooldownSeconds: 120, maxRecentDismissalsBeforeMute: 3)
    // Ideal conditions → offer.
    #expect(gate.shouldOffer(confidence: 0.9, secondsSinceLastOffer: 300, recentDismissals: 0, userIsActivelyTyping: false))
    // Each guard suppresses.
    #expect(!gate.shouldOffer(confidence: 0.9, secondsSinceLastOffer: 300, recentDismissals: 0, userIsActivelyTyping: true))
    #expect(!gate.shouldOffer(confidence: 0.4, secondsSinceLastOffer: 300, recentDismissals: 0, userIsActivelyTyping: false))
    #expect(!gate.shouldOffer(confidence: 0.9, secondsSinceLastOffer: 10, recentDismissals: 0, userIsActivelyTyping: false))
    #expect(!gate.shouldOffer(confidence: 0.9, secondsSinceLastOffer: 300, recentDismissals: 3, userIsActivelyTyping: false))
}

@Test
func gateReasonsAreReported() {
    let gate = InterruptibilityGate()
    if case .suppress(let reason) = gate.decide(confidence: 0.9, secondsSinceLastOffer: 300, recentDismissals: 0, userIsActivelyTyping: true) {
        #expect(reason.contains("typing"))
    } else {
        Issue.record("expected suppression while typing")
    }
}
