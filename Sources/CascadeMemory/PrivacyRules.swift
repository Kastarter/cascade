import Foundation

/// The privacy boundary for everything Cascade observes. A moment is dropped
/// entirely — never saved, never OCR'd, never stored — when its app/window/text
/// looks sensitive (banking, health, legal, dating, private browsing, password
/// managers, wallets). Lives in `CascadeMemory` so both the recorder
/// (`MacContextKit`) and downstream consumers (`WasteDetection`) can gate on it
/// without depending on each other.
public enum PrivacyRules {
    public static let defaultSensitiveKeywords = [
        "bank", "health", "medical", "legal", "dating", "incognito", "private browsing",
        "password", "1password", "keychain", "wallet",
        // Credential labels — matched so the VALUE on the same line gets redacted too
        // (see FrameRedactor line-level redaction).
        "api key", "api-key", "apikey", "secret key", "private key", "access token",
        "passphrase", "seed phrase", "credential", "routing number", "account number",
        "social security", "ssn", "cvv", "pin code"
    ]

    /// Keywords that mark a moment as off-limits. Matched case-insensitively
    /// across app name, bundle id, window title, and OCR text.
    public static let sensitiveKeywords = defaultSensitiveKeywords

    public static let defaultPolicy = CapturePrivacyPolicy.default

    public static func isSensitive(_ context: RecordedContext) -> Bool {
        !defaultPolicy.decision(
            appName: context.appName,
            bundleIdentifier: context.bundleIdentifier,
            windowTitle: context.windowTitle,
            text: context.ocrText
        ).allowed
    }

    /// Cheaper pre-OCR gate: checks only app/bundle/window so we can drop a frame
    /// before paying for OCR. The full `isSensitive(_:)` re-checks once OCR text
    /// is available.
    public static func isSensitive(appName: String, bundleIdentifier: String?, windowTitle: String?) -> Bool {
        !defaultPolicy.decision(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle
        ).allowed
    }

    /// Gate for a single piece of captured text (e.g. the AX label of a clicked
    /// element) when the surrounding app/window already passed: the text itself
    /// must not smuggle a sensitive phrase into the store.
    public static func isSensitiveText(_ text: String) -> Bool {
        defaultPolicy.isSensitiveText(text)
    }

    public static func redactingSensitiveKeywords(in text: String) -> String {
        defaultPolicy.redactingSensitiveKeywords(in: text)
    }
}
