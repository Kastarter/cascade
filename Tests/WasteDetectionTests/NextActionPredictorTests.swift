import Foundation
import CascadeMemory
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

private let predictorBase = Date(timeIntervalSince1970: 1_720_000_000)

private func predictorEvent(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind = .click,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    app: String = "Safari",
    bundle: String? = nil,
    window: String? = "Invoice Review",
    x: Double? = 10,
    y: Double? = 10,
    descriptor: String? = nil
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: predictorBase.addingTimeInterval(seconds),
        kind: kind,
        x: x,
        y: y,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: app,
        bundleIdentifier: bundle,
        windowTitle: window,
        targetDescriptor: descriptor
    )
}

@Test
func eventTokenCarriesSafeSourceAndTargetMetadata() throws {
    let descriptor = try #require(AXTargetDescriptorV2.encode(
        label: "Approve Request",
        role: "AXButton",
        identifier: "approve.request",
        container: "AXGroup: Review actions"
    ))
    let events = [
        predictorEvent(1, at: 0, text: "Review Request", app: "Google Chrome", window: "Inbox - Gmail"),
        predictorEvent(2, at: 2, kind: .key, key: "a", modifiers: ["command"], app: "Google Chrome", window: "Inbox - Gmail"),
        predictorEvent(3, at: 4, app: "Google Chrome", window: "Inbox - Gmail", descriptor: descriptor),
    ]

    let tokens = NextActionPredictor.tokens(for: events) { event in
        event.windowTitle?.contains("Gmail") == true ? "Gmail" : nil
    }

    #expect(tokens[2].contains("click:Approve Request@Gmail"))
    #expect(tokens[2].contains("app=googlechrome"))
    #expect(tokens[2].contains("surface=gmail"))
    #expect(tokens[2].contains("windowHash="))
    #expect(tokens[2].contains("targetHash="))
    #expect(tokens[2].contains("gap=1-5s"))
    #expect(!tokens[2].contains("schemaVersion"))
    #expect(!tokens[2].contains("{"))
}

@Test
func eventPredictionWeightsRecentEvidence() {
    let predictor = NextActionPredictor(recencyHalfLife: 20)
    var events: [InputEvent] = []
    var id = 0
    func appendRun(start: TimeInterval, next: String, includeNext: Bool = true) {
        events.append(predictorEvent(id, at: start, text: "A")); id += 1
        events.append(predictorEvent(id, at: start + 1, text: "B")); id += 1
        if includeNext {
            events.append(predictorEvent(id, at: start + 2, text: next)); id += 1
        }
    }
    appendRun(start: 0, next: "Old")
    appendRun(start: 10, next: "Old")
    appendRun(start: 1_000, next: "Recent")
    appendRun(start: 1_003, next: "Recent", includeNext: false)

    let prediction = predictor.predict(events: events)

    #expect(prediction?.token.contains("Recent") == true)
    #expect(prediction?.evidenceCount == 1)
    #expect(prediction?.sourceWindow == "Invoice Review")
}

@Test
func timeGapBucketSeparatesOtherwiseIdenticalContexts() {
    let predictor = NextActionPredictor(recencyHalfLife: 10_000)
    var events: [InputEvent] = []
    var id = 0
    func appendRun(start: TimeInterval, gap: TimeInterval, next: String, includeNext: Bool = true) {
        events.append(predictorEvent(id, at: start, text: "A")); id += 1
        events.append(predictorEvent(id, at: start + gap, text: "B")); id += 1
        if includeNext {
            events.append(predictorEvent(id, at: start + gap + 1, text: next)); id += 1
        }
    }
    appendRun(start: 0, gap: 2, next: "Fast")
    appendRun(start: 20, gap: 2, next: "Fast")
    appendRun(start: 100, gap: 20, next: "Slow")
    appendRun(start: 150, gap: 20, next: "Slow")
    appendRun(start: 200, gap: 20, next: "Slow", includeNext: false)

    let prediction = predictor.predict(events: events)

    #expect(prediction?.token.contains("Slow") == true)
    #expect(prediction?.support == 2)
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

@Test
func structuredGateSuppressesHardBoundariesAndAllowsCheapBoundary() {
    let gate = InterruptibilityGate()
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, isPrivacySensitive: true)) == .suppress(reason: "privacy.sensitive"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, secureInputActive: true)) == .suppress(reason: "input.secure"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, modifierHeavyKeySequence: true)) == .suppress(reason: "input.modifier_sequence"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, draggingOrSelecting: true)) == .suppress(reason: "input.drag_or_selection"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, agentRunning: true)) == .suppress(reason: "agent.running"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, permissionsHealthy: false)) == .suppress(reason: "permissions.unhealthy"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, noisySurface: true)) == .suppress(reason: "surface.noisy"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, perSignatureSnoozed: true)) == .suppress(reason: "snooze.signature"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, requiresBoundary: true)) == .suppress(reason: "boundary.missing"))
    #expect(gate.decide(InterruptibilityContext(confidence: 0.9, boundary: .completionControl, requiresBoundary: true)) == .offer)
}

@Test
func struggleDetectorFindsRepeatedClickLoop() {
    let events = [
        predictorEvent(1, at: 0, text: "Retry", x: 42, y: 99),
        predictorEvent(2, at: 2, text: "Retry", x: 42, y: 99),
        predictorEvent(3, at: 4, text: "Retry", x: 42, y: 99),
    ]

    #expect(StruggleDetector().detect(events: events)?.kind == .repeatedClick)
}

@Test
func struggleDetectorFindsUndoCancelLoops() {
    let events = [
        predictorEvent(1, at: 0, kind: .key, key: "z", modifiers: ["command"]),
        predictorEvent(2, at: 2, kind: .key, key: "escape"),
        predictorEvent(3, at: 4, kind: .key, key: "delete"),
    ]

    #expect(StruggleDetector().detect(events: events)?.kind == .undoCancelLoop)
}

@Test
func struggleDetectorFindsRepeatedErrorText() {
    let contexts = [
        RecordedContext(capturedAt: predictorBase, source: .screen, appName: "Safari", windowTitle: "Upload failed", ocrText: "Error: try again"),
        RecordedContext(capturedAt: predictorBase.addingTimeInterval(2), source: .screen, appName: "Safari", windowTitle: "Upload failed", ocrText: "Error: try again"),
    ]

    #expect(StruggleDetector().detect(events: [], contexts: contexts)?.kind == .repeatedError)
}

@Test
func struggleDetectorFindsSearchRewriteLoop() {
    let events = [
        predictorEvent(1, at: 0, kind: .type, text: "typed 3 chars", window: "Search customers"),
        predictorEvent(2, at: 2, kind: .type, text: "typed 5 chars", window: "Search customers"),
        predictorEvent(3, at: 4, kind: .type, text: "typed 2 chars", window: "Search customers"),
    ]

    #expect(StruggleDetector().detect(events: events)?.kind == .searchRewrite)
}

@Test
func struggleDetectorFindsScrollOscillation() {
    let events = [
        predictorEvent(1, at: 0, kind: .scroll, modifiers: ["0", "1"]),
        predictorEvent(2, at: 1, kind: .scroll, modifiers: ["0", "-1"]),
        predictorEvent(3, at: 2, kind: .scroll, modifiers: ["0", "1"]),
        predictorEvent(4, at: 3, kind: .scroll, modifiers: ["0", "-1"]),
        predictorEvent(5, at: 4, kind: .scroll, modifiers: ["0", "1"]),
    ]

    #expect(StruggleDetector().detect(events: events)?.kind == .scrollOscillation)
}

@Test
func struggleDetectorFindsFlailingAfterIdleButIgnoresNormalTypingAndReadingScrolls() {
    let flailing = [
        predictorEvent(1, at: 0, text: "Inbox"),
        predictorEvent(2, at: 90, text: "A"),
        predictorEvent(3, at: 92, kind: .key, key: "escape"),
        predictorEvent(4, at: 94, text: "B", x: 100, y: 100),
        predictorEvent(5, at: 96, kind: .scroll, modifiers: ["0", "1"]),
        predictorEvent(6, at: 98, kind: .key, key: "tab"),
        predictorEvent(7, at: 100, text: "C", x: 180, y: 120),
    ]
    let typing = (0..<8).map {
        predictorEvent($0, at: TimeInterval($0), kind: .type, text: "typed \($0 + 1) chars", app: "Notes")
    }
    let readingScroll = (0..<6).map {
        predictorEvent($0, at: TimeInterval($0), kind: .scroll, modifiers: ["0", "1"], app: "Safari")
    }

    #expect(StruggleDetector().detect(events: flailing)?.kind == .flailingAfterIdle)
    #expect(StruggleDetector().detect(events: typing) == nil)
    #expect(StruggleDetector().detect(events: readingScroll) == nil)
}
