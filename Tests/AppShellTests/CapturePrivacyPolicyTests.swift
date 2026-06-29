import AppShell
import CascadeMemory
import Testing

@Test
func capturePolicyImportExportRoundTrips() throws {
    let policy = CapturePrivacyPolicy(
        privateModeEnabled: true,
        deniedAppNames: ["Preview"],
        deniedBundleIdentifiers: ["com.example.Secret"],
        deniedWindowTitleKeywords: ["Payroll"],
        retentionByDataClass: ["frames": CaptureRetentionPolicy(maxAgeDays: 3, maxBytes: 1024)]
    )

    let imported = try CapturePrivacyPolicy.importJSONData(policy.exportedJSONData())
    #expect(imported == policy)
}

@Test
func capturePolicyDeniesBundleWindowAndPrivateMode() {
    let bundlePolicy = CapturePrivacyPolicy(deniedBundleIdentifiers: ["com.example.Secret"])
    #expect(!bundlePolicy.decision(appName: "Secret", bundleIdentifier: "com.example.Secret", windowTitle: nil).allowed)

    let windowPolicy = CapturePrivacyPolicy(deniedWindowTitleKeywords: ["Payroll"])
    #expect(!windowPolicy.decision(appName: "Numbers", bundleIdentifier: nil, windowTitle: "Q4 Payroll").allowed)

    let privatePolicy = CapturePrivacyPolicy(privateModeEnabled: true)
    #expect(privatePolicy.decision(appName: "Notes", bundleIdentifier: nil, windowTitle: nil).reason == "private_mode")
}
