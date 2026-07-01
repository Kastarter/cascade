import CascadeMemory
import Foundation
import Testing
@testable import WasteDetection

private let parameterizedMiningBase = Date(timeIntervalSince1970: 1_791_000_000)

private func parameterizedSurface(_ event: InputEvent) -> String? {
    let title = event.windowTitle ?? ""
    if title.localizedCaseInsensitiveContains("Google") { return "Google" }
    if title.localizedCaseInsensitiveContains("Notion") { return "Notion" }
    return nil
}

private func parameterizedEvent(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    window: String
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: parameterizedMiningBase.addingTimeInterval(seconds),
        kind: kind,
        x: kind == .click ? 20 : nil,
        y: kind == .click ? 20 : nil,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: window
    )
}

private func cryptoPriceFixture() -> [InputEvent] {
    var events: [InputEvent] = []
    var id = 0
    let noiseCounts = [301, 301, 301, 304]

    for (run, coin) in ["ETH", "SOL", "BTC", "LTC"].enumerated() {
        let start = TimeInterval(run * 2_000)
        let googleWindow = "\(coin) price - Google - Safari"
        let notionWindow = "\(coin) tracker - Notion - Safari"
        events.append(parameterizedEvent(id, at: start, kind: .click, text: "Search", window: googleWindow)); id += 1
        events.append(parameterizedEvent(id, at: start + 1, kind: .type, text: coin, window: googleWindow)); id += 1
        events.append(parameterizedEvent(id, at: start + 2, kind: .key, key: "Return", window: googleWindow)); id += 1
        events.append(parameterizedEvent(id, at: start + 3, kind: .click, text: "Price result", window: googleWindow)); id += 1
        events.append(parameterizedEvent(id, at: start + 4, kind: .key, key: "c", modifiers: ["command"], window: googleWindow)); id += 1
        events.append(parameterizedEvent(id, at: start + 5, kind: .click, text: "\(coin) tracker row", window: notionWindow)); id += 1
        events.append(parameterizedEvent(id, at: start + 6, kind: .key, key: "v", modifiers: ["command"], window: notionWindow)); id += 1

        let noiseStart = start + 220
        for offset in 0..<noiseCounts[run] {
            events.append(parameterizedEvent(
                id,
                at: noiseStart + TimeInterval(offset * 4),
                kind: .scroll,
                window: "Research noise \(run)"
            ))
            id += 1
        }
    }

    #expect(events.count == 1_235)
    return events.sorted {
        if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
        return $0.capturedAt < $1.capturedAt
    }
}

@Test
func cryptoFixtureLiteralPathYieldsNoCandidatesButParameterizedPathFindsOne() throws {
    let events = cryptoPriceFixture()
    let detector = WasteDetector()

    let literal = detector.detect(
        contexts: [],
        inputEvents: events,
        maxResults: 5,
        webAppIdentity: parameterizedSurface,
        useEpisodeMining: true,
        useParameterizedMining: false
    )
    #expect(literal.isEmpty)

    let parameterized = detector.detect(
        contexts: [],
        inputEvents: events,
        maxResults: 5,
        webAppIdentity: parameterizedSurface,
        useEpisodeMining: true,
        useParameterizedMining: true
    )

    #expect(parameterized.count == 1)
    let waste = try #require(parameterized.first)
    #expect(waste.occurrences == 4)
    let parameterSteps = waste.recipe.steps.filter(\.isParameter)
    #expect(parameterSteps.count == 1)
    let parameter = try #require(parameterSteps.first)
    #expect(parameter.parameterKind == .ticker)
    #expect(parameter.valueHashes.count == 4)
    #expect(parameter.valueExamples.allSatisfy { $0.hasPrefix("ticker:") })
}

@Test
func parameterizedMiningDoesNotLeakRawTickerValues() throws {
    let waste = try #require(WasteDetector().detect(
        contexts: [],
        inputEvents: cryptoPriceFixture(),
        maxResults: 5,
        webAppIdentity: parameterizedSurface,
        useEpisodeMining: true,
        useParameterizedMining: true
    ).first)
    let exposed = [
        waste.signature,
        waste.title,
        waste.recipe.steps.map { $0.valueExamples.joined(separator: "|") }.joined(separator: "|"),
        waste.recipe.humanSteps.joined(separator: "|")
    ].joined(separator: "\n")

    for raw in ["ETH", "SOL", "BTC", "LTC"] {
        #expect(!exposed.localizedCaseInsensitiveContains(raw))
    }
}
