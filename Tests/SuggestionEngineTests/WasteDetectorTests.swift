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
