import CascadeMemory
import Foundation
import Testing

private struct RecallEvalCase {
    let category: String
    let query: String
    let expectedID: Int64?
    let hard: Bool
}

private func makeRecallEvalStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRecallEvalTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func recallEvaluationHarnessCoversDeterministicUserStyleCases() async throws {
    let store = try makeRecallEvalStore()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var cases: [RecallEvalCase] = []

    for index in 0..<25 {
        let context = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(Double(index)),
            source: .screen,
            appName: "Safari",
            windowTitle: "Exact Lookup \(index)",
            ocrText: "exactcase\(index) quarterly revenue projection and board memo"))
        cases.append(.init(category: "exact", query: "exactcase\(index) revenue", expectedID: context.id, hard: true))
    }

    for index in 0..<20 {
        let context = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(1_000 + Double(index)),
            source: .screen,
            appName: "Maps",
            windowTitle: "Tokyo Trip \(index)",
            ocrText: "semanticcase\(index) Tokyo itinerary hotel train reservations"))
        cases.append(.init(category: "semantic-ablation", query: "semanticcase\(index) japan travel", expectedID: context.id, hard: false))
    }

    for index in 0..<20 {
        let context = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(2_000 + Double(index)),
            source: .screen,
            appName: index.isMultiple(of: 2) ? "Calendar" : "Slack",
            windowTitle: "Temporal App \(index)",
            ocrText: "temporalscope\(index) standup notes and action items"))
        cases.append(.init(category: "temporal-app", query: "temporalscope\(index) \(context.appName)", expectedID: context.id, hard: true))
    }

    for index in 0..<25 {
        let context = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(3_000 + Double(index)),
            source: .screen,
            appName: "Finder",
            windowTitle: "Project Files \(index)",
            ocrText: "entitycase\(index) /Users/mohanadbahammam/Documents/project-\(index)-brief.pdf owner reviewer"))
        cases.append(.init(category: "entity-file", query: "entitycase\(index) project \(index) brief", expectedID: context.id, hard: true))
    }

    for index in 0..<5 {
        cases.append(.init(category: "negative", query: "missingcase\(index) nowhere", expectedID: nil, hard: true))
    }
    for index in 0..<5 {
        _ = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(4_000 + Double(index)),
            source: .screen,
            appName: "Safari",
            windowTitle: "1Password",
            ocrText: "sensitivecase\(index) vault password token"))
        cases.append(.init(category: "sensitive", query: "sensitivecase\(index)", expectedID: nil, hard: true))
    }

    #expect(cases.count == 100)

    let started = Date()
    var positiveCount = 0
    var recallAt5Hits = 0
    var reciprocalRankTotal = 0.0
    var hardFailures: [RecallEvalCase] = []

    for testCase in cases {
        let hits = try await store.hybridContexts(matching: testCase.query, limit: 5)
            .filter { !PrivacyRules.isSensitive($0) }
        let ids = hits.map(\.id)
        if let expected = testCase.expectedID {
            positiveCount += 1
            if let rank = ids.firstIndex(of: expected) {
                recallAt5Hits += 1
                reciprocalRankTotal += 1.0 / Double(rank + 1)
            } else if testCase.hard {
                hardFailures.append(testCase)
            }
        } else if testCase.hard, !ids.isEmpty {
            hardFailures.append(testCase)
        }
    }

    let recallAt5 = Double(recallAt5Hits) / Double(max(positiveCount, 1))
    let mrrAt10 = reciprocalRankTotal / Double(max(positiveCount, 1))
    #expect(hardFailures.isEmpty)
    #expect(recallAt5 > 0.65)
    #expect(mrrAt10 > 0.65)

    let citationCase = try #require(cases.first { $0.category == "exact" && $0.expectedID != nil })
    let citationHits = try await store.hybridContexts(matching: citationCase.query, limit: 5)
        .filter { !PrivacyRules.isSensitive($0) }
    let recallOutput = citationHits
        .map { "[#\($0.id)] \($0.appName) \(($0.ocrText ?? "").prefix(80))" }
        .joined(separator: "\n")
    let citedIDs = RecallEvalCitationParser.ids(in: recallOutput)
    let citationPrecision = Double(citedIDs.filter { $0 == citationCase.expectedID }.count) / Double(max(citedIDs.count, 1))
    #expect(citedIDs.contains(citationCase.expectedID ?? -1))
    #expect(citationPrecision > 0)

    let elapsed = Date().timeIntervalSince(started)
    let throughput = Double(cases.count) / max(elapsed, 0.001)
    let memoryEvents = try await store.memoryEvents(limit: 200)
    let storageCounter = memoryEvents.reduce(0) { $0 + $1.summary.utf8.count + $1.entitiesJSON.utf8.count + $1.linksJSON.utf8.count }
    #expect(elapsed >= 0)
    #expect(throughput > 0)
    #expect(storageCounter > 0)
}

private enum RecallEvalCitationParser {
    static func ids(in output: String) -> [Int64] {
        guard let regex = try? NSRegularExpression(pattern: #"\[#(\d+)\]"#) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            Range(match.range(at: 1), in: output).flatMap { Int64(output[$0]) }
        }
    }
}
