import CascadeMemory
import Foundation
import Testing
@testable import WasteDetection

private let episodeMiningBase = Date(timeIntervalSince1970: 1_760_000_000)

private func miningEvent(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind = .click,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    app: String = "Books",
    bundle: String? = nil,
    window: String? = nil
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: episodeMiningBase.addingTimeInterval(seconds),
        kind: kind,
        x: kind == .click ? 10 : nil,
        y: kind == .click ? 10 : nil,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: app,
        bundleIdentifier: bundle,
        windowTitle: window
    )
}

@Test
func defaultEpisodeMiningFlagUsesProductionEpisodePath() {
    var events: [InputEvent] = []
    var id = 0
    for (run, fillerKey) in ["down", "right", "left"].enumerated() {
        let start = TimeInterval(run * 300)
        events.append(miningEvent(id, at: start, text: "Open")); id += 1
        events.append(miningEvent(id, at: start + 1, kind: .key, key: fillerKey)); id += 1
        events.append(miningEvent(id, at: start + 2, kind: .key, key: "c", modifiers: ["command"])); id += 1
        events.append(miningEvent(id, at: start + 3, kind: .key, key: fillerKey)); id += 1
    }

    let detector = WasteDetector()
    let implicit = detector.detect(contexts: [], inputEvents: events)
    let explicitEpisode = detector.detect(contexts: [], inputEvents: events, useEpisodeMining: true)
    let explicitLegacy = detector.detect(contexts: [], inputEvents: events, useEpisodeMining: false)

    #expect(implicit.map(\.signature) == explicitEpisode.map(\.signature))
    #expect(implicit.map(\.occurrences) == explicitEpisode.map(\.occurrences))
    #expect(explicitLegacy.isEmpty)
    #expect(normalizedSignatureTokensForTest(implicit.first?.signature ?? "") == ["click:open@books", "key:command+c@books"])
}

@Test
func episodeMiningRecoversGappedRoutineTheContiguousMinerMisses() throws {
    var events: [InputEvent] = []
    var id = 0
    for (run, fillerKey) in ["down", "right", "left"].enumerated() {
        let start = TimeInterval(run * 300)
        events.append(miningEvent(id, at: start, text: "Open")); id += 1
        events.append(miningEvent(id, at: start + 1, kind: .key, key: fillerKey)); id += 1
        events.append(miningEvent(id, at: start + 2, kind: .key, key: "c", modifiers: ["command"])); id += 1
        events.append(miningEvent(id, at: start + 3, kind: .key, key: fillerKey)); id += 1
    }

    let detector = WasteDetector()
    #expect(detector.detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)

    let firstRun = detector.detect(contexts: [], inputEvents: events)
    let secondRun = detector.detect(contexts: [], inputEvents: events)
    let waste = try #require(firstRun.first)

    #expect(waste.occurrences == 3)
    #expect(normalizedSignatureTokensForTest(waste.signature) == ["click:open@books", "key:command+c@books"])
    #expect(Set(waste.evidence) == Set([0, 2, 4, 6, 8, 10]))
    #expect(waste.recipe.steps.map(\.kind) == [.activateApp, .click, .key])
    #expect(firstRun.map(\.signature) == secondRun.map(\.signature))
    #expect(firstRun.map(\.evidence) == secondRun.map(\.evidence))
}

@Test
func episodeMiningExcludesSensitiveAndNoisySurfaces() {
    let events = [
        miningEvent(0, at: 0, text: "Mute", app: "zoom.us", bundle: "us.zoom.xos"),
        miningEvent(1, at: 1, kind: .key, key: "c", modifiers: ["command"], app: "zoom.us", bundle: "us.zoom.xos"),
        miningEvent(2, at: 300, text: "Mute", app: "zoom.us", bundle: "us.zoom.xos"),
        miningEvent(3, at: 301, kind: .key, key: "c", modifiers: ["command"], app: "zoom.us", bundle: "us.zoom.xos"),
        miningEvent(4, at: 600, text: "Pay", app: "Safari", window: "Bank account"),
        miningEvent(5, at: 601, kind: .key, key: "c", modifiers: ["command"], app: "Safari", window: "Bank account"),
        miningEvent(6, at: 900, text: "Pay", app: "Safari", window: "Bank account"),
        miningEvent(7, at: 901, kind: .key, key: "c", modifiers: ["command"], app: "Safari", window: "Bank account"),
    ]

    let results = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: true)

    #expect(results.isEmpty)
}
