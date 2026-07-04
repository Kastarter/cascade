import CascadeMemory
import Foundation
import GovernanceKit
import PerceptionCore
import Testing

// MARK: - Fixtures

/// The parity matrix: every branch of `CapturePrivacyPolicy.decision` the shipped
/// pre-OCR gate can hit, plus the clean frame. Each case pairs a policy with a
/// capture context.
private struct ParityCase {
    let name: String
    let policy: CapturePrivacyPolicy
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String?
}

private func parityMatrix() -> [ParityCase] {
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
        ParityCase(
            name: "denied app",
            policy: deniedApp,
            appName: "1Password", bundleIdentifier: "com.1password.mac", windowTitle: "Vault"
        ),
        ParityCase(
            name: "denied bundle",
            policy: deniedBundle,
            appName: "Secret", bundleIdentifier: "com.example.secret", windowTitle: nil
        ),
        ParityCase(
            name: "denied window-title keyword",
            policy: deniedTitle,
            appName: "Numbers", bundleIdentifier: "com.apple.Numbers", windowTitle: "Q3 Payroll.numbers"
        ),
        ParityCase(
            name: "sensitive keyword",
            policy: keyword,
            appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Reset your password"
        ),
        ParityCase(
            name: "allowlist miss",
            policy: allowlist,
            appName: "Mail", bundleIdentifier: "com.apple.mail", windowTitle: "Inbox"
        ),
        ParityCase(
            name: "private-mode + keyword (kept — redacted downstream, never dropped here)",
            policy: privateModeKeyword,
            appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Reset your password"
        ),
        ParityCase(
            name: "clean frame",
            policy: .default,
            appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "Cascade.swift"
        ),
    ]
}

private let allKindTokens = [
    "click", "double_click", "triple_click", "right_click", "drag", "type", "key",
    "scroll", "wait", "screenshot", "open_app", "open_url", "zoom", "highlight", "move",
]

// MARK: - DefaultGovernancePolicy parity

@Test
func defaultPolicyCaptureVerdictMatchesTodaysDecisionAcrossMatrix() {
    for item in parityMatrix() {
        let decision = item.policy.decision(
            appName: item.appName,
            bundleIdentifier: item.bundleIdentifier,
            windowTitle: item.windowTitle
        )
        let verdict = DefaultGovernancePolicy(capture: item.policy).evaluateCapture(CaptureContext(
            appName: item.appName,
            bundleIdentifier: item.bundleIdentifier,
            windowTitle: item.windowTitle
        ))
        if decision.allowed {
            #expect(verdict == .allow, "\(item.name): expected .allow")
        } else {
            #expect(
                verdict == .drop(reason: decision.reason ?? "denied"),
                "\(item.name): expected .drop with today's reason string"
            )
        }
        // dab9e5c pin: the default policy NEVER emits redact for any input.
        if case .redact = verdict {
            Issue.record("\(item.name): default policy must never return .redact")
        }
    }
}

@Test
func defaultPolicyDropReasonsMatchShippedReasonStrings() {
    let matrix = parityMatrix()
    let expectations: [String: String] = [
        "denied app": "denied_app",
        "denied bundle": "denied_bundle",
        "denied window-title keyword": "denied_window_title",
        "sensitive keyword": "sensitive_keyword:password",
        "allowlist miss": "bundle_not_allowed",
    ]
    for item in matrix {
        guard let expectedReason = expectations[item.name] else { continue }
        let verdict = DefaultGovernancePolicy(capture: item.policy).evaluateCapture(CaptureContext(
            appName: item.appName,
            bundleIdentifier: item.bundleIdentifier,
            windowTitle: item.windowTitle
        ))
        #expect(verdict == .drop(reason: expectedReason), Comment(rawValue: item.name))
    }
}

@Test
func defaultPolicyKeepsPrivateModeFrames() {
    // Pins behavior == TODAY: private mode KEEPS frames (FrameRedactor redacts
    // downstream — dropping froze the Reel), even when a sensitive keyword is on
    // screen. The plan's "private-mode ⇒ drop" prose loses to shipped behavior.
    var policy = CapturePrivacyPolicy.default
    policy.privateModeEnabled = true
    policy.sensitiveKeywords = ["password"]
    let verdict = DefaultGovernancePolicy(capture: policy).evaluateCapture(CaptureContext(
        appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Reset your password"
    ))
    #expect(verdict == .allow)
}

@Test
func defaultPolicyAllowsEveryActionKindAtEveryRisk() {
    let policy = DefaultGovernancePolicy(capture: .default, tenant: TenantPolicy())
    let risks: [ActionRisk] = [.low, .elevated, .high, .destructive]
    for kind in allKindTokens {
        for risk in risks {
            let verdict = policy.evaluateAction(ActionDescriptor(kindToken: kind), risk: risk)
            #expect(verdict == .allow, "kind=\(kind) risk=\(risk)")
        }
    }
}

// MARK: - GovernanceFlag

@Test
func governanceFlagDefaultsOffAndReadsKey() {
    let suite = "governance-flag-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(GovernanceFlag.key == "cascade.governance")
    #expect(!GovernanceFlag.isEnabled(defaults: defaults))
    defaults.set(true, forKey: GovernanceFlag.key)
    #expect(GovernanceFlag.isEnabled(defaults: defaults))
}

// MARK: - TenantPolicy managed-prefs decode

@Test
func tenantPolicyLoadsFromManagedJSONData() {
    let suite = "tenant-policy-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let json = """
    {"version":"tenant-policy-v1","deniedBundleIdentifiers":["com.example.banned"],\
    "deniedURLHosts":["evil.example"],"retentionDaysByDataClass":{"screen":30},\
    "allowRedactOnly":false}
    """
    defaults.set(Data(json.utf8), forKey: TenantPolicy.managedPreferenceKey)
    let policy = TenantPolicy.loadManaged(defaults: defaults)
    #expect(policy != nil)
    #expect(policy?.deniedBundleIdentifiers == ["com.example.banned"])
    #expect(policy?.deniedURLHosts == ["evil.example"])
    #expect(policy?.retentionDaysByDataClass == ["screen": 30])
    #expect(policy?.allowRedactOnly == false)
}

@Test
func tenantPolicyLoadsFromManagedDictionary() {
    // MDM forced prefs commonly surface as a plist dictionary, not Data.
    let suite = "tenant-policy-dict-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
        ["deniedBundleIdentifiers": ["com.example.banned"]],
        forKey: TenantPolicy.managedPreferenceKey
    )
    let policy = TenantPolicy.loadManaged(defaults: defaults)
    #expect(policy?.deniedBundleIdentifiers == ["com.example.banned"])
    #expect(policy?.version == TenantPolicy.defaultVersion)
}

@Test
func tenantPolicyAbsentOrMalformedIsNil() {
    let suite = "tenant-policy-bad-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(TenantPolicy.loadManaged(defaults: defaults) == nil)
    defaults.set("not json at all {{{", forKey: TenantPolicy.managedPreferenceKey)
    #expect(TenantPolicy.loadManaged(defaults: defaults) == nil)
    defaults.set(Data([0xFF, 0x00, 0x12]), forKey: TenantPolicy.managedPreferenceKey)
    #expect(TenantPolicy.loadManaged(defaults: defaults) == nil)
}

// MARK: - SIEMExporter stub

@Test
func siemExporterCountsSpansInOTelEnvelope() {
    // Same envelope shape AgentTrace.otelJSON() renders (resourceSpans → scopeSpans → spans).
    let json = """
    {"trace_id":"t1","resourceSpans":[{"resource":{"attributes":[]},"scopeSpans":[{"scope":\
    {"name":"Cascade.AgentTrace","version":"1"},"spans":[{"traceId":"a","spanId":"b","name":"run",\
    "attributes":[{"key":"gen_ai.operation.name","value":{"stringValue":"invoke_agent"}}]},\
    {"traceId":"a","spanId":"c","name":"model"}]}]}]}
    """
    let record = SIEMExporter().makeRecord(fromOTelJSON: json)
    #expect(record?.spanCount == 2)
    #expect(record?.byteSize == json.utf8.count)
}

@Test
func siemExporterRejectsMalformedEnvelope() {
    let exporter = SIEMExporter()
    #expect(exporter.makeRecord(fromOTelJSON: "not json") == nil)
    #expect(exporter.makeRecord(fromOTelJSON: "{\"nope\":1}") == nil)
    #expect(exporter.makeRecord(fromOTelJSON: "[]") == nil)
}

@Test
func siemExporterConstantsMirrorAgentTraceGenAINames() {
    #expect(SIEMExporter.GenAIAttribute.operationName == "gen_ai.operation.name")
    #expect(SIEMExporter.GenAIAttribute.providerName == "gen_ai.provider.name")
    #expect(SIEMExporter.GenAIAttribute.requestModel == "gen_ai.request.model")
    #expect(SIEMExporter.GenAIAttribute.usageInputTokens == "gen_ai.usage.input_tokens")
}
