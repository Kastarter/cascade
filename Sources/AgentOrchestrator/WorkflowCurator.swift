import CascadeMemory
import Foundation
import OSLog
import ProviderKit
import WasteDetection

/// A detected workflow the curator judged worth turning into an agent — named in
/// the user's words, with a one-line reason and the intent goal a deployed agent
/// would carry out. It carries its `source` `DetectedWaste` so approving still
/// builds the real agent from the recorded recipe.
public struct CuratedAgent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: DetectedWaste
    /// What the task IS, in the user's words ("Reply to refund emails with the
    /// policy link") — never "Repeated steps in Mail".
    public let name: String
    /// One short line: why automating THIS helps THIS user.
    public let why: String
    /// A single imperative a computer-use agent can carry out from intent — not a
    /// list of recorded clicks. This is what a deployed agent actually runs.
    public let goal: String
    /// 0…1, the curator's judged value — orders the cards and sets a "worth it" bar.
    public let value: Double

    public init(id: UUID = UUID(), source: DetectedWaste, name: String, why: String, goal: String, value: Double) {
        self.id = id
        self.source = source
        self.name = name
        self.why = why
        self.goal = goal
        self.value = value
    }

    public var signature: String { source.signature }
    public var evidence: [Int64] { source.evidence }
    public var apps: [String] { source.apps }
}

/// The intelligence layer over `WasteDetector`. The detector is mechanical recall —
/// it finds *repeated* action sequences. The curator decides which of those are
/// genuinely worth automating for this user, names them like a person would, writes
/// the intent goal a deployed agent runs, and drops the noise (incidental reading,
/// navigation, things nobody would hand off). It is strictly grounded — it can only
/// keep candidates the detector actually saw — and on any failure it degrades to the
/// raw detector list, so curation is never worse than showing everything.
public struct WorkflowCurator: Sendable {
    private let client: any MessageCompleting
    private let model: String

    public init(client: any MessageCompleting = AnthropicClient(), model: String = AnthropicModel.sonnet) {
        self.client = client
        self.model = model
    }

    /// Judges, names, and prunes the detector's candidates. Returns the kept,
    /// enriched proposals (possibly empty — the curator is allowed to decide that
    /// nothing is worth automating). Falls back to the raw list only when the call
    /// or the parse fails, never to paper over an intentional "keep none".
    /// `onScreen` carries, per candidate `signature`, a short privacy-filtered
    /// excerpt of the text actually visible while the user did the work (resolved by
    /// the orchestrator from the recorded OCR/AX). It is what lets the curator write a
    /// *content-aware* goal ("reply to refund-request emails") instead of a shape-only
    /// one ("reply to emails"). Optional — with none, behaviour is exactly as before.
    public func curate(_ candidates: [DetectedWaste], onScreen: [String: String] = [:]) async -> [CuratedAgent] {
        guard !candidates.isEmpty else { return [] }
        let raw = try? await client.complete(
            system: Self.systemPrompt,
            user: Self.userPrompt(candidates, onScreen: onScreen),
            model: model,
            maxTokens: 900
        )
        if let raw, let picked = Self.parse(raw, candidates: candidates) {
            return picked
        }
        Self.logger.error("curator fell back to the raw detector list — \(raw == nil ? "request failed" : "reply did not parse", privacy: .public)")
        return candidates.map(Self.fallback)
    }

    /// Curates ONE recorded recipe — a Teach-once demonstration (or a Reel
    /// selection) — into a named, grounded `CuratedAgent`. Unlike `curate`, it
    /// judges a single recipe that may have occurred only once and may run
    /// on-screen, and it folds in the user's spoken `statedIntent` (what they said
    /// while demonstrating) as the strongest signal for the name and goal. It
    /// ALWAYS returns a candidate: a deliberate demonstration is something the user
    /// wants, so a failed/empty model reply degrades to the detector's own naming
    /// (`fallback`) — never worse than the automatic path, never nothing.
    public func curateOne(_ waste: DetectedWaste, statedIntent: String? = nil, onScreen: String? = nil) async -> CuratedAgent {
        let intent = statedIntent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try? await client.complete(
            system: Self.curateOneSystemPrompt,
            user: Self.userPromptOne(waste, statedIntent: (intent?.isEmpty == false) ? intent : nil, onScreen: onScreen),
            model: model,
            maxTokens: 400
        )
        if let raw, let picked = Self.parse(raw, candidates: [waste])?.first {
            return picked
        }
        Self.logger.error("single-recipe curation fell back to detector naming — \(raw == nil ? "request failed" : "reply did not parse", privacy: .public)")
        return Self.fallback(waste)
    }

    private static let logger = Logger(subsystem: "com.humain.cascade", category: "curator")

    static let curateOneSystemPrompt = """
    The user just DEMONSTRATED a task by hand for you to turn into an agent — they \
    did it once, on purpose, and want it automated. Your job is to name it the way \
    they would and write the goal a deployed agent will carry out. This is NOT noise \
    filtering: they chose to record this, so you KEEP it and describe it well.

    It may run in the browser (a background web agent) or in a native app (an \
    on-screen agent reproduces it) — that routing is decided elsewhere, so don't say \
    where it runs.

    Return one kept entry:
    - "index": always 0 (there is a single recipe).
    - "name": what the task IS, in the user's words (e.g. "Compile the weekly \
    numbers into the Monday report") — never "Repeated steps in <app>".
    - "why": one short line on why automating it helps (time saved, tedium, error-prone).
    - "goal": ONE imperative instruction a computer-use agent could carry out to \
    reproduce the task from intent — NOT a list of clicks. Carry the concrete \
    app/site and what it accomplishes.
    - "value": 0.0–1.0, how worth-automating it is.

    If the user told you in their own words what they were doing, THAT description is \
    the strongest signal — base the name and goal on it. When an "on screen" line is \
    given, it is the text actually visible while they worked — use it to make the name \
    and goal CONCRETE about the real subject matter (e.g. "reply to the refund-request \
    emails", "update the Q2 pipeline sheet"), not generic. Never invent steps the \
    recipe does not contain, and never copy private values verbatim into the goal.

    Reply with ONLY this JSON, no prose:
    {"agents":[{"index":0,"name":"...","why":"...","goal":"...","value":0.8}]}
    """

    /// The single recorded recipe as the curator's input, with the on-screen content
    /// and the user's spoken intent appended when present.
    static func userPromptOne(_ waste: DetectedWaste, statedIntent: String?, onScreen: String? = nil) -> String {
        let apps = waste.apps.joined(separator: " → ")
        let steps = waste.recipe.humanSteps
            .filter { $0 != "type" && $0 != "scroll" }
            .prefix(8)
            .joined(separator: ", ")
        var lines = ["The recorded demonstration:"]
        var line = "[0] “\(waste.title)” · apps: \(apps.isEmpty ? "—" : apps) · ~\(waste.estimatedSecondsPerRun)s"
        if !steps.isEmpty { line += " · steps: \(steps)" }
        lines.append(line)
        if let onScreen, !onScreen.isEmpty {
            lines.append("    on screen: “\(onScreen)”")
        }
        if let statedIntent, !statedIntent.isEmpty {
            lines.append("")
            lines.append("What the user SAID while demonstrating (their own words — use them): “\(statedIntent)”")
        }
        return lines.joined(separator: "\n")
    }

    static let systemPrompt = """
    You curate a list of repeated workflows the system detected by watching the user \
    repeat the same actions, into the few that are genuinely worth turning into an \
    agent FOR THIS USER.

    Every candidate already cleared two bars before reaching you: it repeats at least \
    three times, and it represents real time. Some run entirely in the browser (a \
    background web agent carries those out while the user keeps working); others run in \
    native apps (an on-screen agent reproduces those). Your job is the final judgment of \
    WORTH — not where it runs.

    For each candidate, judge: would automating this actually save real time and \
    tedium, or is it noise — incidental reading, scrolling, navigation, or one-off \
    clicking a person would never hand off? KEEP only the ones genuinely worth handing \
    to an agent. It is correct to keep none.

    For each KEPT candidate return:
    - "index": the candidate's number from the list.
    - "name": what the task IS, in the user's words (e.g. "Reply to refund emails \
    with the policy link") — never "Repeated steps in <app>".
    - "why": one short line on why automating it helps this user (time saved, tedium, \
    error-prone). If it is web-only work, it can run in the background while they keep working.
    - "goal": ONE imperative instruction a computer-use agent could carry out to \
    reproduce the task from intent — NOT a list of clicks. Carry the concrete app/site \
    and what it accomplishes.
    - "value": 0.0–1.0, how worth-automating it is.

    Judge each candidate on its own merit — a task can qualify whether it touches one \
    app or several, and whatever kind of work it is (data, writing, design, admin, \
    browsing, anything). What matters is that it genuinely repeats and is worth handing \
    off — never how well it fits a particular shape. Never invent a workflow that is not \
    in the candidates.

    Some candidates include an "on screen" sub-line: the text actually visible while the \
    user did the work. USE it to make the name and goal content-aware about the real \
    subject matter (e.g. "reply to refund-request emails with the policy link" rather \
    than "reply to emails") — but NEVER invent details the snippet does not show, and \
    never copy private/sensitive values verbatim into the goal.

    Reply with ONLY this JSON, no prose:
    {"agents":[{"index":0,"name":"...","why":"...","goal":"...","value":0.8}]}
    """

    /// The candidates as a compact numbered list — the facts the curator judges on.
    /// When `onScreen[signature]` holds the text visible while a workflow happened, it
    /// is added as an indented sub-line so the curator can name the real subject matter.
    static func userPrompt(_ candidates: [DetectedWaste], onScreen: [String: String] = [:]) -> String {
        var lines = ["Candidates:"]
        for (index, waste) in candidates.enumerated() {
            let apps = waste.apps.joined(separator: " → ")
            let steps = waste.recipe.humanSteps
                .filter { $0 != "type" && $0 != "scroll" }
                .prefix(6)
                .joined(separator: ", ")
            var line = "[\(index)] “\(waste.title)” · apps: \(apps.isEmpty ? "—" : apps)"
            line += " · seen \(waste.occurrences)× (~\(waste.estimatedSecondsPerRun)s each)"
            if !steps.isEmpty { line += " · steps: \(steps)" }
            lines.append(line)
            if let screen = onScreen[waste.signature], !screen.isEmpty {
                lines.append("    on screen: “\(screen)”")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the reply, tolerating prose or code fences. Returns nil ONLY when the
    /// JSON can't be found/decoded (so the caller falls back); an empty kept-list is
    /// a valid, respected answer.
    static func parse(_ raw: String, candidates: [DetectedWaste]) -> [CuratedAgent]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let dto = try? JSONDecoder().decode(CurationDTO.self, from: data) else { return nil }
        var seen = Set<Int>()
        var kept: [CuratedAgent] = []
        for item in dto.agents {
            guard let index = item.index, candidates.indices.contains(index), !seen.contains(index) else { continue }
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = (item.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !goal.isEmpty else { continue }
            seen.insert(index)
            let waste = candidates[index]
            kept.append(CuratedAgent(
                source: waste,
                name: String(name.prefix(80)),
                why: String((item.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(140)),
                goal: String(goal.prefix(240)),
                value: min(1, max(0, item.value ?? waste.confidence))
            ))
        }
        // Strongest first; ties keep the detector's (time-saved) order via a stable sort.
        return kept.sorted { $0.value > $1.value }
    }

    /// Mechanical proposal used when the model is unavailable — exactly today's
    /// behaviour (show every detected workflow), just in the curated shape.
    static func fallback(_ waste: DetectedWaste) -> CuratedAgent {
        CuratedAgent(
            source: waste,
            name: waste.title,
            why: "You've done this \(waste.occurrences)× — Cascade can take it over.",
            goal: waste.title,
            value: waste.confidence
        )
    }

    private struct CurationDTO: Decodable {
        let agents: [Item]
        struct Item: Decodable {
            let index: Int?
            let name: String?
            let why: String?
            let goal: String?
            let value: Double?
        }
    }
}
