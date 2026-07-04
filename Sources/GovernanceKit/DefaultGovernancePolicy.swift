import CascadeMemory
import Foundation
import PerceptionCore

/// The built-in DEFAULT policy: behavior == TODAY, verbatim.
///
/// Capture: wraps `CapturePrivacyPolicy.decision(appName:bundleIdentifier:windowTitle:)`
/// exactly — `.allowed` ⇒ `.allow`, denied ⇒ `.drop` with the SAME reason strings
/// (denied_app / denied_bundle / denied_window_title / sensitive_keyword:* /
/// bundle_not_allowed). It NEVER returns `.redact` (dab9e5c: never redact-only).
/// NOTE: today's shipped gate KEEPS private-mode frames (FrameRedactor redacts
/// downstream — CapturePrivacyPolicy.swift:140-172 documents why dropping froze the
/// Reel), so the default policy allows them too. Behavior == TODAY wins over the
/// plan's "private-mode ⇒ drop" prose; flipping that is a future TenantPolicy
/// decision behind its own gate.
///
/// Action: `.allow` unconditionally — today executeCU has no policy gate at this
/// point; the existing refusal lists (paste gate, isIrreversibleCombo,
/// SecureInputGuard) stay where they live in ComputerUseAgent/actuator and are not
/// duplicated here.
public struct DefaultGovernancePolicy: PolicyEnforcing {
    public let capture: CapturePrivacyPolicy
    /// Accepted but unused (stub) — future tenant knobs land behind their own gate.
    public let tenant: TenantPolicy?

    public init(capture: CapturePrivacyPolicy, tenant: TenantPolicy? = nil) {
        self.capture = capture
        self.tenant = tenant
    }

    public func evaluateCapture(_ ctx: CaptureContext) -> PolicyVerdict {
        let decision = capture.decision(
            appName: ctx.appName,
            bundleIdentifier: ctx.bundleIdentifier,
            windowTitle: ctx.windowTitle
        )
        if decision.allowed { return .allow }
        return .drop(reason: decision.reason ?? "denied")
    }

    public func evaluateAction(_ action: ActionDescriptor, risk: ActionRisk) -> PolicyVerdict {
        .allow
    }
}
