import CascadeMemory
import Testing

@Test
func defaultPrivacyRulesMatchHistoricalKeywordBehavior() {
    #expect(PrivacyRules.isSensitive(appName: "Bank Portal", bundleIdentifier: nil, windowTitle: nil))
    #expect(PrivacyRules.isSensitiveText("medical record"))
    #expect(!PrivacyRules.isSensitive(appName: "Notes", bundleIdentifier: "com.apple.Notes", windowTitle: "Project plan"))
}

@Test
func privacyRulesRedactSensitiveKeywordsForStorage() {
    let redacted = PrivacyRules.redactingSensitiveKeywords(in: "Password and bank details")
    #expect(redacted.contains("<SENSITIVE_TEXT>"))
    #expect(!redacted.lowercased().contains("password"))
    #expect(!redacted.lowercased().contains("bank"))
}
