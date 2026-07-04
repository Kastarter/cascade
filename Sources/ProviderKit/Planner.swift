import CascadeMemory
import Foundation
import PerceptionCore

/// The safe action vocabulary a planner may propose. There is deliberately **no**
/// shell/exec/file case — a model that tries to emit one decodes to `.unsupported`
/// and is never executed (architecture: no generated spec can use shell/exec).
public enum PlannedAction: Sendable, Equatable {
    case move(x: Double, y: Double)
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case type(String)
    case key(String, modifiers: [String])
    case scroll(deltaX: Double, deltaY: Double)
    case openURL(String)
    /// The goal is already satisfied — nothing to execute.
    case done(String)
    /// Outside the safe vocabulary; surfaced for review but never executed.
    case unsupported(String)

    public var isExecutable: Bool {
        switch self {
        case .done, .unsupported: false
        default: true
        }
    }

    /// Compact human label for the review dock.
    public var shortLabel: String {
        switch self {
        case .move(let x, let y): "move to \(Self.displayCoordinate(x)), \(Self.displayCoordinate(y))"
        case .click(let x, let y): "click \(Self.displayCoordinate(x)), \(Self.displayCoordinate(y))"
        case .doubleClick(let x, let y): "double-click \(Self.displayCoordinate(x)), \(Self.displayCoordinate(y))"
        case .rightClick(let x, let y): "right-click \(Self.displayCoordinate(x)), \(Self.displayCoordinate(y))"
        case .type(let text): "type “\(text.prefix(40))”"
        case .key(let key, let modifiers): (modifiers + [key]).joined(separator: "+")
        case .scroll(let dx, let dy): "scroll \(Self.displayCoordinate(dx)), \(Self.displayCoordinate(dy))"
        case .openURL(let url): "open \(url)"
        case .done: "done — nothing to run"
        case .unsupported(let kind): "unsupported (\(kind))"
        }
    }

    private static let displayCoordinateLimit = 1_000_000

    private static func displayCoordinate(_ value: Double) -> String {
        guard value.isFinite else { return "?" }

        let lower = Double(-displayCoordinateLimit)
        let upper = Double(displayCoordinateLimit)
        let clamped = min(max(value, lower), upper)
        return String(Int(clamped))
    }

    /// The screen point a click-type action targets, so the runtime can visibly
    /// move the cursor there before clicking.
    public var targetPoint: (x: Double, y: Double)? {
        switch self {
        case .click(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y): (x, y)
        default: nil
        }
    }
}

public struct ProposedStep: Sendable, Equatable {
    public let rationale: String
    public let action: PlannedAction
    public let confidence: Double

    public init(rationale: String, action: PlannedAction, confidence: Double) {
        self.rationale = rationale
        self.action = action
        self.confidence = confidence
    }
}

public enum PlannerError: Error, LocalizedError {
    case unparseable(String)

    public var errorDescription: String? {
        switch self {
        case .unparseable: "Could not read a single next step from Claude."
        }
    }
}

public protocol SingleStepPlanner: Sendable {
    func proposeNextStep(goal: String, contexts: [RecordedContext]) async throws -> ProposedStep
}

public struct ActionCritiqueRequest: Sendable, Equatable {
    public let goal: String
    public let actionSummary: String
    public let screenSummary: String
    public let triggerReasons: [String]

    public init(goal: String, actionSummary: String, screenSummary: String = "", triggerReasons: [String] = []) {
        self.goal = goal
        self.actionSummary = actionSummary
        self.screenSummary = screenSummary
        self.triggerReasons = triggerReasons
    }
}

public struct ActionCritique: Sendable, Equatable {
    public enum Verdict: String, Sendable, Codable {
        case approve
        case revise
        case refuse
        case askUser
    }

    public let verdict: Verdict
    public let failureKind: CascadeMemory.AgentFailureKind?
    public let reason: String
    public let saferInstruction: String?

    public init(
        verdict: Verdict,
        failureKind: CascadeMemory.AgentFailureKind? = nil,
        reason: String,
        saferInstruction: String? = nil
    ) {
        self.verdict = verdict
        self.failureKind = failureKind
        self.reason = reason
        self.saferInstruction = saferInstruction
    }
}

public protocol ActionCritic: Sendable {
    func critique(_ request: ActionCritiqueRequest) async -> ActionCritique
}

// ActionRisk moved to Sources/PerceptionCore/ActionRisk.swift (t06); shim keeps callsites compiling unchanged.
public typealias ActionRisk = PerceptionCore.ActionRisk

public struct PreActionVerification: Sendable, Equatable {
    public let risk: ActionRisk
    public let triggerReasons: [String]
    public let failureKind: CascadeMemory.AgentFailureKind?

    public init(
        risk: ActionRisk,
        triggerReasons: [String],
        failureKind: CascadeMemory.AgentFailureKind? = nil
    ) {
        self.risk = risk
        self.triggerReasons = Array(Set(triggerReasons)).sorted()
        self.failureKind = failureKind
    }

    public var shouldCritique: Bool { !triggerReasons.isEmpty }
}

public enum PreActionVerifier: Sendable {
    public static func verify(
        action: CUAction? = nil,
        harnessToolName: String? = nil,
        lowConfidenceGrounding: Bool = false,
        alternativeCount: Int = 0,
        groundingMissCount: Int = 0,
        noEffectCount: Int = 0,
        liveValueFailure: Bool = false
    ) -> PreActionVerification {
        var reasons: [String] = []
        var risk: ActionRisk = .low
        var failureKind: CascadeMemory.AgentFailureKind?

        if let harnessToolName {
            switch harnessToolName {
            case "run_command":
                reasons.append("power_harness_tool")
                reasons.append("shell")
                risk = .high
                failureKind = .unsafeAction
            case "run_applescript":
                reasons.append("power_harness_tool")
                reasons.append("applescript")
                risk = .high
                failureKind = .unsafeAction
            case "write_file":
                reasons.append("power_harness_tool")
                reasons.append("file_write")
                risk = .high
                failureKind = .unsafeAction
            default:
                break
            }
        }

        if let action {
            let text = actionRiskText(action)
            if containsDestructiveIntent(text) {
                reasons.append("destructive_or_submit_intent")
                risk = maxRisk(risk, .destructive)
                failureKind = .unsafeAction
            } else if containsPrivacySensitiveFormIntent(text) {
                reasons.append("privacy_sensitive_form")
                risk = maxRisk(risk, .high)
                failureKind = .unsafeAction
            }
            switch action {
            case .key(let combo) where ComputerUseAgent.isIrreversibleCombo(combo):
                reasons.append("irreversible_key")
                risk = maxRisk(risk, .destructive)
                failureKind = .unsafeAction
            case .key(let combo) where ComputerUseAgent.looksExternallySignificant(combo):
                reasons.append("external_side_effect_key")
                risk = maxRisk(risk, .high)
                failureKind = .unsafeAction
            case .type(let text) where ComputerUseAgent.looksExternallySignificant(text):
                reasons.append("external_side_effect_text")
                risk = maxRisk(risk, .high)
                failureKind = .unsafeAction
            case .openURL(let url):
                if isExternalURL(url) {
                    reasons.append("external_url")
                    risk = maxRisk(risk, .high)
                    failureKind = .unsafeAction
                }
            default:
                break
            }
        }

        if lowConfidenceGrounding {
            reasons.append("low_confidence_grounding")
            risk = maxRisk(risk, .high)
            failureKind = failureKind ?? .groundingMiss
        }
        if alternativeCount > 0 {
            reasons.append("ambiguous_grounding")
            risk = maxRisk(risk, .elevated)
            failureKind = failureKind ?? .groundingMiss
        }
        if groundingMissCount >= 2 {
            reasons.append("repeated_grounding_miss")
            risk = maxRisk(risk, .high)
            failureKind = failureKind ?? .groundingMiss
        }
        if noEffectCount >= 2 {
            reasons.append("repeated_no_effect")
            risk = maxRisk(risk, .high)
            failureKind = failureKind ?? .noEffect
        }
        if liveValueFailure {
            reasons.append("parameter_needs_live_value")
            risk = maxRisk(risk, .elevated)
            failureKind = failureKind ?? .parameterNeedsLiveValue
        }

        return PreActionVerification(risk: risk, triggerReasons: reasons, failureKind: failureKind)
    }

    private static func actionRiskText(_ action: CUAction) -> String {
        switch action {
        case .type(let text), .key(let text), .openApp(let text), .openURL(let text):
            return text
        case .highlight(_, _, _, _, let label):
            return label
        default:
            return ""
        }
    }

    private static func containsDestructiveIntent(_ value: String) -> Bool {
        value.range(
            of: #"(?i)\b(send|submit|delete|remove|trash|erase|pay|purchase|buy|allow|grant|approve|confirm|post|publish|wire|transfer)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsPrivacySensitiveFormIntent(_ value: String) -> Bool {
        value.range(
            of: #"(?i)\b(password|passcode|ssn|social\s+security|credit\s*card|card\s*number|bank|routing|secret|token|api\s*key)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isExternalURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return true }
        guard scheme == "http" || scheme == "https" else { return true }
        guard let host = url.host()?.lowercased() else { return true }
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local"))
    }

    private static func maxRisk(_ lhs: ActionRisk, _ rhs: ActionRisk) -> ActionRisk {
        order(lhs) >= order(rhs) ? lhs : rhs
    }

    private static func order(_ risk: ActionRisk) -> Int {
        switch risk {
        case .low: return 0
        case .elevated: return 1
        case .high: return 2
        case .destructive: return 3
        }
    }
}

public struct PromptActionCritic: ActionCritic {
    private let client: any MessageCompleting
    private let model: String

    public init(client: any MessageCompleting = AnthropicClient(), model: String = AnthropicModel.haiku) {
        self.client = client
        self.model = model
    }

    public func critique(_ request: ActionCritiqueRequest) async -> ActionCritique {
        let user = """
        Goal: \(request.goal)
        Proposed action: \(request.actionSummary)
        Trigger reasons: \(request.triggerReasons.joined(separator: ", "))
        Current state summary:
        \(request.screenSummary.isEmpty ? "not provided" : request.screenSummary)

        Predict whether this action is safe and likely to advance the goal. Reply ONLY JSON:
        {"verdict":"approve|revise|refuse|askUser","reason":"...","saferInstruction":"optional"}
        """
        let raw = try? await client.complete(
            system: "You are Cascade's pre-action GUI critic. Deterministic runtime gates are already enforced; approve unless the action is unsafe, likely wrong, or needs user clarification.",
            user: user,
            model: model,
            maxTokens: 180
        )
        return raw.flatMap(Self.parse) ?? ActionCritique(verdict: .approve, reason: "critic unavailable")
    }

    public static func parse(_ raw: String) -> ActionCritique? {
        guard let json = ClaudeSingleStepPlanner.extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            return nil
        }
        let verdictRaw = dto.verdict
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        let verdict: ActionCritique.Verdict
        switch verdictRaw {
        case "approve", "approved":
            verdict = .approve
        case "revise", "revision", "correct":
            verdict = .revise
        case "refuse", "refused", "deny", "denied":
            verdict = .refuse
        case "askuser", "ask", "clarify":
            verdict = .askUser
        default:
            return nil
        }
        return ActionCritique(
            verdict: verdict,
            failureKind: parseFailureKind(dto.failureKind),
            reason: dto.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            saferInstruction: normalizedOptional(dto.saferInstruction)
                ?? normalizedOptional(dto.suggestion)
        )
    }

    private struct DTO: Decodable {
        let verdict: String
        let reason: String
        let saferInstruction: String?
        let suggestion: String?
        let failureKind: String?
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseFailureKind(_ raw: String?) -> CascadeMemory.AgentFailureKind? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "unsafe_action", "unsafe_action_refused", "unsafeactionrefused":
            return .unsafeAction
        case "grounding_miss", "groundingmiss":
            return .groundingMiss
        case "no_effect", "noeffect":
            return .noEffect
        case "parameter_needs_live_value", "parameterneedslivevalue":
            return .parameterNeedsLiveValue
        default:
            return CascadeMemory.AgentFailureKind(rawValue: normalized)
        }
    }
}

/// Asks Claude for exactly ONE reviewed next step, grounded in recent local
/// context. The one-step truncation is a safety property (TipTour-style): the
/// employee approves each step before it runs; the planner never returns a
/// multi-step script.
public struct ClaudeSingleStepPlanner: SingleStepPlanner {
    private let client: any MessageCompleting
    private let cachedClient: CachedMessageCompleter?
    private let model: String
    static let promptVersion = "claude-single-step-planner.prompt.v1"
    static let schemaVersion = "claude-single-step-planner.schema.v1"

    public init(
        client: any MessageCompleting = AnthropicClient(),
        model: String = AnthropicModel.opus,
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

    public func proposeNextStep(goal: String, contexts: [RecordedContext]) async throws -> ProposedStep {
        let user = Self.userPrompt(goal: goal, contexts: contexts)
        let options = AnthropicCompletionOptions.deterministic(
            promptVersion: Self.promptVersion,
            schemaVersion: Self.schemaVersion,
            callsite: "ClaudeSingleStepPlanner.proposeNextStep"
        )
        let raw: String
        if let cachedClient {
            raw = try await cachedClient.complete(
                system: Self.systemPrompt,
                user: user,
                model: model,
                maxTokens: 700,
                options: options,
                validating: { _ = try Self.parse($0) }
            )
        } else {
            raw = try await client.complete(
                system: Self.systemPrompt,
                user: user,
                model: model,
                maxTokens: 700,
                options: options
            )
        }
        return try Self.parse(raw)
    }

    static let systemPrompt = """
    You are Cascade's supervised computer-use planner. Propose EXACTLY ONE next step \
    for the employee to review and approve before it runs. Never plan more than one step.

    Respond with ONLY a JSON object, no prose, in this shape:
    {"rationale": "<one sentence>", "confidence": <0.0-1.0>,
     "action": {"kind": "<kind>", ...fields}}

    Allowed kinds and their fields (coordinates are screen pixels):
      move        {"x": n, "y": n}
      click       {"x": n, "y": n}
      double_click{"x": n, "y": n}
      right_click {"x": n, "y": n}
      type        {"text": "..."}
      key         {"key": "return", "modifiers": ["command"]}
      scroll      {"delta_x": n, "delta_y": n}
      open_url    {"url": "https://..."}
      done        {"summary": "..."}

    Never use shell commands, file edits, or any capability not listed. If you are \
    unsure or the goal looks complete, return kind "done". Only http/https URLs.
    """

    static func userPrompt(goal: String, contexts: [RecordedContext]) -> String {
        let recent = contexts.sorted { $0.capturedAt > $1.capturedAt }.prefix(8)
        let lines = recent.map { context -> String in
            let title = context.windowTitle.map { " — \($0)" } ?? ""
            let ocr = context.ocrText.map { " | on-screen: \($0.prefix(240))" } ?? ""
            return "• \(context.appName)\(title)\(ocr)"
        }
        let contextBlock = lines.isEmpty ? "(no recent local context)" : lines.joined(separator: "\n")
        return """
        Goal: \(goal)

        Recent local context (most recent first):
        \(contextBlock)
        """
    }

    static func parse(_ raw: String) throws -> ProposedStep {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8) else {
            throw PlannerError.unparseable(raw)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let dto = try? decoder.decode(PlanDTO.self, from: data), let action = dto.action else {
            throw PlannerError.unparseable(raw)
        }
        return ProposedStep(
            rationale: dto.rationale ?? "Proposed next step.",
            action: action.toPlannedAction(),
            confidence: min(max(dto.confidence ?? 0.5, 0), 1)
        )
    }

    /// Pulls the first `{ ... }` object out of a response that may be wrapped in
    /// prose or ```json fences.
    static func extractJSONObject(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(raw[start...end])
    }

    private struct PlanDTO: Decodable {
        let rationale: String?
        let confidence: Double?
        let action: ActionDTO?

        struct ActionDTO: Decodable {
            let kind: String
            let x: Double?
            let y: Double?
            let text: String?
            let key: String?
            let modifiers: [String]?
            let deltaX: Double?
            let deltaY: Double?
            let url: String?
            let summary: String?

            func toPlannedAction() -> PlannedAction {
                switch kind {
                case "move":
                    guard let x, let y else { return .unsupported(kind) }
                    return .move(x: x, y: y)
                case "click":
                    guard let x, let y else { return .unsupported(kind) }
                    return .click(x: x, y: y)
                case "doubleClick", "double_click":
                    guard let x, let y else { return .unsupported(kind) }
                    return .doubleClick(x: x, y: y)
                case "rightClick", "right_click":
                    guard let x, let y else { return .unsupported(kind) }
                    return .rightClick(x: x, y: y)
                case "type":
                    guard let text else { return .unsupported(kind) }
                    return .type(text)
                case "key":
                    guard let key else { return .unsupported(kind) }
                    return .key(key, modifiers: modifiers ?? [])
                case "scroll":
                    return .scroll(deltaX: deltaX ?? 0, deltaY: deltaY ?? 0)
                case "openUrl", "open_url":
                    guard let url, url.hasPrefix("http://") || url.hasPrefix("https://") else { return .unsupported(kind) }
                    return .openURL(url)
                case "done":
                    return .done(summary ?? "Goal looks complete.")
                default:
                    return .unsupported(kind)
                }
            }
        }
    }
}
