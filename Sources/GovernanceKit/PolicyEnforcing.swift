// GovernanceKit — enterprise policy choke points (§3.2/§7).
//
// Dependency discipline: this target depends on CascadeMemory (CapturePrivacyPolicy)
// and PerceptionCore (ActionDescriptor/ActionRisk/Rect<FrameSpace>) ONLY. It must
// NEVER import ProviderKit — governance speaks PerceptionCore's ActionDescriptor,
// not CUAction, so the graph stays acyclic (ProviderKit ← AppShell maps CUAction →
// ActionDescriptor at the callsite).

import Foundation
import PerceptionCore

/// What a policy says about one capture frame or one screen action.
public enum PolicyVerdict: Equatable, Sendable {
    /// Proceed exactly as today.
    case allow
    /// Proceed, but redact these frame-space regions first. The built-in default
    /// policy NEVER emits this (dab9e5c: never redact-only) — FrameRedactor remains
    /// the redaction owner; the case exists for future tenant policies.
    case redact(regions: [Rect<FrameSpace>])
    /// Do not persist the frame / do not perform the action.
    case drop(reason: String)
    /// Do not proceed; a supervisor must resume. Callers without a pause surface
    /// treat this like `.drop`.
    case pause(reason: String)
}

/// Exactly the three fields RewindEngine.process hands to the capture policy today
/// (the pre-OCR gate passes no text — `text: nil`).
public struct CaptureContext: Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?

    public init(appName: String, bundleIdentifier: String? = nil, windowTitle: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
    }
}

/// A policy enforcer both choke points call synchronously (inside the RewindEngine
/// actor and MainActor executeCU), so conformers must be Sendable value types or
/// internally synchronized references.
public protocol PolicyEnforcing: Sendable {
    func evaluateCapture(_ ctx: CaptureContext) -> PolicyVerdict
    func evaluateAction(_ action: ActionDescriptor, risk: ActionRisk) -> PolicyVerdict
}

/// `cascade.governance` — default OFF (absent ⇒ false ⇒ byte-identical to today).
/// Read ONCE at construction (ContextRecorder.Options / CascadeAppModel init),
/// never per frame or per action.
public enum GovernanceFlag {
    public static let key = "cascade.governance"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}
