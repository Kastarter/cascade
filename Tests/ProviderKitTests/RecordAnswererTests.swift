import CascadeMemory
import Foundation
import ProviderKit
import Testing

@Test
func stableSystemPromptIsByteIdenticalAcrossCallsAndCarriesNoClock() {
    let a = RecordSearchAnswerer.stableSystemPrompt()
    let b = RecordSearchAnswerer.stableSystemPrompt()
    #expect(a == b)                                   // cacheable: identical across hops
    #expect(!a.contains("Current time:"))             // the clock is NOT in the cached prefix
    // No ISO timestamp leaked into the stable prefix.
    #expect(a.range(of: #"\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) == nil)
}

@Test
func timeContextCarriesTheVolatileClock() {
    let note = RecordSearchAnswerer.timeContext()
    #expect(note.contains("Current time:"))
    #expect(note.range(of: #"\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil)
}

@Test
func citationsParseFromSourcesLine() {
    let answer = RecordSearchAnswerer.parseCitations(
        from: "You were comparing flight prices around 2pm.\nSOURCES: #42, #87"
    )
    #expect(answer.text == "You were comparing flight prices around 2pm.")
    #expect(answer.citedMomentIDs == [42, 87])
}

@Test
func inlineCitationMarkersAreCollectedAndStripped() {
    let answer = RecordSearchAnswerer.parseCitations(
        from: "The deadline was Friday [#12] and you noted it in Things [#12] [#9]."
    )
    #expect(answer.text == "The deadline was Friday and you noted it in Things.")
    #expect(answer.citedMomentIDs == [12, 9]) // deduped, order preserved
}

@Test
func answersWithoutSourcesHaveNoCitations() {
    let answer = RecordSearchAnswerer.parseCitations(from: "The record doesn't cover that.")
    #expect(answer.text == "The record doesn't cover that.")
    #expect(answer.citedMomentIDs.isEmpty)
}

@Test
func citationsAreCappedAtFour() {
    let answer = RecordSearchAnswerer.parseCitations(from: "x\nSOURCES: #1, #2, #3, #4, #5, #6")
    #expect(answer.citedMomentIDs.count == 4)
}

@Test
func recordSearchAnswererConfiguresHeuristicRecallRerankerWithoutNetwork() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRecordAnswererTests-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let answerer = RecordSearchAnswerer(store: store)

    #expect(answerer.usesRerankedRecall)
    #expect(answerer.configuredToolDefinitions().contains { ($0["name"] as? String) == "search_record" })
}
