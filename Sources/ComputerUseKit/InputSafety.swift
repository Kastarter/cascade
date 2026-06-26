import Foundation
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

/// macOS "Secure Input" — engaged when a password field has focus (or by some
/// terminals/password managers) — silently DROPS synthetic keyboard events. When
/// it's active the agent "types" into the void: keys press, nothing lands. We
/// detect it and refuse with a clear message instead of failing invisibly, which
/// was a real "it's pressing but nothing is written" failure mode (SEQ-09).
public enum SecureInputGuard {
    /// Whether macOS Secure Input is currently engaged process-wide.
    public static func isActive() -> Bool {
        #if canImport(Carbon)
        return IsSecureEventInputEnabled()
        #else
        return false
        #endif
    }

    /// A user-facing refusal reason when synthetic keyboard input can't land, or
    /// nil when typing is safe. Pure (takes the state) so it's unit-testable
    /// without toggling system-wide Secure Input.
    public static func refusalReason(secureInputActive: Bool) -> String? {
        guard secureInputActive else { return nil }
        return "macOS Secure Input is active (a password field has focus), so synthetic "
            + "keystrokes won't register. Ask the user to type this themselves, or move focus "
            + "out of the secure field, then retry."
    }
}

/// Splits text into UTF-16 chunks for `keyboardSetUnicodeString` that NEVER split
/// a grapheme cluster. Emoji, flags, skin-tone/ZWJ sequences, and combining marks
/// span multiple UTF-16 units; cutting them on a raw fixed window injects a broken
/// half-glyph (the classic "🎉" → two replacement chars) or drops the character.
public enum TextChunker {
    /// Grapheme-safe chunks, each at most `maxUTF16` UTF-16 units — except a single
    /// grapheme longer than `maxUTF16`, which becomes its own chunk rather than
    /// being split.
    public static func graphemeSafeChunks(_ text: String, maxUTF16: Int = 16) -> [[UniChar]] {
        precondition(maxUTF16 > 0)
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            // Flush before this grapheme would overflow the window.
            if !current.isEmpty, current.count + units.count > maxUTF16 {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
            // A single grapheme at/over the window is emitted whole on its own.
            if current.count >= maxUTF16 {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
