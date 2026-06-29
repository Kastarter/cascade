import CoreGraphics
import Foundation

// Conversation memory for the voice/hotkey assistant, so follow-ups work
// ("highlight my WhatsApp messages" → "now reply to the first one"). Ported from
// the CompanionManager pattern in `farzaa/clicky` and `jasonkneen/openclicky`
// (MIT): a small rolling window of (user, assistant) text turns replayed as plain
// messages before the current screenshot turn, older turns compacted into a
// persisted text archive, and structured "last pointed element" state for
// referential commands like "click that". Screenshots are never kept across
// turns — only the words. See docs/THIRD_PARTY_NOTICES.md.
@MainActor
public final class AssistMemory {
    public struct Turn: Sendable, Equatable {
        public let user: String
        public let assistant: String
        public let at: Date
        /// Whether the exchange succeeded. Failed/stopped turns stay useful as
        /// IMMEDIATE context ("you just stopped me") but are dropped at compaction
        /// instead of archived — a stale "I lost sight of the screen" from
        /// yesterday must never poison future calls.
        public let ok: Bool
        /// Conversation history helps resolve references but is not a fresh
        /// authorization channel for power or irreversible actions.
        public let provenance: ContentTrust
        public let safeForControl: Bool

        public init(
            user: String,
            assistant: String,
            at: Date = Date(),
            ok: Bool = true,
            provenance: ContentTrust = .trustedUserInstruction,
            safeForControl: Bool = false
        ) {
            self.user = user
            self.assistant = assistant
            self.at = at
            self.ok = ok
            self.provenance = provenance
            self.safeForControl = safeForControl
        }
    }

    /// The element the assistant last pointed at / framed on screen, so a
    /// follow-up "click that" can act instantly without another vision call.
    public struct PointedElement: Sendable {
        /// What the user asked for when it was pointed at (e.g. "the Send button").
        public let label: String
        /// Global AppKit point (bottom-left origin, like NSEvent.mouseLocation).
        public let globalPoint: CGPoint
        public let at: Date
    }

    /// Active turns kept verbatim (openclicky uses 8 — enough for follow-ups,
    /// small enough to never crowd out the screenshot).
    static let activeTurnLimit = 8
    /// Per-turn caps. Every active turn is resent on EVERY model call in the
    /// session, so one rambling summary must not tax all later turns — the worst
    /// case (8 turns × ~700 chars + the archive) stays under ~2k tokens, noise
    /// against a ~1.5k-token screenshot per loop step.
    static let userCharacterLimit = 280
    static let assistantCharacterLimit = 420
    /// Older turns survive as a trailing compacted transcript, hard-capped.
    static let archiveCharacterLimit = 2_400
    /// How long a pointed element stays valid for "click that".
    static let pointedElementLifetime: TimeInterval = 120
    /// How long the conversation counts as "live" for follow-up routing.
    static let followUpWindow: TimeInterval = 240

    private static let archiveDefaultsKey = "cascade.assist.compactedArchive"

    public private(set) var turns: [Turn] = []
    public private(set) var lastPointed: PointedElement?
    private var compactedArchive: String?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        compactedArchive = defaults.string(forKey: Self.archiveDefaultsKey)
    }

    /// Records one finished exchange. Older successful turns beyond the active
    /// window are folded into the compacted archive (persisted); failed turns
    /// (`ok: false`) age out of the window and disappear.
    public func remember(
        user: String,
        assistant: String,
        at: Date = Date(),
        ok: Bool = true,
        provenance: ContentTrust = .trustedUserInstruction,
        safeForControl: Bool = false
    ) {
        let u = Self.capped(user, at: Self.userCharacterLimit)
        let a = Self.capped(assistant, at: Self.assistantCharacterLimit)
        guard !u.isEmpty else { return }
        turns.append(Turn(
            user: u,
            assistant: a.isEmpty ? "(no reply)" : a,
            at: at,
            ok: ok,
            provenance: provenance,
            safeForControl: safeForControl
        ))
        compactIfNeeded()
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public func rememberPointed(label: String, globalPoint: CGPoint, at: Date = Date()) {
        lastPointed = PointedElement(label: label, globalPoint: globalPoint, at: at)
    }

    /// The pointed element if it is still fresh enough to act on.
    public func freshPointed(now: Date = Date()) -> PointedElement? {
        guard let pointed = lastPointed,
              now.timeIntervalSince(pointed.at) <= Self.pointedElementLifetime else { return nil }
        return pointed
    }

    /// Whether the conversation is recent enough that a referential utterance
    /// ("now the second one") should inherit the previous turn's routing.
    public func isFollowUpWindowOpen(now: Date = Date()) -> Bool {
        guard let last = turns.last else { return false }
        return now.timeIntervalSince(last.at) <= Self.followUpWindow
    }

    /// History shaped for the Messages API: the compacted archive rides along as a
    /// synthetic earliest exchange, then the active turns verbatim.
    public func historyForAPI() -> [(user: String, assistant: String)] {
        var history: [(user: String, assistant: String)] = []
        if let compactedArchive, !compactedArchive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.append((user: "[earlier conversation in this session]", assistant: compactedArchive))
        }
        history.append(contentsOf: turns.map { (user: $0.user, assistant: $0.assistant) })
        return history
    }

    /// Plain-text rendering for prompts that take a single string (the task
    /// planner), so it can resolve "them" / "that one" while splitting a job.
    public func contextMemo(maxTurns: Int = 4) -> String {
        let recent = turns.suffix(maxTurns)
        guard !recent.isEmpty else { return "" }
        return recent
            .map { "User: \($0.user)\nCascade: \($0.assistant)" }
            .joined(separator: "\n")
    }

    public func clear() {
        turns = []
        lastPointed = nil
        compactedArchive = nil
        defaults.removeObject(forKey: Self.archiveDefaultsKey)
    }

    private func compactIfNeeded() {
        let overflow = turns.count - Self.activeTurnLimit
        guard overflow > 0 else { return }
        let archived = turns.prefix(overflow).filter(\.ok)  // failures age out, never archive
        turns.removeFirst(overflow)
        guard !archived.isEmpty else { return }

        let chunk = archived
            .map {
                "User: \(Self.snippet($0.user))\nCascade: \(Self.snippet($0.assistant))\nContext provenance: \($0.provenance.rawValue); safeForControl=false"
            }
            .joined(separator: "\n")
        let merged = [compactedArchive, chunk].compactMap { $0 }.joined(separator: "\n")
        compactedArchive = String(merged.suffix(Self.archiveCharacterLimit))
        defaults.set(compactedArchive, forKey: Self.archiveDefaultsKey)
    }

    private static func snippet(_ text: String, max: Int = 200) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        guard line.count > max else { return line }
        return String(line.prefix(max)) + "…"
    }
}
