import AppShell
import CascadeMemory
import Testing

@Test
func capturePolicyImportExportRoundTrips() throws {
    let policy = CapturePrivacyPolicy(
        recordingAvailable: false,
        privateModeEnabled: true,
        backgroundWebRunsAvailable: false,
        scheduledRunsAvailable: false,
        powerHarnessAvailable: false,
        recordRecallAvailable: false,
        forceIrreversibleActionGuard: true,
        deniedAppNames: ["Preview"],
        deniedBundleIdentifiers: ["com.example.Secret"],
        deniedWindowTitleKeywords: ["Payroll"],
        deniedURLHosts: ["example.com"],
        deniedURLKeywords: ["token="],
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

@Test
func capturePolicyBlocksManagedAgentSites() {
    let policy = CapturePrivacyPolicy(
        deniedURLHosts: ["example.com"],
        deniedURLKeywords: ["access_token"]
    )

    #expect(policy.agentDecision(urlString: "https://secure.example.com/report").reason == "denied_url_host")
    #expect(policy.agentDecision(urlString: "open https://app.test/?access_token=abc").reason == "denied_url_keyword")
    #expect(policy.agentDecision(urlString: "https://public.test/report").allowed)
}
