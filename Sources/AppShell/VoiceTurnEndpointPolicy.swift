import Foundation

/// Pure endpoint policy for push-to-talk turns after local VAD/energy timing.
///
/// The policy deliberately has no audio hardware or PCM dependency. It only
/// decides what the caller should do with already observed timing state.
public struct VoiceTurnEndpointPolicy: Sendable {
    public struct Settings: Equatable, Sendable {
        public let minSpeechMs: Int
        public let hangoverMs: Int
        public let maxTailMs: Int
        public let lexicalFragmentWaitMs: Int

        public init(
            minSpeechMs: Int = 210,
            hangoverMs: Int = 240,
            maxTailMs: Int = 750,
            lexicalFragmentWaitMs: Int = 150
        ) {
            self.minSpeechMs = max(0, minSpeechMs)
            self.hangoverMs = max(0, hangoverMs)
            self.maxTailMs = max(0, maxTailMs)
            self.lexicalFragmentWaitMs = max(0, lexicalFragmentWaitMs)
        }
    }

    public struct Timing: Equatable, Sendable {
        public let nowMs: Int
        public let keyDownAtMs: Int
        public let keyUpAtMs: Int?
        public let speechStartedAtMs: Int?
        public let lastSpeechAtMs: Int?
        public let uploadedSpeechMs: Int
        public let hasUnfinishedLexicalFragment: Bool

        public init(
            nowMs: Int,
            keyDownAtMs: Int,
            keyUpAtMs: Int?,
            speechStartedAtMs: Int?,
            lastSpeechAtMs: Int?,
            uploadedSpeechMs: Int,
            hasUnfinishedLexicalFragment: Bool = false
        ) {
            self.nowMs = nowMs
            self.keyDownAtMs = keyDownAtMs
            self.keyUpAtMs = keyUpAtMs
            self.speechStartedAtMs = speechStartedAtMs
            self.lastSpeechAtMs = lastSpeechAtMs
            self.uploadedSpeechMs = max(0, uploadedSpeechMs)
            self.hasUnfinishedLexicalFragment = hasUnfinishedLexicalFragment
        }
    }

    public enum Decision: Equatable, Sendable {
        case clear
        case appendOnly
        case tailWait(remainingMs: Int)
        case commitNow
    }

    public let settings: Settings

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public func decide(_ timing: Timing) -> Decision {
        guard timing.keyUpAtMs == nil || timing.keyUpAtMs! >= timing.keyDownAtMs else {
            return .clear
        }

        guard hasValidSpeech(timing) else {
            return timing.keyUpAtMs == nil ? .appendOnly : .clear
        }

        guard let keyUpAtMs = timing.keyUpAtMs else {
            return .appendOnly
        }

        let tailElapsedMs = max(0, timing.nowMs - keyUpAtMs)
        let maxTailRemainingMs = settings.maxTailMs - tailElapsedMs
        guard maxTailRemainingMs > 0 else {
            return .commitNow
        }

        let silenceAfterSpeechMs = max(0, timing.nowMs - (timing.lastSpeechAtMs ?? timing.nowMs))
        let hangoverRemainingMs = settings.hangoverMs - silenceAfterSpeechMs
        if hangoverRemainingMs > 0 {
            return .tailWait(remainingMs: min(hangoverRemainingMs, maxTailRemainingMs))
        }

        if timing.hasUnfinishedLexicalFragment, settings.lexicalFragmentWaitMs > 0 {
            return .tailWait(remainingMs: min(settings.lexicalFragmentWaitMs, maxTailRemainingMs))
        }

        return .commitNow
    }

    public static func hasUnfinishedLexicalFragment(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:")))
        guard !normalized.isEmpty else { return false }

        let leadIns: Set<String> = [
            "and", "then", "and then", "can you", "could you", "would you",
            "please", "open", "find", "search", "look up", "go to", "click",
            "select", "move", "copy", "paste",
        ]
        if leadIns.contains(normalized) { return true }
        if leadIns.contains(where: { normalized.hasSuffix(" " + $0) }) { return true }

        let trailingWords: Set<String> = [
            "and", "or", "then", "to", "for", "with", "in", "on", "at",
            "from", "into", "onto", "of", "by", "about", "as", "after",
            "before", "when", "while", "because", "if",
        ]
        let words = normalized.split(separator: " ").map(String.init)
        guard let last = words.last else { return false }
        return trailingWords.contains(last)
    }

    private func hasValidSpeech(_ timing: Timing) -> Bool {
        guard timing.uploadedSpeechMs >= settings.minSpeechMs,
              let speechStartedAtMs = timing.speechStartedAtMs,
              let lastSpeechAtMs = timing.lastSpeechAtMs
        else {
            return false
        }
        return lastSpeechAtMs >= speechStartedAtMs
    }
}
