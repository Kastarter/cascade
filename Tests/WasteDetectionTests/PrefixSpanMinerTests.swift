import Foundation
import Testing
import WasteDetection

@Test
func findsGappedRepeatsWithinGapBound() {
    let miner = PrefixSpanMiner(minSupport: 2, maxPatternLength: 3, maxGapEvents: 1, closedOnly: false)

    let patterns = miner.mine(episodes: [
        ["open", "profile", "copy", "paste"],
        ["open", "noise", "profile", "copy", "paste"],
        ["open", "profile", "copy", "paste"]
    ])

    let pattern = patterns.first { $0.tokens == ["open", "profile", "copy"] }
    #expect(pattern?.support == 3)
    #expect(pattern?.occurrenceSpans.contains {
        $0.episodeIndex == 1 && $0.startEventIndex == 0 && $0.endEventIndex == 3
    } == true)
}

@Test
func recoversInterruptedContiguousNGrams() {
    let miner = PrefixSpanMiner(minSupport: 3, maxPatternLength: 4, maxGapEvents: 1)

    let patterns = miner.mine(episodes: [
        ["select", "copy", "paste", "send"],
        ["select", "copy", "note", "paste", "send"],
        ["select", "copy", "paste", "send"]
    ])

    #expect(patterns.first?.tokens == ["select", "copy", "paste", "send"])
    #expect(patterns.first?.support == 3)
}

@Test
func ignoresLowSupportTokens() {
    let miner = PrefixSpanMiner(minSupport: 2, maxPatternLength: 1, maxGapEvents: 0, closedOnly: false)

    let patterns = miner.mine(episodes: [
        ["repeat", "singleton-a"],
        ["repeat", "singleton-b"],
        ["singleton-c"]
    ])

    #expect(patterns.map(\.tokens) == [["repeat"]])
}

@Test
func closedPatternsSuppressRedundantSubpatterns() {
    let miner = PrefixSpanMiner(minSupport: 2, maxPatternLength: 3, maxGapEvents: 0, closedOnly: true)

    let patterns = miner.mine(episodes: [
        ["open", "copy", "paste"],
        ["open", "copy", "paste"],
        ["open", "copy", "paste"]
    ])

    #expect(patterns.map(\.tokens) == [["open", "copy", "paste"]])
}

@Test
func deterministicTieOrderingIsStable() {
    let episodes = [
        ["beta", "gamma"],
        ["alpha", "delta"],
        ["beta", "gamma"],
        ["alpha", "delta"]
    ]
    let miner = PrefixSpanMiner(minSupport: 2, maxPatternLength: 2, maxGapEvents: 0, closedOnly: false)

    let firstRun = miner.mine(episodes: episodes)
    let secondRun = miner.mine(episodes: episodes)
    let twoTokenPatterns = firstRun.filter { $0.tokens.count == 2 }.map(\.tokens)

    #expect(firstRun.map(\.tokens) == secondRun.map(\.tokens))
    #expect(twoTokenPatterns == [["alpha", "delta"], ["beta", "gamma"]])
}

@Test
func maxSpanSecondsBoundsOccurrenceDuration() {
    let miner = PrefixSpanMiner(
        minSupport: 2,
        maxPatternLength: 3,
        maxGapEvents: 0,
        maxSpanSeconds: 3,
        closedOnly: false
    )

    let patterns = miner.mine(episodes: [
        [
            PrefixSpanMiner.Event("open", timestamp: 0),
            PrefixSpanMiner.Event("copy", timestamp: 1),
            PrefixSpanMiner.Event("paste", timestamp: 8)
        ],
        [
            PrefixSpanMiner.Event("open", timestamp: 10),
            PrefixSpanMiner.Event("copy", timestamp: 12),
            PrefixSpanMiner.Event("paste", timestamp: 20)
        ]
    ])

    let shortPattern = patterns.first { $0.tokens == ["open", "copy"] }

    #expect(shortPattern?.support == 2)
    #expect(shortPattern?.occurrenceSpans.compactMap(\.durationSeconds) == [1, 2])
    #expect(patterns.contains { $0.tokens == ["open", "copy", "paste"] } == false)
}

@Test
func maxGapSecondsRejectsLooseConsecutiveMatches() {
    let miner = PrefixSpanMiner(
        minSupport: 2,
        maxPatternLength: 2,
        maxGapEvents: 0,
        maxGapSeconds: 60,
        closedOnly: false
    )

    let patterns = miner.mine(episodes: [
        [
            PrefixSpanMiner.Event("open", timestamp: 0),
            PrefixSpanMiner.Event("copy", timestamp: 120)
        ],
        [
            PrefixSpanMiner.Event("open", timestamp: 200),
            PrefixSpanMiner.Event("copy", timestamp: 320)
        ]
    ])

    #expect(patterns.contains { $0.tokens == ["open", "copy"] } == false)
    #expect(patterns.contains { $0.tokens == ["open"] })
}

@Test
func closedPatternsKeepShorterPatternWhenOccurrenceSpansDiffer() {
    let miner = PrefixSpanMiner(
        minSupport: 2,
        maxPatternLength: 3,
        maxGapEvents: 0,
        closedOnly: true
    )

    let patterns = miner.mine(episodes: [
        [
            PrefixSpanMiner.Event("open", timestamp: 0),
            PrefixSpanMiner.Event("copy", timestamp: 1),
            PrefixSpanMiner.Event("paste", timestamp: 240)
        ],
        [
            PrefixSpanMiner.Event("open", timestamp: 300),
            PrefixSpanMiner.Event("copy", timestamp: 301),
            PrefixSpanMiner.Event("paste", timestamp: 540)
        ]
    ])

    #expect(patterns.contains { $0.tokens == ["open", "copy"] })
    #expect(patterns.contains { $0.tokens == ["open", "copy", "paste"] })
}
