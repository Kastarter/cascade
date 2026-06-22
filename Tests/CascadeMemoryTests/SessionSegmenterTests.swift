import CascadeMemory
import Foundation
import Testing

/// Pure tests for the LLM-free session segmenter — the engine that turns a flat
/// frame log into work sessions for episode-level recall.

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func moment(_ id: Int64, app: String, bundle: String? = nil, title: String? = nil, at offset: TimeInterval) -> RecordedContext {
    RecordedContext(
        id: id,
        capturedAt: base.addingTimeInterval(offset),
        source: .screen,
        appName: app,
        bundleIdentifier: bundle,
        windowTitle: title,
        ocrText: nil
    )
}

@Test
func segmenterSplitsOnAppSwitch() {
    let episodes = SessionSegmenter.segment([
        moment(1, app: "Keynote", at: 0),
        moment(2, app: "Keynote", at: 30),
        moment(3, app: "Mail", at: 60),
        moment(4, app: "Mail", at: 90),
    ])
    #expect(episodes.count == 2)
    #expect(episodes[0].appName == "Keynote")
    #expect(episodes[0].id == 1)              // anchored on the first moment
    #expect(episodes[0].momentIDs == [1, 2])
    #expect(episodes[1].appName == "Mail")
    #expect(episodes[1].momentIDs == [3, 4])
}

@Test
func segmenterSplitsOnLongIdleGapWithinOneApp() {
    // Same app, but a gap longer than maxGap means the session ended and a new
    // one began (you left and came back to the same app).
    let episodes = SessionSegmenter.segment([
        moment(1, app: "Xcode", at: 0),
        moment(2, app: "Xcode", at: 60),
        moment(3, app: "Xcode", at: 60 + 700),   // 700s > 600s default → split
        moment(4, app: "Xcode", at: 60 + 730),
    ])
    #expect(episodes.count == 2)
    #expect(episodes[0].momentIDs == [1, 2])
    #expect(episodes[1].momentIDs == [3, 4])
}

@Test
func segmenterKeepsOneSessionAcrossShortGaps() {
    // A static screen (dedup skips identical frames) leaves real gaps inside one
    // session — a sub-maxGap pause must NOT split it.
    let episodes = SessionSegmenter.segment([
        moment(1, app: "Figma", at: 0),
        moment(2, app: "Figma", at: 300),     // 5-min reading pause, under 600s
        moment(3, app: "Figma", at: 360),
    ])
    #expect(episodes.count == 1)
    #expect(episodes[0].momentCount == 3)
    #expect(episodes[0].duration == 360)
}

@Test
func segmenterDistinguishesAppsByBundleIdNotJustName() {
    // Two apps can share a display name; bundle id is the real identity.
    let episodes = SessionSegmenter.segment([
        moment(1, app: "Helper", bundle: "com.a.helper", at: 0),
        moment(2, app: "Helper", bundle: "com.b.helper", at: 20),
    ])
    #expect(episodes.count == 2)
}

@Test
func segmenterPicksMostFrequentTitleTiesToEarliest() {
    #expect(SessionSegmenter.representativeTitle([
        moment(1, app: "Pages", title: "Draft", at: 0),
        moment(2, app: "Pages", title: "Final", at: 10),
        moment(3, app: "Pages", title: "Final", at: 20),
    ]) == "Final")
    // Tie on count → earliest seen wins.
    #expect(SessionSegmenter.representativeTitle([
        moment(1, app: "Pages", title: "First", at: 0),
        moment(2, app: "Pages", title: "Second", at: 10),
    ]) == "First")
    // No titles at all → nil.
    #expect(SessionSegmenter.representativeTitle([moment(1, app: "Pages", at: 0)]) == nil)
}

@Test
func segmenterHandlesEmptySingleAndUnorderedInput() {
    #expect(SessionSegmenter.segment([]).isEmpty)

    let single = SessionSegmenter.segment([moment(1, app: "Notes", at: 0)])
    #expect(single.count == 1)
    #expect(single[0].duration == 0)

    // Out-of-order input is sorted oldest-first before segmenting.
    let ordered = SessionSegmenter.segment([
        moment(2, app: "Notes", at: 60),
        moment(1, app: "Notes", at: 0),
    ])
    #expect(ordered.count == 1)
    #expect(ordered[0].id == 1)               // anchor is the earliest moment
    #expect(ordered[0].momentIDs == [1, 2])
}
