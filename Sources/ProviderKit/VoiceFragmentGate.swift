import Foundation

/// Classifies one voice transcription before it may become an agent goal.
///
/// The transcriber hands over EVERYTHING the mic hears, and the audit log shows
/// what that did to real sessions (2026-06-11): one-word interjections ("Iii!",
/// "Hi", "はあ", "مريم."), punctuation shards ("。""), and filler sentences
/// ("Okay, thank you.") each spawned a full screen-control run — and because
/// every new goal supersedes the live one, each fragment KILLED whatever real
/// task was running. Set-based acknowledgment matching didn't hold (internal
/// punctuation and novel filler defeat exact lookups), so this gate is
/// compositional: filler vocabulary + structure, pinned by tests.
public enum VoiceFragmentGate {
    public enum Verdict: Equatable {
        /// Run it — cleaned of dangling lead-in filler ("And create…" → "create…").
        case goal(String)
        /// Ignore it: interjection, fragment, or pure filler. Never a task, and
        /// critically never a supersession of a running task.
        case noise
    }

    public static func classify(_ utterance: String) -> Verdict {
        let cleaned = strippingDanglingLead(utterance)
        return isNoise(cleaned) ? .noise : .goal(cleaned)
    }

    /// Conversational filler that carries no task content on its own.
    static let fillerWords: Set<String> = [
        "ok", "okay", "k", "sure", "yes", "yep", "yeah", "no", "nah",
        "thanks", "thank", "you", "cool", "nice", "good", "great", "perfect",
        "awesome", "alright", "all", "right", "well", "so", "and", "or", "but",
        "then", "also", "now", "please", "hmm", "uh", "um", "huh", "hey", "hi",
        "hello", "bye", "goodbye",
    ]

    /// Leading filler a transcriber bolts onto the front of a command when the
    /// user pauses mid-sentence ("And create…", "Okay, now, can you…"). Dropped
    /// one token at a time while a real command (≥2 words) remains behind them.
    static func strippingDanglingLead(_ utterance: String) -> String {
        var tokens = utterance.split(separator: " ").map(String.init)
        while tokens.count > 2, let first = tokens.first,
              fillerWords.contains(normalizedWord(first)) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// A goal needs the shape of a command: at least two words, at least four
    /// letters, and not composed of filler alone.
    static func isNoise(_ utterance: String) -> Bool {
        let words = utterance.split(separator: " ").map { normalizedWord(String($0)) }.filter { !$0.isEmpty }
        if words.count < 2 { return true }
        if words.allSatisfy({ fillerWords.contains($0) }) { return true }
        let letters = utterance.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters < 4
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}
