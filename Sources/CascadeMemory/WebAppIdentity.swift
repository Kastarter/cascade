import Foundation

/// Identifies the web app / site a browser window is showing, from its title — so a
/// workflow done INSIDE the browser is recognized as the real app (Gmail, Notion,
/// Google Docs, Figma…) instead of being lumped under "Safari" / "Chrome".
///
/// Browsers put the site brand LAST after a separator:
///   "Inbox (5) - me@example.com - Gmail" → "Gmail"
///   "Q3 plan - Google Docs"              → "Google Docs"
///   "(2) Feed | LinkedIn"                → "LinkedIn"
/// When there's no separator the brand can't be named reliably, so this returns nil
/// and the caller keeps the browser's own name. A volatile last segment (a doc title,
/// a count) is self-correcting downstream: it won't repeat, so it never forms a
/// detected workflow — a bad guess costs a missed detection, never a wrong one.
public enum WebAppIdentity {
    /// Title separators, matched in order; the first present one splits the title.
    private static let separators = [" — ", " – ", " - ", " | ", " · ", " • ", " :: "]

    public static func from(windowTitle: String?) -> String? {
        guard let raw = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        for separator in separators where raw.contains(separator) {
            let parts = raw
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2, let brand = parts.last else { continue }
            // A brand is a short label, not a sentence — cap it so a content tail
            // can't masquerade as an app name.
            let cleaned = String(brand.prefix(40))
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}
