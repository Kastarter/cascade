import CascadeMemory
import Foundation
import Testing
import WasteDetection

private let routineEvalBase = Date(timeIntervalSince1970: 1_780_000_000)

private struct RoutineMiningFixture {
    let name: String
    let events: [InputEvent]
    let expectedSignatures: [String]
    let negativeTokens: [String]
}

private func evalEvent(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind = .click,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    app: String
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: routineEvalBase.addingTimeInterval(seconds),
        kind: kind,
        x: kind == .click ? 10 : nil,
        y: kind == .click ? 10 : nil,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: app
    )
}

private func routineMiningFixtures() -> [RoutineMiningFixture] {
    var fixtures: [RoutineMiningFixture] = []

    var exact: [InputEvent] = []
    var id = 0
    for run in 0..<3 {
        let start = TimeInterval(run * 300)
        exact.append(evalEvent(id, at: start, text: "Open", app: "Mail")); id += 1
        exact.append(evalEvent(id, at: start + 1, kind: .key, key: "c", modifiers: ["command"], app: "Mail")); id += 1
    }
    fixtures.append(RoutineMiningFixture(
        name: "exact repeat",
        events: exact,
        expectedSignatures: ["click:open@Mail|key:command+c@Mail"],
        negativeTokens: []
    ))

    var noisy: [InputEvent] = []
    id = 100
    for (run, filler) in ["down", "left", "right"].enumerated() {
        let start = TimeInterval(run * 300)
        noisy.append(evalEvent(id, at: start, text: "Open", app: "Books")); id += 1
        noisy.append(evalEvent(id, at: start + 1, kind: .key, key: filler, app: "Books")); id += 1
        noisy.append(evalEvent(id, at: start + 2, kind: .key, key: "c", modifiers: ["command"], app: "Books")); id += 1
    }
    fixtures.append(RoutineMiningFixture(
        name: "repeat with noisy event",
        events: noisy,
        expectedSignatures: ["click:open@Books|key:command+c@Books"],
        negativeTokens: ["key:down@Books"]
    ))

    var variants: [InputEvent] = []
    id = 200
    for (run, target) in ["Row", "Row", "Cell"].enumerated() {
        let start = TimeInterval(run * 300)
        variants.append(evalEvent(id, at: start, text: "Open", app: "Mail")); id += 1
        variants.append(evalEvent(id, at: start + 1, kind: .key, key: "c", modifiers: ["command"], app: "Mail")); id += 1
        variants.append(evalEvent(id, at: start + 2, text: target, app: "Numbers")); id += 1
        variants.append(evalEvent(id, at: start + 3, kind: .key, key: "v", modifiers: ["command"], app: "Numbers")); id += 1
    }
    fixtures.append(RoutineMiningFixture(
        name: "variants merge",
        events: variants,
        expectedSignatures: ["click:open@Mail|key:command+c@Mail|click:row@Numbers|key:command+v@Numbers"],
        negativeTokens: []
    ))

    var parameterized: [InputEvent] = []
    id = 300
    for (run, value) in ["INV-001", "INV-002", "INV-003"].enumerated() {
        let start = TimeInterval(run * 300)
        parameterized.append(evalEvent(id, at: start, text: "Invoice number", app: "Mail")); id += 1
        parameterized.append(evalEvent(id, at: start + 1, kind: .key, key: "c", modifiers: ["command"], app: "Mail")); id += 1
        parameterized.append(evalEvent(id, at: start + 2, text: "Invoice number", app: "Numbers")); id += 1
        parameterized.append(evalEvent(id, at: start + 3, kind: .type, text: value, app: "Numbers")); id += 1
        parameterized.append(evalEvent(id, at: start + 4, kind: .key, key: "s", modifiers: ["command"], app: "Numbers")); id += 1
    }
    fixtures.append(RoutineMiningFixture(
        name: "cross-app copy/paste with parameter",
        events: parameterized,
        expectedSignatures: ["click:invoice number@Mail|key:command+c@Mail|click:invoice number@Numbers|type@Numbers|key:command+s@Numbers"],
        negativeTokens: []
    ))

    var negative: [InputEvent] = []
    id = 400
    for run in 0..<3 {
        let start = TimeInterval(run * 300)
        negative.append(evalEvent(id, at: start, kind: .type, text: "draft text", app: "Notes")); id += 1
        negative.append(evalEvent(id, at: start + 1, kind: .key, key: "Delete", app: "Notes")); id += 1
        negative.append(evalEvent(id, at: start + 2, text: "Mute", app: "zoom.us")); id += 1
    }
    fixtures.append(RoutineMiningFixture(
        name: "editing and meeting noise",
        events: negative,
        expectedSignatures: [],
        negativeTokens: ["type@Notes", "click:mute@zoom.us"]
    ))

    return fixtures
}

@Test
func defaultEpisodeMiningPipelineMeetsOfflineFixtureThresholds() {
    let fixtures = routineMiningFixtures()
    let detector = WasteDetector()
    let resultsByFixture = fixtures.map { fixture in
        (fixture, detector.detect(contexts: [], inputEvents: fixture.events, maxResults: 5))
    }

    let precision = precisionAtK(resultsByFixture.flatMap(\.1), expected: fixtures.flatMap(\.expectedSignatures), k: 5)
    let recall = recallKnownRoutines(resultsByFixture)
    let negativesSurfaced = resultsByFixture.contains { fixture, results in
        results.contains { result in
            fixture.negativeTokens.contains { result.signature.contains($0) }
        }
    }

    #expect(precision >= 0.60)
    #expect(recall >= 0.75)
    #expect(!negativesSurfaced)
}

private func precisionAtK(_ results: [DetectedWaste], expected: [String], k: Int) -> Double {
    let top = Array(results.prefix(k))
    guard !top.isEmpty else { return expected.isEmpty ? 1 : 0 }
    let hits = top.count { result in expected.contains { signaturesMatch(result.signature, $0) } }
    return Double(hits) / Double(top.count)
}

private func recallKnownRoutines(_ resultsByFixture: [(RoutineMiningFixture, [DetectedWaste])]) -> Double {
    let expected = resultsByFixture.flatMap { fixture, _ in fixture.expectedSignatures.map { (fixture.name, $0) } }
    guard !expected.isEmpty else { return 1 }
    let hits = expected.count { fixtureName, expectedSignature in
        guard let results = resultsByFixture.first(where: { $0.0.name == fixtureName })?.1 else { return false }
        return results.contains { signaturesMatch($0.signature, expectedSignature) }
    }
    return Double(hits) / Double(expected.count)
}

private func signaturesMatch(_ actual: String, _ expected: String) -> Bool {
    let actualTokens = actual.components(separatedBy: "|")
    let expectedTokens = expected.components(separatedBy: "|")
    return normalizedLevenshtein(actualTokens, expectedTokens) >= 0.70
        || jaccard(Set(actualTokens), Set(expectedTokens)) >= 0.70
}

private func normalizedLevenshtein(_ a: [String], _ b: [String]) -> Double {
    let longest = max(a.count, b.count)
    guard longest > 0 else { return 1 }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return 1.0 - Double(previous[b.count]) / Double(longest)
}

private func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
    let union = a.union(b)
    guard !union.isEmpty else { return 1 }
    return Double(a.intersection(b).count) / Double(union.count)
}
