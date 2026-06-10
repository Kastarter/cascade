import CascadeMemory
import Foundation
import ProviderKit
import Testing

private func moment(_ app: String, at seconds: TimeInterval, title: String? = nil, ocr: String? = nil) -> RecordedContext {
    RecordedContext(
        capturedAt: Date(timeIntervalSince1970: seconds),
        source: .screen,
        appName: app,
        windowTitle: title,
        ocrText: ocr
    )
}

@Test
func mergesConsecutiveSameAppMomentsIntoOneSegment() {
    let segments = ActivityTimeline.segments(from: [
        moment("Chrome", at: 0, title: "WhatsApp"),
        moment("Chrome", at: 60, title: "Gmail"),
        moment("Chrome", at: 120),
        moment("Xcode", at: 180, title: "Cascade"),
        moment("Xcode", at: 240)
    ])

    #expect(segments.count == 2)
    #expect(segments[0].appName == "Chrome")
    #expect(segments[0].moments == 3)
    #expect(segments[0].duration == 120)
    // The last title seen wins — sticky across title-less moments.
    #expect(segments[0].windowTitle == "Gmail")
    #expect(segments[1].appName == "Xcode")
    #expect(segments[1].moments == 2)
}

@Test
func longIdleGapSplitsASameAppRun() {
    let segments = ActivityTimeline.segments(from: [
        moment("Chrome", at: 0),
        moment("Chrome", at: 60),
        moment("Chrome", at: 60 + 16 * 60)
    ])

    #expect(segments.count == 2)
    #expect(segments[0].moments == 2)
    #expect(segments[1].moments == 1)
}

@Test
func digestCapsLinesAndNotesOmittedVisits() {
    // 70 one-moment visits, alternating apps so nothing merges.
    let contexts = (0..<70).map { moment($0 % 2 == 0 ? "Chrome" : "Xcode", at: TimeInterval($0 * 60)) }

    let digest = ActivityTimeline.digest(from: contexts, maxLines: 10, timeZone: TimeZone(identifier: "UTC")!)
    let lines = digest.components(separatedBy: "\n")

    #expect(lines.count == 11)
    #expect(lines.last == "(+60 briefer visits not shown)")
}

@Test
func digestAddsDayHeadersWhenTheWindowCrossesMidnight() {
    let contexts = [
        moment("Chrome", at: 86400 - 600),  // Thu Jan 1 1970 23:50 UTC
        moment("Xcode", at: 86400 + 600)    // Fri Jan 2 1970 00:10 UTC
    ]

    let digest = ActivityTimeline.digest(from: contexts, timeZone: TimeZone(identifier: "UTC")!)

    #expect(digest.contains("Thu Jan 1:"))
    #expect(digest.contains("Fri Jan 2:"))
}

@Test
func digestOmitsDayHeadersWithinASingleDay() {
    let digest = ActivityTimeline.digest(from: [
        moment("Chrome", at: 0, title: "WhatsApp"),
        moment("Chrome", at: 600)
    ], timeZone: TimeZone(identifier: "UTC")!)

    #expect(digest == "• 00:00–00:10 Chrome — WhatsApp (2 moments)")
}

@Test
func localAnswererCoversTheWholeWindowNotJustTheLatestMoments() async throws {
    // Xcode dominates the day but the latest moments are all Chrome — the
    // summary must still mention Xcode.
    let contexts = (0..<10).map { moment("Xcode", at: TimeInterval($0 * 60)) }
        + (0..<8).map { moment("Chrome", at: TimeInterval(3600 + $0 * 60)) }

    let answer = try await LocalGroundedAnswerer().answer(
        question: "summary of my day",
        grounding: ChatGrounding(timeline: contexts)
    )

    #expect(answer.contains("Xcode"))
    #expect(answer.contains("Chrome"))
}

private final class CapturingCompleter: MessageCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastUser: String?
    var lastUser: String? {
        lock.withLock { _lastUser }
    }

    private func record(_ user: String) {
        lock.withLock { _lastUser = user }
    }

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        record(user)
        return "ok"
    }
}

@Test
func claudeAnswererPromptCarriesEveryGroundingLayer() async throws {
    let completer = CapturingCompleter()
    let answerer = ClaudeGroundedAnswerer(client: completer)

    _ = try await answerer.answer(
        question: "when is the assignment due?",
        grounding: ChatGrounding(
            timeline: [moment("Xcode", at: 0, title: "Cascade build")],
            samples: [moment("Notes", at: 3600, ocr: "groceries: milk, eggs")],
            relevant: [moment("Chrome", at: 7200, title: "LEARN", ocr: "Final Project due Jul 30 at 11:59 PM")],
            recent: [moment("Chrome", at: 6 * 3600, title: "WhatsApp", ocr: "quarterly dashboard numbers")]
        )
    )

    let prompt = try #require(completer.lastUser)
    #expect(prompt.contains("Xcode"))
    #expect(prompt.contains("groceries: milk, eggs"))
    #expect(prompt.contains("Final Project due Jul 30 at 11:59 PM"))
    #expect(prompt.contains("quarterly dashboard numbers"))
    #expect(prompt.contains("Moments matching the question"))
}
