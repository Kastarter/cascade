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

    #expect(suggestions.contains { $0.kind == .repeatedWorkflow })
    #expect(suggestions.allSatisfy { $0.doable })
    #expect(!suggestions.flatMap(\.evidence).contains { $0.localizedCaseInsensitiveContains("password") })
}
