import CascadeMemory
import GovernanceKit
import Testing
@testable import MacContextKit

// ON-path parity at the REAL capture choke point: `RewindEngine.captureGateVerdict`
// is exactly what `process()` switches on before OCR/persistence, so a `.drop` here
// IS "the frame would not persist" and `.allow` IS "capture continues".

private struct GateCase {
    let name: String
    let policy: CapturePrivacyPolicy
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String?
}

private func gateMatrix() -> [GateCase] {
    var deniedApp = CapturePrivacyPolicy.default
    deniedApp.deniedAppNames = ["1Password"]
    var deniedBundle = CapturePrivacyPolicy.default
    deniedBundle.deniedBundleIdentifiers = ["com.example.secret"]
    var deniedTitle = CapturePrivacyPolicy.default
    deniedTitle.deniedWindowTitleKeywords = ["payroll"]
    var keyword = CapturePrivacyPolicy.default
    keyword.sensitiveKeywords = ["password"]
    var allowlist = CapturePrivacyPolicy.default
    allowlist.allowedBundleIdentifiers = ["com.example.allowed"]
    var privateModeKeyword = CapturePrivacyPolicy.default
    privateModeKeyword.privateModeEnabled = true
    privateModeKeyword.sensitiveKeywords = ["password"]
    return [
        GateCase(name: "denied app", policy: deniedApp, appName: "1Password",
                 bundleIdentifier: "com.1password.mac", windowTitle: "Vault"),
        GateCase(name: "denied bundle", policy: deniedBundle, appName: "Secret",
                 bundleIdentifier: "com.example.secret", windowTitle: nil),
        GateCase(name: "denied window title", policy: deniedTitle, appName: "Numbers",
                 bundleIdentifier: "com.apple.Numbers", windowTitle: "Q3 Payroll.numbers"),
        GateCase(name: "sensitive keyword", policy: keyword, appName: "Safari",
                 bundleIdentifier: "com.apple.Safari", windowTitle: "Reset your password"),
        GateCase(name: "allowlist miss", policy: allowlist, appName: "Mail",
                 bundleIdentifier: "com.apple.mail", windowTitle: "Inbox"),
        GateCase(name: "private-mode + keyword", policy: privateModeKeyword, appName: "Safari",
                 bundleIdentifier: "com.apple.Safari", windowTitle: "Reset your password"),
        GateCase(name: "clean frame", policy: .default, appName: "Xcode",
                 bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "Cascade.swift"),
    ]
}

@Test
func governanceOnDropsDeniedAppAndAllowsCleanSnapshot() {
    var deniedApp = CapturePrivacyPolicy.default
    deniedApp.deniedAppNames = ["1Password"]
    let denied = RewindEngine.captureGateVerdict(
        appName: "1Password", bundleIdentifier: "com.1password.mac", windowTitle: "Vault",
        policy: deniedApp, governanceEnabled: true
    )
    #expect(denied == .drop(reason: "denied_app"))

    let clean = RewindEngine.captureGateVerdict(
        appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "Cascade.swift",
        policy: deniedApp, governanceEnabled: true
    )
    #expect(clean == .allow)
}

@Test
func redactVerdictDegradesToDropAtCaptureGate() {
    // LAW 7: no redactor is wired at this choke point, so a `.redact` verdict
    // must NOT persist the frame un-redacted (FALSE) — it degrades to drop
    // (MISSED) until redaction wiring exists.
    #expect(RewindEngine.captureVerdictAllowsPersist(.allow) == true)
    #expect(RewindEngine.captureVerdictAllowsPersist(.redact(regions: [])) == false)
    #expect(RewindEngine.captureVerdictAllowsPersist(.drop(reason: "denied_app")) == false)
    #expect(RewindEngine.captureVerdictAllowsPersist(.pause(reason: "supervisor")) == false)
}

@Test
func captureGateOnAndOffAgreeAcrossMatrix() {
    for item in gateMatrix() {
        let off = RewindEngine.captureGateVerdict(
            appName: item.appName, bundleIdentifier: item.bundleIdentifier,
            windowTitle: item.windowTitle, policy: item.policy, governanceEnabled: false
        )
        let on = RewindEngine.captureGateVerdict(
            appName: item.appName, bundleIdentifier: item.bundleIdentifier,
            windowTitle: item.windowTitle, policy: item.policy, governanceEnabled: true
        )
        #expect(on == off, Comment(rawValue: item.name))
        // Both must also equal today's raw decision.
        let decision = item.policy.decision(
            appName: item.appName,
            bundleIdentifier: item.bundleIdentifier,
            windowTitle: item.windowTitle
        )
        if decision.allowed {
            #expect(off == .allow, Comment(rawValue: item.name))
        } else {
            #expect(off == .drop(reason: decision.reason ?? "denied"), Comment(rawValue: item.name))
        }
    }
}
