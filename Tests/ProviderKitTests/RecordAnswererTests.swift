import ProviderKit
import Testing

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
