import CascadeMemory
import Foundation
import Testing
@testable import WasteDetection

private let typedActionBase = Date(timeIntervalSince1970: 1_790_000_000)

private func typedActionEvent(
    text: String?,
    kind: InputEventKind = .type,
    window: String? = nil
) -> InputEvent {
    InputEvent(
        id: 1,
        capturedAt: typedActionBase,
        kind: kind,
        text: text,
        appName: "Safari",
        windowTitle: window
    )
}

@Test
func slotClassifiesCommonLocalValueCategories() {
    #expect(TypedActionAbstractor.classifySlotValue("ETH") == .ticker)
    #expect(TypedActionAbstractor.classifySlotValue("SOL") == .ticker)
    #expect(TypedActionAbstractor.classifySlotValue("BTC") == .ticker)
    #expect(TypedActionAbstractor.classifySlotValue("LTC") == .ticker)
    #expect(TypedActionAbstractor.classifySlotValue("$4,201.55") == .number)
    #expect(TypedActionAbstractor.classifySlotValue("2026-07-01") == .date)
    #expect(TypedActionAbstractor.classifySlotValue("https://example.com/path") == .url)
    #expect(TypedActionAbstractor.classifySlotValue("rebalance") == .word)
    #expect(TypedActionAbstractor.classifySlotValue("Ada Lovelace") == .name)
}

@Test
func abstractTokensNeverContainRawSlotValues() {
    let rawValues = ["ETH", "SOL", "BTC", "LTC", "$4,201.55", "https://example.com/secret"]
    let abstractor = TypedActionAbstractor()

    for rawValue in rawValues {
        let action = abstractor.abstract(
            typedActionEvent(text: rawValue, window: "Google \(rawValue) price"),
            surface: "Google"
        )
        let token = action.abstractToken
        #expect(!token.localizedCaseInsensitiveContains(rawValue))
        #expect(token.contains("slot="))
        #expect(token.contains("surface=google"))
    }
}

@Test
func abstractTokensAreStableAcrossDifferentTickerValues() {
    let abstractor = TypedActionAbstractor()
    let eth = abstractor.abstract(typedActionEvent(text: "ETH", window: "Google ETH price"), surface: "Google")
    let sol = abstractor.abstract(typedActionEvent(text: "SOL", window: "Google SOL price"), surface: "Google")

    #expect(eth.abstractToken == sol.abstractToken)
    #expect(eth.dataSlot?.category == .ticker)
    #expect(eth.dataSlot?.valueHash != sol.dataSlot?.valueHash)
}

@Test
func semanticEpisodeClusteringIsDeterministic() {
    let abstractor = TypedActionAbstractor()
    let coins = ["ETH", "SOL", "BTC", "LTC"]
    let episodes = coins.enumerated().map { index, coin in
        let start = typedActionBase.addingTimeInterval(TimeInterval(index * 300))
        let actions = [
            abstractor.abstract(typedActionEvent(text: coin, window: "Google \(coin) price"), surface: "Google"),
            abstractor.abstract(typedActionEvent(text: "Price row", kind: .click, window: "Notion \(coin) row"), surface: "Notion")
        ]
        return TypedActionEpisode(
            index: index,
            actions: actions,
            eventIDs: [Int64(index * 10), Int64(index * 10 + 1)],
            startedAt: start,
            endedAt: start.addingTimeInterval(1)
        )
    }
    let shuffled = [episodes[2], episodes[0], episodes[3], episodes[1]]
    let clusterer = TypedActionEpisodeClusterer()

    let first = clusterer.cluster(shuffled)
    let second = clusterer.cluster(episodes)

    #expect(first == second)
    #expect(first.count == 1)
    #expect(first.first?.episodeIndices == [0, 1, 2, 3])
}
