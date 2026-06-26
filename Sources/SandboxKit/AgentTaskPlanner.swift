import Foundation
import OSLog
import ProviderKit

/// One part of a job, sized so a single Computer Use episode can finish it within
/// its own step budget.
public struct AgentSubtask: Sendable, Equatable {
    /// What to actually DO (imperative, self-contained).
    public let task: String
    /// The page to start this part on. Empty means "continue where the previous
    /// part finished".
    public let startURL: String
    /// On-screen jobs only: the exact macOS app this part happens in, opened
    /// instantly before the episode starts. Empty when `startURL` applies or the
    /// part continues in place.
    public let app: String
    /// Web-sandbox jobs only: whether this part can be done in a browser at all.
    /// Native-only parts (local apps, local files) are reported back to the user,
    /// never attempted blind.
    public let web: Bool
    /// For non-web sandbox parts: a short reason shown to the user.
    public let note: String

    public init(task: String, startURL: String = "", app: String = "", web: Bool = true, note: String = "") {
        self.task = task
        self.startURL = startURL
        self.app = app
        self.web = web
        self.note = note
    }
}

/// Splits a request into ordered, individually-runnable subtasks before the agent
/// loop starts, so an orchestrator can run one Computer Use episode per part — each
/// with its own step budget and a findings memo carried between parts — instead of
/// pushing a monolithic goal through a single loop. Serves both agents; the
/// environment decides the rules (web-only + feasibility triage in the sandbox,
/// any app or site on screen).
public struct AgentTaskPlanner: Sendable {
    public enum Environment: Sendable {
        /// The isolated background browser: websites only. Native-app parts are
        /// rewritten for web equivalents or flagged infeasible.
        case webSandbox
        /// The user's real screen: any app or website.
        case onScreen
    }

    private let client: any MessageCompleting
    private let model: String
    static let promptVersion = "agent-task-planner.prompt.v1"
    static let schemaVersion = "agent-task-planner.schema.v1"

    public init(client: any MessageCompleting = AnthropicClient(), model: String = AnthropicModel.sonnet) {
        self.client = client
        self.model = model
    }

    /// Plans `task`. Never fails: if the call or the parse falls over, the whole
    /// task becomes a single subtask — exactly the pre-planner behavior.
    /// `conversationContext` is the session's recent exchanges as plain text, so a
    /// follow-up job ("now reply to the first one") is split against what the user
    /// and the agent just did instead of in a vacuum.
    public func plan(
        for task: String, in environment: Environment, conversationContext: String = ""
    ) async -> [AgentSubtask] {
        let memo = conversationContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = memo.isEmpty
            ? "Job: \(task)"
            : "Recent conversation (resolve references like \"it\" or \"the first one\" from here; the job below is what to plan):\n\(memo)\n\nJob: \(task)"
        let raw = try? await client.complete(
            system: Self.systemPrompt(for: environment),
            user: user,
            model: model,
            maxTokens: 700,
            options: .deterministic(
                promptVersion: Self.promptVersion,
                schemaVersion: Self.schemaVersion,
                callsite: "AgentTaskPlanner.plan"
            )
        )
        if let raw, let parsed = Self.parse(raw) {
            return Array(parsed.prefix(Self.maxSubtasks))
        }
        // Degrading to one subtask is safe but should never be invisible — a key,
        // network, or schema problem would otherwise just look like "worse plans".
        Self.logger.error("planner fell back to a single subtask — \(raw == nil ? "request failed" : "reply did not parse", privacy: .public)")
        switch environment {
        case .webSandbox: return [AgentSubtask(task: task, startURL: Self.searchURL(for: task))]
        case .onScreen: return [AgentSubtask(task: task)]
        }
    }

    private static let logger = Logger(subsystem: "com.humain.cascade", category: "planner")

    static let maxSubtasks = 5

    static func systemPrompt(for environment: Environment) -> String {
        switch environment {
        case .webSandbox: webSandboxPrompt
        case .onScreen: onScreenPrompt
        }
    }

    static let webSandboxPrompt = """
    You split a job for a browser-automation agent into the smallest number of \
    sequential subtasks (1-\(maxSubtasks)). The agent works inside one isolated browser \
    view, one subtask at a time, and each finished subtask's result is passed to the \
    later ones.

    Rules:
    - Most jobs are ONE subtask. Split only when the job has clearly separate parts — \
    different websites, or a find-something-then-use-it sequence.
    - Each "task" says what to DO (imperative, self-contained), never what to research.
    - "startURL" is the best https:// page to start that part on — the real service's \
    own site, not a how-to article. Use "" only when the part continues on the page \
    where the previous part ends.
    - The agent can ONLY use websites. If a part names a native app that has a web \
    equivalent, rewrite the part for the web version (Mail/Outlook → the webmail \
    site, Calendar → the calendar website, Notes → keep.google.com, Messages/WhatsApp \
    → web.whatsapp.com, Docs/Word → docs.google.com, …). Set "web": false ONLY when \
    a part truly cannot happen in a browser (controls a local desktop app, local \
    files, system settings) and put a short reason in "note".

    Reply with ONLY this JSON, no prose:
    {"subtasks":[{"task":"...","startURL":"https://...","web":true,"note":""}]}
    """

    static let onScreenPrompt = """
    You split a job for an agent that operates the user's Mac — it sees the screen \
    and can click, type, and instantly open apps and websites — into the smallest \
    number of sequential subtasks (1-\(maxSubtasks)). The agent does one subtask at a \
    time, and each finished subtask's result is passed to the later ones.

    Rules:
    - Most jobs are ONE subtask. Split only when the job has clearly separate parts — \
    different apps or sites, or a find-something-then-use-it sequence.
    - Each "task" says what to DO (imperative, self-contained), carrying the concrete \
    details from the job that the part needs.
    - If a part happens in a specific macOS app, put the app's exact name in "app" \
    (e.g. "Notes", "Mail", "Calendar"). If it happens on a specific website, put the \
    full https:// page in "url" instead. Leave both "" when the part continues where \
    the previous part ends.

    Reply with ONLY this JSON, no prose:
    {"subtasks":[{"task":"...","app":"","url":""}]}
    """

    /// Parses the planner reply, tolerating prose or code fences around the JSON.
    static func parse(_ raw: String) -> [AgentSubtask]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let dto = try? JSONDecoder().decode(PlanDTO.self, from: data) else { return nil }
        let subtasks = dto.subtasks.compactMap { item -> AgentSubtask? in
            let task = (item.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            var url = (item.startURL ?? item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, !url.lowercased().hasPrefix("http") { url = "https://" + url }
            return AgentSubtask(
                task: task,
                startURL: url,
                app: (item.app ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                web: item.web ?? true,
                note: (item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return subtasks.isEmpty ? nil : subtasks
    }

    /// Deterministic fallback start page when no better URL is known.
    static func searchURL(for task: String) -> String {
        "https://www.google.com/search?q=" +
            (task.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }

    /// Builds an episode goal that carries forward what the earlier parts produced
    /// — the findings memo. Facts live here as plain text, immune to screenshot
    /// pruning in the vision loop.
    public static func goal(
        for sub: AgentSubtask, index: Int, total: Int, job: String,
        findings: [(task: String, result: String)], firmer: Bool
    ) -> String {
        var lines: [String] = []
        if total > 1 {
            lines.append("This is part \(index + 1) of \(total) of one job: “\(job)”.")
            if !findings.isEmpty {
                lines.append("Already finished — rely on these results, do not redo them:")
                for (offset, finding) in findings.enumerated() {
                    lines.append("\(offset + 1). \(finding.task) → \(finding.result)")
                }
            }
            lines.append("Do ONLY this part now: \(sub.task)")
        } else {
            lines.append(sub.task)
        }
        if firmer {
            lines.append("Important: actually CARRY OUT this part right now with tool calls — do not stop to narrate, describe the page, or ask a question.")
        }
        return lines.joined(separator: "\n")
    }

    /// The user-facing wrap-up: every part's finding, the parts that couldn't run
    /// in a browser, and whether the job ran long. A single-part job with nothing
    /// skipped reads exactly like the finding itself.
    public static func summary(
        findings: [(task: String, result: String)],
        skipped: [AgentSubtask],
        ranLongOn: String?,
        stalledOn: String? = nil
    ) -> String {
        if findings.count == 1, skipped.isEmpty, ranLongOn == nil, stalledOn == nil { return findings[0].result }
        var pieces: [String] = []
        if let ranLongOn {
            pieces.append("Ran out of steps on “\(ranLongOn)” — ask again and I'll continue.")
        }
        if let stalledOn {
            pieces.append("I got stuck on “\(stalledOn)” and paused there — tell me more, or ask again and I'll retry.")
        }
        if !findings.isEmpty {
            let lines = findings.map { "• \($0.task) — \($0.result)" }.joined(separator: "\n")
            pieces.append((ranLongOn == nil && stalledOn == nil && skipped.isEmpty ? "Done.\n" : "Finished:\n") + lines)
        }
        if !skipped.isEmpty {
            let parts = skipped
                .map { $0.note.isEmpty ? $0.task : "\($0.task) (\($0.note))" }
                .joined(separator: "; ")
            pieces.append("These need the Mac itself, not a browser — ask me on screen and I'll do them with you: \(parts).")
        }
        return pieces.isEmpty ? "Done." : pieces.joined(separator: "\n")
    }

    private struct PlanDTO: Decodable {
        let subtasks: [Item]
        struct Item: Decodable {
            let task: String?
            let startURL: String?
            let url: String?
            let app: String?
            let web: Bool?
            let note: String?
        }
    }
}
