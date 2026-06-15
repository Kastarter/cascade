import CascadeMemory
import Foundation
import WasteDetection
import Testing

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func event(_ i: Int, _ kind: InputEventKind, app: String, key: String? = nil, modifiers: [String] = []) -> InputEvent {
    InputEvent(
        id: Int64(i),
        capturedAt: base.addingTimeInterval(Double(i)),
        kind: kind,
        x: kind == .click ? 10 : nil,
        y: kind == .click ? 10 : nil,
        key: key,
        modifiers: modifiers,
        appName: app
    )
}

@Test
func detectsRepeatedCrossAppWorkflow() {
    // Copy from Mail → paste into Numbers, done twice.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(event(i, .click, app: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
        events.append(event(i, .click, app: "Numbers")); i += 1
        events.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    }

    let result = WasteDetector().detect(contexts: [], inputEvents: events)
    #expect(result.count == 1)
    let waste = result.first!
    #expect(waste.occurrences == 2)
    #expect(waste.apps == ["Mail", "Numbers"])
    // activateApp Mail, click, key, activateApp Numbers, click, key
    #expect(waste.recipe.steps.count == 6)
    #expect(waste.recipe.steps.first?.kind == .activateApp)
    #expect(waste.recipe.steps.contains { $0.kind == .key && $0.key == "v" })
}

@Test
func nonRepeatingActivityDetectsNothing() {
    let events = (0..<6).map { event($0, .click, app: "App\($0)") }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).isEmpty)
}

@Test
func scrollSpamIsNeverAWorkflow() {
    // Hours of reading in iTerm2 — hundreds of wheel ticks, no real actions.
    // This was surfacing as "Repeated steps in iTerm2 · scroll · scroll · …".
    let events = (0..<60).map { event($0, .scroll, app: "iTerm2") }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).isEmpty)
}

@Test
func scrollThenOneActionIsStillNotAWorkflow() {
    // Scroll, type a command, repeat — that's just using a terminal.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<4 {
        for _ in 0..<6 { events.append(event(i, .scroll, app: "iTerm2")); i += 1 }
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "ls", appName: "iTerm2")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).isEmpty)
}

@Test
func scrollBurstsCollapseToOneGesture() {
    var events: [InputEvent] = []
    var i = 0
    // 8-tick wheel burst, then a click, a key — twice.
    for _ in 0..<2 {
        for _ in 0..<8 { events.append(event(i, .scroll, app: "Mail")); i += 1 }
        events.append(event(i, .click, app: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "r", modifiers: ["command"])); i += 1
    }
    let results = WasteDetector().detect(contexts: [], inputEvents: events)
    #expect(results.count == 1)
    let waste = results[0]
    // The burst is one step, not eight — recipes and time-saved stay honest.
    let scrollSteps = waste.recipe.steps.filter { $0.kind == .scroll }.count
    #expect(scrollSteps <= 1)
    #expect(waste.estimatedSecondsPerRun <= 12)
}

@Test
func recipeStepsCarryRealCoordinatesAndText() {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 42, y: 99, appName: "Safari")); i += 1
        events.append(event(i, .key, app: "Safari", key: "l", modifiers: ["command"])); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "hello", appName: "Safari")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events).first!
    #expect(waste.recipe.steps.contains { $0.kind == .click && $0.x == 42 && $0.y == 99 })
    #expect(waste.recipe.steps.contains { $0.kind == .type && $0.text == "hello" })
}

@Test
func editingKeysAreNeverAWorkflow() {
    // The real-world garbage this gate exists for: "Delete → Delete → type"
    // in Chrome is someone fixing a sentence, not an automatable task.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<3 {
        events.append(event(i, .key, app: "Google Chrome", key: "Delete")); i += 1
        events.append(event(i, .key, app: "Google Chrome", key: "Delete")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "fix", appName: "Google Chrome")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).isEmpty)
}

@Test
func anonymousSameAppClickingIsNotAWorkflow() {
    // Click, click, click around a browser — that's reading. No named element,
    // no shortcut, one app: no agent.
    let events = (0..<12).map { event($0, .click, app: "Google Chrome") }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).isEmpty)
}

@Test
func clickPlusTypingAloneIsNotAWorkflow() {
    // Click a field and type — that's just using a text box (the "type →
    // Delete → type" cards). One structural action isn't a workflow.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<3 {
        events.append(event(i, .click, app: "Google Chrome")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "words", appName: "Google Chrome")); i += 1
        events.append(event(i, .key, app: "Google Chrome", key: "Delete")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).isEmpty)
}

@Test
func clickAXLabelBecomesTheAnchor() {
    // The recorder stores the clicked element's AX label in `text` for clicks —
    // the strongest re-targeting anchor at replay time.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 42, y: 99, text: "Send Message", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "w", modifiers: ["command"], appName: "Mail")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events).first!
    let click = waste.recipe.steps.first { $0.kind == .click }!
    #expect(click.ocrAnchor == "Send Message")
}

@Test
func contextAnchorMustComeFromTheSameApp() {
    // The nearest prior context is from a DIFFERENT app — it must not become the
    // anchor for Safari clicks (it would re-target the click at the wrong thing).
    let foreign = RecordedContext(
        capturedAt: base.addingTimeInterval(-1),
        source: .screen,
        appName: "Slack",
        bundleIdentifier: "com.slack",
        windowTitle: "Slack — #general",
        ocrText: "unrelated"
    )
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, appName: "Safari", windowTitle: "Safari window")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "r", modifiers: ["command"], appName: "Safari")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [foreign], inputEvents: events).first!
    let click = waste.recipe.steps.first { $0.kind == .click }!
    #expect(click.ocrAnchor == "Safari window")
}

@Test
func copyPasteAcrossAppsGetsNamedOutright() {
    // ⌘C in Mail then ⌘V in Numbers — the title should say what it IS.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
        events.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events).first!
    #expect(waste.title == "Copy from Mail into Numbers")
}

@Test
func titleTellsTheStoryFromAnchorsNotJustTheApp() {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(
            id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)),
            kind: .click, x: 10, y: 10, text: "Reply All", appName: "Mail"
        )); i += 1
        events.append(event(i, .key, app: "Mail", key: "r", modifiers: ["command"])); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events).first!
    #expect(waste.title.contains("Mail"))
    #expect(waste.title.contains("Reply All"))
    #expect(!waste.title.contains("Repeated steps"))
    // And the card can date the evidence.
    #expect(waste.lastSeenAt > base)
}

@Test
func resultsSortByTotalTimeSavedDescending() {
    var events: [InputEvent] = []
    var i = 0
    // Small workflow: 2 occurrences × 2 events in TextEdit.
    for _ in 0..<2 {
        events.append(event(i, .click, app: "TextEdit")); i += 1
        events.append(event(i, .key, app: "TextEdit", key: "s", modifiers: ["command"])); i += 1
    }
    // Big workflow: 4 occurrences × 2 events in Mail (distinct shortcut).
    for _ in 0..<4 {
        events.append(event(i, .click, app: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "e", modifiers: ["command"])); i += 1
    }
    let results = WasteDetector().detect(contexts: [], inputEvents: events)
    #expect(results.count >= 2)
    #expect(results[0].estimatedTotalSeconds >= results[1].estimatedTotalSeconds)
    #expect(results[0].apps == ["Mail"])
}

@Test
func overlappingWorkflowsAreNotDoubleCounted() {
    // Two length-2 shapes share a boundary event: [click "Inbox", ⌘C] and
    // [⌘C, ⌘V]. The ⌘C in the middle belongs to BOTH the moment the detector
    // forgets what it has already claimed — surfacing two cards for one stretch
    // of activity and counting that time twice. Dictionary iteration order is
    // per-process random, so before the fix this also made the output flaky.
    // The earliest/strongest shape must claim its events once; the overlapping
    // neighbour is then left with too few free occurrences and drops out.
    func click(_ i: Int) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")
    }
    func key(_ i: Int, _ k: String) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: k, modifiers: ["command"], appName: "Mail")
    }
    // click ⌘C ⌘V ⌘S click ⌘C ⌘X ⌘C ⌘V  →  [click,⌘C]@{0,4} and [⌘C,⌘V]@{1,7}
    let events: [InputEvent] = [
        click(0), key(1, "c"), key(2, "v"), key(3, "s"),
        click(4), key(5, "c"), key(6, "x"), key(7, "c"), key(8, "v"),
    ]
    let results = WasteDetector().detect(contexts: [], inputEvents: events)
    #expect(results.count == 1)
    #expect(results.first?.signature == "click@Mail|key:command+c@Mail")
    // The hard invariant: no event id is ever counted into two workflows.
    let allEvidence = results.flatMap(\.evidence)
    #expect(Set(allEvidence).count == allEvidence.count)
}

// MARK: - waste(fromInstance:) — the reusable single-range entry point (Teach-once)

/// One occurrence of the cross-app copy/paste, offset so two of them form the
/// repeated workflow `detect` mines.
private func copyPasteInstance(_ start: Int) -> [InputEvent] {
    var e: [InputEvent] = []
    var i = start
    e.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")); i += 1
    e.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
    e.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers")); i += 1
    e.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    return e
}

@Test
func wasteFromInstanceBuildsTheSameRecipeAsDetect() {
    // The intentional path (Teach-once) must yield the very recipe the automatic path
    // would for that instance — one creation spine, not a divergent second one.
    let detector = WasteDetector()
    let detected = detector.detect(contexts: [], inputEvents: copyPasteInstance(0) + copyPasteInstance(4)).first!
    let taught = detector.waste(fromInstance: copyPasteInstance(0), contexts: [])

    let one = try! #require(taught)
    #expect(one.signature == detected.signature)               // same token shape
    #expect(one.recipe.steps.count == detected.recipe.steps.count) // activateApp×2 + 4 actions
    #expect(one.apps == ["Mail", "Numbers"])
    #expect(one.occurrences == 1)                              // a single demonstration
    #expect(one.recipe.steps.contains { $0.kind == .key && $0.key == "v" })
}

@Test
func wasteFromInstanceRefusesAJunkRange() {
    // A demonstration of only scrolling, or only typing, has no automatable structure
    // — the same guard `detect` uses returns nil ("nothing repeatable here yet").
    let detector = WasteDetector()
    let scrolls = (0..<8).map { event($0, .scroll, app: "Safari") }
    #expect(detector.waste(fromInstance: scrolls, contexts: []) == nil)
    let typing = [InputEvent(id: 1, capturedAt: base, kind: .type, text: "hello", appName: "Notes")]
    #expect(detector.waste(fromInstance: typing, contexts: []) == nil)
}

@Test
func wasteFromInstanceHonorsTheWebSurfaceResolver() {
    // With a web-identity resolver a browser demonstration is named for the web app,
    // exactly as the detector names it — while still recording the real browser.
    let detector = WasteDetector()
    var events: [InputEvent] = []
    var i = 0
    events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Compose", appName: "Google Chrome", windowTitle: "Inbox - Gmail")); i += 1
    events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Google Chrome", windowTitle: "Inbox - Gmail")); i += 1
    let resolver: @Sendable (InputEvent) -> String? = { WebAppIdentity.from(windowTitle: $0.windowTitle) }
    let taught = try! #require(detector.waste(fromInstance: events, contexts: [], surface: resolver))
    #expect(taught.title.contains("Gmail"))
    #expect(taught.apps == ["Google Chrome"])
}

@Test
func webAppsInSameBrowserAreDistinctWorkflows() {
    // Two different web apps, BOTH in Google Chrome, each a repeated click + ⌘C.
    // Keyed only on the macOS app they tokenize identically and merge into one
    // "Chrome" workflow; with a web-app resolver they become two distinct agents,
    // each named for the web app — while still recording the real browser.
    func click(_ i: Int, _ title: String) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Compose", appName: "Google Chrome", windowTitle: title)
    }
    func copy(_ i: Int, _ title: String) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Google Chrome", windowTitle: title)
    }
    let gmail = "Inbox - me@example.com - Gmail"
    let notion = "Tasks - Notion"
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 { events.append(click(i, gmail)); i += 1; events.append(copy(i, gmail)); i += 1 }
    for _ in 0..<2 { events.append(click(i, notion)); i += 1; events.append(copy(i, notion)); i += 1 }

    let resolver: @Sendable (InputEvent) -> String? = { WebAppIdentity.from(windowTitle: $0.windowTitle) }
    let results = WasteDetector().detect(contexts: [], inputEvents: events, webAppIdentity: resolver)
    #expect(results.count == 2)
    #expect(results.contains { $0.title.contains("Gmail") })
    #expect(results.contains { $0.title.contains("Notion") })
    // The real browser is still what's recorded, so replay + background routing work.
    #expect(results.allSatisfy { $0.apps == ["Google Chrome"] })

    // Contrast: with no resolver, both collapse into a single "Chrome" workflow.
    #expect(WasteDetector().detect(contexts: [], inputEvents: events).count == 1)
}
