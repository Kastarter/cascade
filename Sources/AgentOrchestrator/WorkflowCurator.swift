import CascadeMemory
import Foundation
import OSLog
import ProviderKit
import SuggestionEngine

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
    public func curate(_ candidates: [DetectedWaste]) async -> [CuratedAgent] {
        guard !candidates.isEmpty else { return [] }
        let raw = try? await client.complete(
            system: Self.systemPrompt,
            user: Self.userPrompt(candidates),
            model: model,
            maxTokens: 900
        )
        if let raw, let picked = Self.parse(raw, candidates: candidates) {
            return picked
        }
        Self.logger.error("curator fell back to the raw detector list — \(raw == nil ? "request failed" : "reply did not parse", privacy: .public)")
        return candidates.map(Self.fallback)
    }

    private static let logger = Logger(subsystem: "com.humain.cascade", category: "curator")

    static let systemPrompt = """
    You curate a list of repeated workflows the system detected by watching the user \
    repeat the same actions, into the few that are genuinely worth turning into an \
    agent FOR THIS USER.

    For each candidate, judge: is automating this actually useful, or is it noise — \
    incidental reading, scrolling, navigation, or one-off clicking a person would \
    never hand off? KEEP only the worthwhile ones. It is correct to keep none.

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

    Reply with ONLY this JSON, no prose:
    {"agents":[{"index":0,"name":"...","why":"...","goal":"...","value":0.8}]}
    """

    /// The candidates as a compact numbered list — the facts the curator judges on.
    static func userPrompt(_ candidates: [DetectedWaste]) -> String {
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
