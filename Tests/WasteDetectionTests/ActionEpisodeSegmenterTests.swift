import CascadeMemory
import Foundation
@testable import WasteDetection
import Testing

private let segmentBase = Date(timeIntervalSince1970: 1_720_000_000)

private func input(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind = .click,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    app: String = "Mail",
    bundle: String? = nil,
    window: String? = nil
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: segmentBase.addingTimeInterval(seconds),
        kind: kind,
        x: kind == .click ? 12 : nil,
        y: kind == .click ? 12 : nil,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: app,
        bundleIdentifier: bundle,
        windowTitle: window
    )
}

@Test
func idleGapCreatesOrderedEpisodeBoundary() {
    let segmenter = ActionEpisodeSegmenter(maxIdleGap: 60)
    let episodes = segmenter.segment([
        input(3, at: 125, text: "Archive"),
        input(1, at: 0, text: "Inbox"),
        input(2, at: 10, text: "Open"),
    ])

    #expect(episodes.map(\.eventIDs) == [[1, 2], [3]])
    #expect(episodes[0].startAt == segmentBase)
    #expect(episodes[0].endAt == segmentBase.addingTimeInterval(10))
    #expect(episodes[0].boundaryReasons == [.idleGap])
}

@Test
func surfaceAndWindowSwitchesSplitWithoutContinuity() {
    let segmenter = ActionEpisodeSegmenter()
    let episodes = segmenter.segment([
        input(1, at: 0, text: "Inbox", app: "Mail", window: "Inbox"),
        input(2, at: 3, text: "Open", app: "Mail", window: "Archive"),
        input(3, at: 6, text: "Cell A1", app: "Numbers", window: "Budget"),
    ])

    #expect(episodes.map(\.eventIDs) == [[1], [2], [3]])
    #expect(episodes[0].boundaryReasons == [.windowSwitch])
    #expect(episodes[1].boundaryReasons == [.surfaceSwitch, .windowSwitch])
    #expect(episodes.map(\.surfaceFlow) == [["Mail"], ["Mail"], ["Numbers"]])
}

@Test
func crossAppCopyPasteContinuityKeepsOneEpisode() {
    let segmenter = ActionEpisodeSegmenter()
    let episodes = segmenter.segment([
        input(1, at: 0, text: "Invoice Total", app: "Mail", window: "Invoice"),
        input(2, at: 1, kind: .key, key: "c", modifiers: ["command"], app: "Mail", window: "Invoice"),
        input(3, at: 4, text: "B4", app: "Numbers", window: "Budget"),
        input(4, at: 5, kind: .key, key: "v", modifiers: ["command"], app: "Numbers", window: "Budget"),
    ])

    #expect(episodes.count == 1)
    #expect(episodes[0].eventIDs == [1, 2, 3, 4])
    #expect(episodes[0].surfaceFlow == ["Mail", "Numbers"])
    #expect(episodes[0].windowTitles == ["Invoice", "Budget"])
    #expect(!episodes[0].boundaryReasons.contains(.surfaceSwitch))
}

@Test
func repeatedDataTokenKeepsWindowSwitchContinuous() {
    let segmenter = ActionEpisodeSegmenter()
    let episodes = segmenter.segment([
        input(1, at: 0, text: "Invoice 142", app: "Mail", window: "Search Results"),
        input(2, at: 5, text: "Invoice 142", app: "Mail", window: "Invoice Detail"),
    ])

    #expect(episodes.count == 1)
    #expect(episodes[0].eventIDs == [1, 2])
    #expect(episodes[0].windowTitles == ["Search Results", "Invoice Detail"])
}

@Test
func saveAndSendCompletionControlsCloseEpisodes() {
    let segmenter = ActionEpisodeSegmenter()
	    let episodes = segmenter.segment([
	        input(1, at: 0, text: "Edit", app: "Notes"),
	        input(2, at: 2, text: "Save", app: "Notes"),
	        input(3, at: 4, text: "Compose", app: "Mail"),
	        input(4, at: 7, text: "Send Message", app: "Mail"),
	        input(5, at: 9, text: "Inbox", app: "Mail"),
	    ])
	
	    #expect(episodes.map(\.eventIDs) == [[1, 2], [3, 4], [5]])
	    #expect(episodes.map(\.boundaryReasons) == [[.completionControl], [.completionControl], [.completionControl]])
	}

@Test
func noisyAndSensitiveSurfacesAreExcludedAndBoundariesRemainVisible() {
    let segmenter = ActionEpisodeSegmenter()
    let episodes = segmenter.segment([
        input(1, at: 0, text: "Inbox", app: "Mail"),
        input(2, at: 1, text: "Mute", app: "zoom.us", bundle: "us.zoom.xos"),
        input(3, at: 2, text: "Reply", app: "Mail"),
        input(4, at: 3, text: "Pay", app: "Safari", window: "Bank account"),
        input(5, at: 4, text: "Reply", app: "Mail"),
    ])

    #expect(episodes.map(\.eventIDs) == [[1], [3], [5]])
    #expect(episodes[0].boundaryReasons == [.noisySurface])
    #expect(episodes[1].boundaryReasons == [.noisySurface, .sensitiveSurface])
    #expect(episodes[2].boundaryReasons == [.sensitiveSurface])
}
