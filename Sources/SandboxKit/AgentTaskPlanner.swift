import Foundation
import OSLog
import AgentOrchestrator
import ProviderKit

/// Observable state changes the executor/verifier can check after a subtask.
public enum ExpectedEffect: Sendable, Equatable {
    case frontmostApp(String)
    case windowTitleContains(String)
    case visibleText(String)
    case urlContains(String)
    case artifactExists(String)
    case noUnexpectedModal

    public var auditLabel: String {
        switch self {
        case .frontmostApp(let value): "frontmost_app:\(value)"
        case .windowTitleContains(let value): "window_title:\(value)"
        case .visibleText(let value): "visible_text:\(value)"
        case .urlContains(let value): "url_contains:\(value)"
        case .artifactExists(let value): "artifact_exists:\(value)"
        case .noUnexpectedModal: "no_unexpected_modal"
        }
    }
}

public enum AgentSubtaskRisk: String, Sendable, Equatable, Codable, CaseIterable {
    case low
    case medium
    case high

    static func normalized(_ raw: String?) -> AgentSubtaskRisk {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "dangerous", "destructive", "external_side_effect", "external-side-effect":
            .high
        case "medium", "moderate", "risky", "uncertain":
            .medium
        default:
            .low
        }
    }
}

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
    /// Deterministic or verifier-checkable state changes expected after this part.
    public let expectedEffects: [ExpectedEffect]
    /// Planner-estimated risk for choosing verifier/critic/replan depth.
    public let risk: AgentSubtaskRisk

    public init(
        task: String,
        startURL: String = "",
        app: String = "",
        web: Bool = true,
        note: String = "",
        expectedEffects: [ExpectedEffect] = [],
        risk: AgentSubtaskRisk = .low
    ) {
        self.task = task
        self.startURL = startURL
        self.app = app
        self.web = web
        self.note = note
        self.expectedEffects = expectedEffects
        self.risk = risk
    }
}

public struct AgentTaskPlan: Sendable, Equatable {
    public let id: String
    public let originalTask: String
    public let subtasks: [AgentSubtask]

    public init(id: String = UUID().uuidString, originalTask: String, subtasks: [AgentSubtask]) {
        self.id = id
        self.originalTask = originalTask
        self.subtasks = Array(subtasks.prefix(AgentTaskPlanner.maxSubtasks))
    }
}

public struct AgentTaskFinding: Sendable, Equatable {
    public let task: String
    public let result: String

    public init(task: String, result: String) {
        self.task = task
        self.result = result
    }
}

public struct AgentRecoveryMemo: Sendable, Equatable {
    public let failedSubtask: AgentSubtask
    public let failureKind: AgentFailureKind
    public let attemptedRecovery: RecoveryAction?
    public let firstBadActionHash: String?
    public let targetHash: String?
    public let stateSummary: String
    public let evidenceSummary: String
    public let completedFindings: [AgentTaskFinding]

    public init(
        failedSubtask: AgentSubtask,
        failureKind: AgentFailureKind,
        attemptedRecovery: RecoveryAction? = nil,
        firstBadActionHash: String? = nil,
        targetHash: String? = nil,
        stateSummary: String,
        evidenceSummary: String = "",
        completedFindings: [AgentTaskFinding] = []
    ) {
        self.failedSubtask = failedSubtask
        self.failureKind = failureKind
        self.attemptedRecovery = attemptedRecovery
        self.firstBadActionHash = firstBadActionHash
        self.targetHash = targetHash
        self.stateSummary = stateSummary
        self.evidenceSummary = evidenceSummary
        self.completedFindings = completedFindings
    }
}

public enum AgentReplanDecision: Sendable, Equatable {
    case replaceCurrent(AgentSubtask)
    case pause(String)
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
    private let cachedClient: CachedMessageCompleter?
    private let model: String
    static let promptVersion = "agent-task-planner.prompt.v2"
    static let replanPromptVersion = "agent-task-replanner.prompt.v1"
    static let schemaVersion = "agent-task-planner.schema.v2"

    public init(
        client: any MessageCompleting = AnthropicClient(),
        model: String = AnthropicModel.sonnet,
        cache: ModelCallCache? = nil,
        retryPolicy: RetryBackoffPolicy? = nil
    ) {
        let effectiveClient: any MessageCompleting = retryPolicy.map {
            RetryingMessageCompleter(client: client, retryPolicy: $0)
        } ?? client
        self.client = effectiveClient
        self.cachedClient = cache.map { CachedMessageCompleter(client: effectiveClient, cache: $0) }
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
        await taskPlan(for: task, in: environment, conversationContext: conversationContext).subtasks
    }

    public func taskPlan(
        for task: String, in environment: Environment, conversationContext: String = ""
    ) async -> AgentTaskPlan {
        let memo = conversationContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = memo.isEmpty
            ? "Job: \(task)"
            : "Recent conversation (resolve references like \"it\" or \"the first one\" from here; the job below is what to plan):\n\(memo)\n\nJob: \(task)"
        let options = AnthropicCompletionOptions.deterministic(
            promptVersion: Self.promptVersion,
            schemaVersion: Self.schemaVersion,
            callsite: "AgentTaskPlanner.plan"
        )
        let raw = try? await complete(
            system: Self.systemPrompt(for: environment),
            user: user,
            maxTokens: 700,
            options: options,
            validating: {
                guard Self.parse($0) != nil else {
                    throw CachedMessageCompleterError.invalidResponse
                }
            }
        )
        if let raw, let parsed = Self.parse(raw) {
            return AgentTaskPlan(originalTask: task, subtasks: parsed)
        }
        // Degrading to one subtask is safe but should never be invisible — a key,
        // network, or schema problem would otherwise just look like "worse plans".
        Self.logger.error("planner fell back to a single subtask — \(raw == nil ? "request failed" : "reply did not parse", privacy: .public)")
        switch environment {
        case .webSandbox: return AgentTaskPlan(originalTask: task, subtasks: [AgentSubtask(task: task, startURL: Self.searchURL(for: task))])
        case .onScreen: return AgentTaskPlan(originalTask: task, subtasks: [AgentSubtask(task: task)])
        }
    }

    public func replan(
        originalTask: String,
        memo: AgentRecoveryMemo,
        environment: Environment,
        conversationContext: String = ""
    ) async -> AgentReplanDecision {
        let recovery = memo.attemptedRecovery ?? AgentRecoveryPolicy.plan(for: memo.failureKind).retryRungs.first
        guard let recovery, recovery.canRecover else {
            return .pause(Self.pauseReason(for: memo.failureKind, action: AgentRecoveryPolicy.plan(for: memo.failureKind).terminal))
        }

        let user = Self.replanPrompt(originalTask: originalTask, memo: memo, recovery: recovery, conversationContext: conversationContext)
        let options = AnthropicCompletionOptions.deterministic(
            promptVersion: Self.replanPromptVersion,
            schemaVersion: Self.schemaVersion,
            callsite: "AgentTaskPlanner.replan"
        )
        let raw = try? await complete(
            system: Self.replanSystemPrompt(for: environment),
            user: user,
            maxTokens: 500,
            options: options,
            validating: {
                guard Self.parse($0)?.first != nil else {
                    throw CachedMessageCompleterError.invalidResponse
                }
            }
        )
        if let raw, let subtask = Self.parse(raw)?.first {
            return .replaceCurrent(subtask)
        }
        return .replaceCurrent(Self.recoveryFallbackSubtask(from: memo, recovery: recovery))
    }

    private static let logger = Logger(subsystem: "com.humain.cascade", category: "planner")

    static let maxSubtasks = 5

    private func complete(
        system: String,
        user: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions,
        validating validate: @Sendable @escaping (String) throws -> Void
    ) async throws -> String {
        if let cachedClient {
            return try await cachedClient.complete(
                system: system,
                user: user,
                model: model,
                maxTokens: maxTokens,
                options: options,
                validating: validate
            )
        }
        return try await client.complete(system: system, user: user, model: model, maxTokens: maxTokens, options: options)
    }

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

    - Include "expectedEffects" only for observable checks: frontmost_app, \
    window_title_contains, visible_text, url_contains, artifact_exists, no_unexpected_modal.
    - Set "risk" to low, medium, or high. High means irreversible, external side effect, \
    payment/send/delete, or file/system mutation.

    Reply with ONLY this JSON, no prose:
    {"subtasks":[{"task":"...","startURL":"https://...","web":true,"note":"","expectedEffects":[{"kind":"url_contains","value":"example.com"}],"risk":"low"}]}
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

    - Include "expectedEffects" only for observable checks: frontmost_app, \
    window_title_contains, visible_text, url_contains, artifact_exists, no_unexpected_modal.
    - Set "risk" to low, medium, or high. High means irreversible, external side effect, \
    payment/send/delete, or file/system mutation.

    Reply with ONLY this JSON, no prose:
    {"subtasks":[{"task":"...","app":"","url":"","expectedEffects":[{"kind":"frontmost_app","value":"Notes"}],"risk":"low"}]}
    """

    static func replanSystemPrompt(for environment: Environment) -> String {
        """
        You repair one failed subtask for Cascade's bounded GUI agent. Return at most ONE \
        replacement subtask that avoids repeating the failed target/action and follows the \
        requested recovery rung. If recovery is not possible, return one subtask that gathers \
        the minimum evidence needed to pause honestly.

        \(systemPrompt(for: environment))
        """
    }

    static func replanPrompt(
        originalTask: String,
        memo: AgentRecoveryMemo,
        recovery: RecoveryAction,
        conversationContext: String
    ) -> String {
        let findings = memo.completedFindings.enumerated().map { index, finding in
            "\(index + 1). \(finding.task) -> \(finding.result)"
        }.joined(separator: "\n")
        return """
        Original job: \(originalTask)
        Failed subtask: \(memo.failedSubtask.task)
        Failure kind: \(memo.failureKind.rawValue)
        Recovery rung to try: \(recovery.rawValue)
        First bad action hash: \(memo.firstBadActionHash ?? "none")
        Target hash: \(memo.targetHash ?? "none")
        Current state: \(memo.stateSummary)
        Evidence: \(memo.evidenceSummary.isEmpty ? "none" : memo.evidenceSummary)
        Completed findings:
        \(findings.isEmpty ? "none" : findings)
        Recent conversation:
        \(conversationContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "none" : conversationContext)
        """
    }

    /// Parses the planner reply, tolerating prose or code fences around the JSON.
    static func parse(_ raw: String) -> [AgentSubtask]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let dto = try? JSONDecoder().decode(PlanDTO.self, from: data) else { return nil }
        let subtasks = dto.subtasks.prefix(Self.maxSubtasks).compactMap { item -> AgentSubtask? in
            let task = (item.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            var url = (item.startURL ?? item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, !url.lowercased().hasPrefix("http") { url = "https://" + url }
            return AgentSubtask(
                task: task,
                startURL: url,
                app: (item.app ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                web: item.web ?? true,
                note: (item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                expectedEffects: (item.expectedEffects ?? []).compactMap(\.effect),
                risk: AgentSubtaskRisk.normalized(item.risk)
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
            let expectedEffects: [ExpectedEffectDTO]?
            let risk: String?
        }
    }

    private struct ExpectedEffectDTO: Decodable {
        let effect: ExpectedEffect?

        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                effect = Self.parse(kind: string, value: nil)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let explicitKind = try container.decodeIfPresent(String.self, forKey: .kind)
            let typeKind = try container.decodeIfPresent(String.self, forKey: .type)
            let nameKind = try container.decodeIfPresent(String.self, forKey: .name)
            let kind = explicitKind ?? typeKind ?? nameKind
            let valueField = try container.decodeIfPresent(String.self, forKey: .value)
            let textField = try container.decodeIfPresent(String.self, forKey: .text)
            let appField = try container.decodeIfPresent(String.self, forKey: .app)
            let titleField = try container.decodeIfPresent(String.self, forKey: .title)
            let urlField = try container.decodeIfPresent(String.self, forKey: .url)
            let pathField = try container.decodeIfPresent(String.self, forKey: .path)
            let value = valueField ?? textField ?? appField ?? titleField ?? urlField ?? pathField
            effect = Self.parse(kind: kind, value: value)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, type, name, value, text, app, title, url, path
        }

        private static func parse(kind rawKind: String?, value rawValue: String?) -> ExpectedEffect? {
            let kind = (rawKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case "frontmost_app", "frontmostapp":
                guard let value, !value.isEmpty else { return nil }
                return .frontmostApp(value)
            case "window_title_contains", "window_title", "windowtitlecontains":
                guard let value, !value.isEmpty else { return nil }
                return .windowTitleContains(value)
            case "visible_text", "visibletext", "ocr_visible_text":
                guard let value, !value.isEmpty else { return nil }
                return .visibleText(value)
            case "url_contains", "urlcontains":
                guard let value, !value.isEmpty else { return nil }
                return .urlContains(value)
            case "artifact_exists", "artifactexists", "file_exists":
                guard let value, !value.isEmpty else { return nil }
                return .artifactExists(value)
            case "no_unexpected_modal", "nounexpectedmodal", "no_modal":
                return .noUnexpectedModal
            default:
                return nil
            }
        }
    }

    private static func pauseReason(for failureKind: AgentFailureKind, action: RecoveryAction) -> String {
        "Recovery for \(failureKind.rawValue) reached \(action.rawValue); pause with the current evidence."
    }

    private static func recoveryFallbackSubtask(from memo: AgentRecoveryMemo, recovery: RecoveryAction) -> AgentSubtask {
        let task = "Recover from \(snakeCase(memo.failureKind.rawValue)) while doing: \(memo.failedSubtask.task). Try \(recovery.rawValue), do not repeat the failed target/action, and pause if the screen still contradicts completion."
        return AgentSubtask(
            task: task,
            startURL: memo.failedSubtask.startURL,
            app: memo.failedSubtask.app,
            web: memo.failedSubtask.web,
            note: memo.failedSubtask.note,
            expectedEffects: memo.failedSubtask.expectedEffects,
            risk: maxRisk(memo.failedSubtask.risk, .medium)
        )
    }

    private static func maxRisk(_ lhs: AgentSubtaskRisk, _ rhs: AgentSubtaskRisk) -> AgentSubtaskRisk {
        func rank(_ risk: AgentSubtaskRisk) -> Int {
            switch risk {
            case .low: 0
            case .medium: 1
            case .high: 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func snakeCase(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if !output.isEmpty { output.append("_") }
                output.append(String(scalar).lowercased())
            } else {
                output.append(String(scalar))
            }
        }
        return output
    }
}
