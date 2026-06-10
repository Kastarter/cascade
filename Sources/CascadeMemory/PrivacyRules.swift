import Foundation

/// The privacy boundary for everything Cascade observes. A moment is dropped
/// entirely — never saved, never OCR'd, never stored — when its app/window/text
/// looks sensitive (banking, health, legal, dating, private browsing, password
/// managers, wallets). Lives in `CascadeMemory` so both the recorder
/// (`MacContextKit`) and downstream consumers (`SuggestionEngine`) can gate on it
/// without depending on each other.
public enum PrivacyRules {
    /// Keywords that mark a moment as off-limits. Matched case-insensitively
    /// across app name, bundle id, window title, and OCR text.
    public static let sensitiveKeywords = [
        "bank", "health", "medical", "legal", "dating", "incognito", "private browsing",
        "password", "1password", "keychain", "wallet"
    ]

    public static func isSensitive(_ context: RecordedContext) -> Bool {
        let haystack = [
            context.appName,
            context.bundleIdentifier ?? "",
            context.windowTitle ?? "",
            context.ocrText ?? ""
        ].joined(separator: " ").lowercased()
        return sensitiveKeywords.contains { haystack.contains($0) }
    }

    /// Cheaper pre-OCR gate: checks only app/bundle/window so we can drop a frame
    /// before paying for OCR. The full `isSensitive(_:)` re-checks once OCR text
    /// is available.
    public static func isSensitive(appName: String, bundleIdentifier: String?, windowTitle: String?) -> Bool {
        let haystack = [
            appName,
            bundleIdentifier ?? "",
            windowTitle ?? ""
        ].joined(separator: " ").lowercased()
        return sensitiveKeywords.contains { haystack.contains($0) }
    }

    /// Gate for a single piece of captured text (e.g. the AX label of a clicked
    /// element) when the surrounding app/window already passed: the text itself
    /// must not smuggle a sensitive phrase into the store.
    public static func isSensitiveText(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return sensitiveKeywords.contains { haystack.contains($0) }
    }
}
