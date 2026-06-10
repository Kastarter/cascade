import CascadeMemory
import Foundation
import SuggestionEngine
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
func recipeStepsCarryRealCoordinatesAndText() {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 42, y: 99, appName: "Safari")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "hello", appName: "Safari")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events).first!
    #expect(waste.recipe.steps.contains { $0.kind == .click && $0.x == 42 && $0.y == 99 })
    #expect(waste.recipe.steps.contains { $0.kind == .type && $0.text == "hello" })
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
