import CascadeMemory
import SuggestionEngine
import Testing

@Test
func suggestionsRequireNonSensitiveEvidence() {
    let engine = SuggestionEngine()
    let contexts = [
        RecordedContext(source: .app, appName: "Notes", bundleIdentifier: "com.apple.Notes", windowTitle: "Weekly notes"),
        RecordedContext(source: .app, appName: "Notes", bundleIdentifier: "com.apple.Notes", windowTitle: "Weekly notes"),
        RecordedContext(source: .app, appName: "Notes", bundleIdentifier: "com.apple.Notes", windowTitle: "Weekly notes"),
        RecordedContext(source: .app, appName: "Keychain Access", windowTitle: "Passwords")
    ]

    let suggestions = engine.suggest(from: contexts)

    // Workflow detection belongs to WasteDetector (real recorded actions) —
    // the engine only offers deliverables like the recap, never a watered-down
    // duplicate of the detected-workflow cards.
    #expect(!suggestions.contains { $0.kind == .repeatedWorkflow })
    #expect(suggestions.contains { $0.kind == .dailyRecap })
    #expect(suggestions.allSatisfy { $0.doable })
    #expect(!suggestions.flatMap(\.evidence).contains { $0.localizedCaseInsensitiveContains("password") })
}
