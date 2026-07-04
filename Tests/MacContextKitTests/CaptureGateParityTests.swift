import CascadeMemory
import CoreGraphics
import GovernanceKit
import PerceptionCore
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
    // LAW 7 OFF pin: with `cascade.frameRedaction` OFF (the shipped default),
    // a `.redact` verdict must NOT persist the frame un-redacted (FALSE) — it
    // degrades to drop (MISSED). `captureVerdictAllowsPersist` is the flag-OFF
    // truth table, now a delegating wrapper over `captureVerdictDisposition`.
    #expect(RewindEngine.captureVerdictAllowsPersist(.allow) == true)
    #expect(RewindEngine.captureVerdictAllowsPersist(.redact(regions: [])) == false)
    #expect(RewindEngine.captureVerdictAllowsPersist(.drop(reason: "denied_app")) == false)
    #expect(RewindEngine.captureVerdictAllowsPersist(.pause(reason: "supervisor")) == false)
}

@Test
func redactVerdictPersistsOnlyWhenFrameRedactionWired() {
    let region = Rect<FrameSpace>(x: 10, y: 20, width: 100, height: 40)

    // ON: `.redact` persists WITH the policy's typed regions (they flow into
    // FrameRedactor.redact(policyRegions:) at the process() choke point).
    #expect(
        RewindEngine.captureVerdictDisposition(.redact(regions: [region]), frameRedactionEnabled: true)
            == .persist(policyRegions: [region])
    )
    // OFF: the same verdict keeps degrading to drop — MISSED, never FALSE.
    #expect(
        RewindEngine.captureVerdictDisposition(.redact(regions: [region]), frameRedactionEnabled: false)
            == .drop
    )
    // `.drop`/`.pause` stay dropped even when the flag is ON.
    #expect(RewindEngine.captureVerdictDisposition(.drop(reason: "denied_app"), frameRedactionEnabled: true) == .drop)
    #expect(RewindEngine.captureVerdictDisposition(.pause(reason: "supervisor"), frameRedactionEnabled: true) == .drop)
    // `.allow` persists with no regions both ways — the flag never widens or
    // narrows the allow path.
    #expect(RewindEngine.captureVerdictDisposition(.allow, frameRedactionEnabled: true) == .persist(policyRegions: []))
    #expect(RewindEngine.captureVerdictDisposition(.allow, frameRedactionEnabled: false) == .persist(policyRegions: []))
}

// LAW 7 pin for the region-blind side channels (AX exact text, AX control
// labels/values, native-res OCR lines): a tenant `.redact(regions:)` verdict
// cannot be region-scoped onto channels with no FrameSpace geometry, so the
// whole channel must degrade to MISSED (dropped) — never persist PII-scrubbed
// region text under a POLICY_REGION manifest (FALSE). The persisted values in
// process() flow through this exact function.
@Test
func policyRegionsDropRegionBlindSideChannels() {
    let region = Rect<FrameSpace>(x: 10, y: 20, width: 100, height: 40)
    let scrubbed = RewindEngine.scrubbedSideChannels(
        axText: "Quarterly totals\nRevenue 403,050",  // benign — no PII, no keywords
        axControls: [ScreenContentStructurer.AXControl(
            kind: .textField, label: "Quarterly totals", value: "403,050",
            rect: CGRect(x: 12, y: 22, width: 90, height: 30)
        )],
        nativeOCRLines: [ScreenTextRecognizer.TextBox(
            text: "Quarterly totals",
            boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.2)
        )],
        policy: .default,
        policyRegions: [region]
    )
    #expect(scrubbed.axText.isEmpty)
    #expect(scrubbed.axControls.isEmpty)
    #expect(scrubbed.nativeOCRLines.isEmpty)
}

// OFF pin: empty regions (the ONLY reachable state with `cascade.frameRedaction`
// OFF) keep today's exact always-on PII scrub on every side channel.
@Test
func emptyPolicyRegionsKeepTodaysPIIScrubOnSideChannels() {
    let axText = "Email jane@example.com\nQuarterly totals"
    let control = ScreenContentStructurer.AXControl(
        kind: .textField, label: "Email", value: "jane@example.com",
        rect: CGRect(x: 12, y: 22, width: 90, height: 30)
    )
    let nativeLine = ScreenTextRecognizer.TextBox(
        text: "Email jane@example.com",
        boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.2)
    )
    let scrubbed = RewindEngine.scrubbedSideChannels(
        axText: axText,
        axControls: [control],
        nativeOCRLines: [nativeLine],
        policy: .default,
        policyRegions: []
    )
    #expect(scrubbed.axText == FrameRedactor.redactedText(axText, policy: .default))
    #expect(scrubbed.axText.contains("<EMAIL>"))
    #expect(scrubbed.axText.contains("Quarterly totals"))
    #expect(scrubbed.axControls.count == 1)
    #expect(scrubbed.axControls.first?.label == "Email")
    #expect(scrubbed.axControls.first?.value == "<EMAIL>")
    #expect(scrubbed.axControls.first?.rect == control.rect)
    #expect(scrubbed.nativeOCRLines.count == 1)
    #expect(scrubbed.nativeOCRLines.first?.text == FrameRedactor.redactedText(nativeLine.text, policy: .default))
    #expect(scrubbed.nativeOCRLines.first?.boundingBox == nativeLine.boundingBox)
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
