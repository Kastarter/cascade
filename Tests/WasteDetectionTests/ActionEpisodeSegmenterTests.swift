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
    window: String? = nil,
    targetDescriptor: String? = nil
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
        windowTitle: window,
        targetDescriptor: targetDescriptor
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
	    #expect(episodes.map(\.boundaryReasons) == [[.completionControl], [.completionControl], []])
		}

@Test
func completionControlKeepsEpisodeWhenNextEventSharesContext() {
    let segmenter = ActionEpisodeSegmenter()
    let episodes = segmenter.segment([
        input(1, at: 0, text: "Invoice 142", app: "Mail", window: "Invoice"),
        input(2, at: 2, text: "Save", app: "Mail", window: "Invoice"),
        input(3, at: 4, text: "Invoice 142", app: "Mail", window: "Invoice"),
        input(4, at: 6, kind: .key, key: "c", modifiers: ["command"], app: "Mail", window: "Invoice"),
    ])

    #expect(episodes.count == 1)
    #expect(episodes[0].eventIDs == [1, 2, 3, 4])
    #expect(!episodes[0].boundaryReasons.contains(.completionControl))
}

@Test
func completionControlSplitsWhenNextEventStartsNewTask() {
    let segmenter = ActionEpisodeSegmenter()
    let episodes = segmenter.segment([
        input(1, at: 0, text: "Invoice 142", app: "Mail", window: "Invoice"),
        input(2, at: 2, text: "Save", app: "Mail", window: "Invoice"),
        input(3, at: 4, text: "Compose", app: "Mail", window: "Inbox"),
    ])

    #expect(episodes.map(\.eventIDs) == [[1, 2], [3]])
    #expect(episodes[0].boundaryReasons == [.completionControl])
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

@Test
func liveRepetitionDetectorMarksSecondQuietAndThirdActionable() {
    let detector = LiveRepetitionDetector(window: 900)
    func run(_ index: Int, start: TimeInterval) -> [InputEvent] {
        [
            input(index * 10, at: start, text: "Open", app: "Mail", window: "Inbox"),
            input(index * 10 + 1, at: start + 2, kind: .key, key: "c", modifiers: ["command"], app: "Mail", window: "Inbox"),
            input(index * 10 + 2, at: start + 4, text: "A1", app: "Numbers", window: "Budget"),
            input(index * 10 + 3, at: start + 6, kind: .key, key: "v", modifiers: ["command"], app: "Numbers", window: "Budget"),
        ]
    }

    let quiet = detector.detect(events: run(0, start: 0) + run(1, start: 120), now: segmentBase.addingTimeInterval(130))
    let actionable = detector.detect(events: run(0, start: 0) + run(1, start: 120) + run(2, start: 240), now: segmentBase.addingTimeInterval(250))

    #expect(quiet?.stage == .quiet)
    #expect(quiet?.occurrences == 2)
    #expect(actionable?.stage == .actionable)
    #expect(actionable?.occurrences == 3)
    #expect(actionable?.evidenceLabels.contains("click Open") == true)
}

@Test
func liveRepetitionDetectorSuppressesNoisyAndSensitiveSessions() {
    let detector = LiveRepetitionDetector(window: 900)
    let noisy = [
        input(1, at: 0, text: "Mute", app: "zoom.us", bundle: "us.zoom.xos"),
        input(2, at: 1, kind: .key, key: "m", modifiers: ["command"], app: "zoom.us", bundle: "us.zoom.xos"),
        input(3, at: 10, text: "Mute", app: "zoom.us", bundle: "us.zoom.xos"),
        input(4, at: 11, kind: .key, key: "m", modifiers: ["command"], app: "zoom.us", bundle: "us.zoom.xos"),
        input(5, at: 20, text: "Mute", app: "zoom.us", bundle: "us.zoom.xos"),
        input(6, at: 21, kind: .key, key: "m", modifiers: ["command"], app: "zoom.us", bundle: "us.zoom.xos"),
    ]
    let sensitive = [
        input(10, at: 0, text: "Pay", app: "Safari", window: "Bank account"),
        input(11, at: 1, kind: .key, key: "return", modifiers: ["command"], app: "Safari", window: "Bank account"),
        input(12, at: 10, text: "Pay", app: "Safari", window: "Bank account"),
        input(13, at: 11, kind: .key, key: "return", modifiers: ["command"], app: "Safari", window: "Bank account"),
        input(14, at: 20, text: "Pay", app: "Safari", window: "Bank account"),
        input(15, at: 21, kind: .key, key: "return", modifiers: ["command"], app: "Safari", window: "Bank account"),
    ]

    #expect(detector.detect(events: noisy, now: segmentBase.addingTimeInterval(30)) == nil)
    #expect(detector.detect(events: sensitive, now: segmentBase.addingTimeInterval(30)) == nil)
}

@Test
func wasteDetectorActionTokensUseSharedIdempotentIdentity() {
    let first = InputEvent(
        id: 1,
        kind: .click,
        x: 10,
        y: 20,
        text: "Send",
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitle: "Inbox",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "send")
    )
    let moved = InputEvent(
        id: 2,
        kind: .click,
        x: 200,
        y: 300,
        text: "Send",
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitle: "Inbox",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "send")
    )
    let different = InputEvent(
        id: 3,
        kind: .click,
        x: 10,
        y: 20,
        text: "Archive",
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitle: "Inbox",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "archive")
    )

    #expect(WasteDetector.actionToken(first, surface: "Gmail") == WasteDetector.actionToken(moved, surface: "Gmail"))
    #expect(WasteDetector.actionToken(first, surface: "Gmail") != WasteDetector.actionToken(different, surface: "Gmail"))
}

@Test
func wasteDetectorTypeTokensDoNotLeakOrVaryByTypedText() {
    let secret = InputEvent(kind: .type, text: "SSN 123-45-6789 secret", appName: "Mail", windowTitle: "Inbox")
    let other = InputEvent(kind: .type, text: "different private text", appName: "Mail", windowTitle: "Inbox")

    let token = WasteDetector.actionToken(secret, surface: "Mail")

    #expect(token == WasteDetector.actionToken(other, surface: "Mail"))
    #expect(!token.contains("SSN"))
    #expect(!token.contains("secret"))
    #expect(!token.contains("123"))
}
