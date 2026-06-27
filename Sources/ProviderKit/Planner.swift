import CascadeMemory
import Foundation

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
