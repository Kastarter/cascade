import CascadeMemory
import ComputerUseKit
import Foundation
import ProviderKit
import WasteDetection

public struct AgentObservation: Sendable {
    public let contexts: [RecordedContext]

    public init(contexts: [RecordedContext]) {
        self.contexts = contexts
    }
}

public enum AgentAction: Sendable, Equatable {
    case computerUse(ComputerUseAction)
    case writeLocalArtifact(title: String, body: String)
}

public extension AgentAction {
    /// Maps a reviewed planner step to an executable agent action. Returns nil for
    /// non-executable steps (`done`, `unsupported`), which the caller audits but
    /// does not run.
    init?(planned: PlannedAction) {
        switch planned {
        case .move(let x, let y): self = .computerUse(.move(x: x, y: y))
        case .click(let x, let y): self = .computerUse(.click(x: x, y: y))
        case .doubleClick(let x, let y): self = .computerUse(.doubleClick(x: x, y: y))
        case .rightClick(let x, let y): self = .computerUse(.rightClick(x: x, y: y))
        case .type(let text): self = .computerUse(.typeText(text))
        case .key(let key, let modifiers): self = .computerUse(.key(key, modifiers: modifiers))
        case .scroll(let deltaX, let deltaY): self = .computerUse(.scroll(deltaX: deltaX, deltaY: deltaY))
        case .openURL(let url): self = .computerUse(.openURL(url))
        case .done, .unsupported: return nil
        }
    }

    /// Maps one step of a recorded agent recipe to an executable action.
    /// `activateApp` returns nil — the run loop handles app activation itself.
    init?(recipeStep step: RecipeStep) {
        switch step.kind {
        case .activateApp:
            return nil
        case .click:
            guard let x = step.x, let y = step.y else { return nil }
            self = .computerUse(.click(x: x, y: y))
        case .doubleClick:
            guard let x = step.x, let y = step.y else { return nil }
            self = .computerUse(.doubleClick(x: x, y: y))
        case .rightClick:
            guard let x = step.x, let y = step.y else { return nil }
            self = .computerUse(.rightClick(x: x, y: y))
        case .type:
            guard let text = step.text else { return nil }
            self = .computerUse(.typeText(text))
        case .key:
            guard let key = step.key else { return nil }
            self = .computerUse(.key(key, modifiers: step.modifiers))
        case .scroll:
            let deltaY = Double(step.modifiers.first ?? "0") ?? 0
            let deltaX = Double(step.modifiers.dropFirst().first ?? "0") ?? 0
            self = .computerUse(.scroll(deltaX: deltaX, deltaY: deltaY))
        }
    }
}

public struct AgentVerification: Sendable, Equatable {
    public let passed: Bool
    public let detail: String

    public init(passed: Bool, detail: String) {
        self.passed = passed
        self.detail = detail
    }
}

public protocol AgentDriver: Sendable {
    func observe() async throws -> AgentObservation
    func act(_ action: AgentAction) async throws
    func verify(goal: String) async throws -> AgentVerification
    func stop() async
    func status() async -> String
}

public actor LocalMacDriver: AgentDriver {
    private let store: CascadeStore
    private let actuator: ComputerUseActuator
    /// Shared STOP signal — immutable and Sendable, so the UI can flip it
    /// synchronously without hopping onto the actor.
    public nonisolated let runState: AgentRunState

    public init(store: CascadeStore, runState: AgentRunState = AgentRunState(), actuator: ComputerUseActuator? = nil) {
        self.store = store
        self.runState = runState
        self.actuator = actuator ?? NativeComputerUseActuator(runState: runState)
    }

    public func observe() async throws -> AgentObservation {
        AgentObservation(contexts: try await store.recentContexts(limit: 40))
    }

    public func act(_ action: AgentAction) async throws {
        switch action {
        case .computerUse(let computerUseAction):
            let result = await actuator.execute(computerUseAction)
            if result.status != .ok {
                throw ComputerUseError.unsupported(result.failureKind?.rawValue ?? result.status.rawValue)
            }
            _ = try await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "computer.act",
                detail: result.auditDetail
            ))
        case .writeLocalArtifact(let title, let body):
            let url = try Self.writeArtifact(title: title, body: body)
            _ = try await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "artifact.write",
                detail: Self.artifactAuditDetail(title: title, body: body, url: url)
            ))
        }
    }

    private nonisolated static func computerActionAuditDetail(_ action: ComputerUseAction) -> String {
        switch action {
        case .move(let x, let y):
            return "kind=move x=\(coordinate(x)) y=\(coordinate(y))"
        case .click(let x, let y):
            return "kind=click x=\(coordinate(x)) y=\(coordinate(y))"
        case .doubleClick(let x, let y):
            return "kind=doubleClick x=\(coordinate(x)) y=\(coordinate(y))"
        case .tripleClick(let x, let y):
            return "kind=tripleClick x=\(coordinate(x)) y=\(coordinate(y))"
        case .rightClick(let x, let y):
            return "kind=rightClick x=\(coordinate(x)) y=\(coordinate(y))"
        case .drag(let fromX, let fromY, let toX, let toY):
            return "kind=drag fromX=\(coordinate(fromX)) fromY=\(coordinate(fromY)) toX=\(coordinate(toX)) toY=\(coordinate(toY))"
        case .key(let key, let modifiers):
            let modifierTokens = modifiers.map(AuditIdentity.safeToken).joined(separator: "+")
            return "kind=key key=\(AuditIdentity.safeToken(key)) modifiers=\(modifierTokens)"
        case .typeText(let text):
            return "kind=typeText \(AuditIdentity.descriptor("text", text))"
        case .scroll(let deltaX, let deltaY):
            return "kind=scroll deltaX=\(coordinate(deltaX)) deltaY=\(coordinate(deltaY))"
        case .openURL(let url):
            return "kind=openURL \(AuditIdentity.descriptor("url", url))"
        }
    }

    private nonisolated static func artifactAuditDetail(title: String, body: String, url: URL) -> String {
        [
            AuditIdentity.descriptor("title", title),
            AuditIdentity.descriptor("path", url.path),
            "bodyChars=\(body.count)",
            "ext=\(AuditIdentity.safeToken(url.pathExtension.isEmpty ? "none" : url.pathExtension))",
        ].joined(separator: " ")
    }

    private nonisolated static func coordinate(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "invalid"
    }

    /// Writes an agent-produced artifact as Markdown under
    /// `Application Support/Cascade/Artifacts/`, slugged + timestamped so runs
    /// never overwrite each other.
    private static func writeArtifact(title: String, body: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Cascade/Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char != "-" || result.last != "-" { result.append(char) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Timestamp + short random suffix — same-titled artifacts in the same
        // second must not overwrite each other.
        let stamp = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.prefix(8)
        let url = dir.appendingPathComponent("\(slug.isEmpty ? "artifact" : String(slug.prefix(60)))-\(stamp)-\(nonce).md")
        try "# \(title)\n\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Did acting visibly land? Passes only when the record shows FRESH context —
    /// something was observed since the run started — not merely that a record
    /// exists at all.
    public func verify(goal: String) async throws -> AgentVerification {
        let contexts = try await store.recentContexts(limit: 12)
        guard let latest = contexts.first else {
            return AgentVerification(passed: false, detail: "No context recorded — nothing to verify against.")
        }
        let age = Date().timeIntervalSince(latest.capturedAt)
        let fresh = age < 60
        let appNames = Set(contexts.map(\.appName))
        return AgentVerification(
            passed: fresh,
            detail: fresh
                ? "Fresh context \(Int(age))s ago in \(latest.appName) (\(contexts.count) samples, \(appNames.count) apps) for goal: \(goal)"
                : "Stale record — latest context is \(Int(age))s old; the screen was not observed after acting on: \(goal)"
        )
    }

    public func stop() async {
        runState.requestStop()
        _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "agent.stop", detail: "User pressed STOP"))
    }

    public func status() async -> String {
        let health = await actuator.health()
        return health.message
    }
}

public actor CascadeOrchestrator {
    private let store: CascadeStore
    private let localAnswerer: ContextQuestionAnswering
    private let claudeAnswerer: ContextQuestionAnswering
    private let recordAnswerer: RecordAnswering
    private let planner: SingleStepPlanner
    private let wasteDetector = WasteDetector()
    private let curator: WorkflowCurator
    /// Curation is a model call; cache it against the set of candidate signatures
    /// (and whether a key is connected) so frequent refreshes don't re-curate the
    /// same unchanged list.
    private var curationCache: (key: Set<String>, keyed: Bool, agents: [CuratedAgent])?
    private let keyStore: AnthropicKeyStore

    public init(
        store: CascadeStore,
        localAnswerer: ContextQuestionAnswering = LocalGroundedAnswerer(),
        claudeAnswerer: ContextQuestionAnswering = ClaudeGroundedAnswerer(),
        recordAnswerer: RecordAnswering? = nil,
        planner: SingleStepPlanner? = nil,
        curator: WorkflowCurator? = nil,
        modelCallCache: ModelCallCache? = nil,
        keyStore: AnthropicKeyStore = AnthropicKeyStore()
    ) {
        self.store = store
        self.localAnswerer = localAnswerer
        self.claudeAnswerer = claudeAnswerer
        self.recordAnswerer = recordAnswerer ?? RecordSearchAnswerer(store: store, keyStore: keyStore)
        self.planner = planner ?? ClaudeSingleStepPlanner(cache: modelCallCache)
        self.curator = curator ?? WorkflowCurator(client: AnthropicClient(keyStore: keyStore), cache: modelCallCache)
        self.keyStore = keyStore
    }

    /// Grounded Q&A. Uses Claude when a key is connected (privacy-filtered context
    /// only) and falls back to the local heuristic answerer otherwise, or on any
    /// provider error.
    public func ask(_ question: String) async throws -> String {
        try await askRecord(question).text
    }

    /// Agentic Q&A: the model hunts through the record (FTS, timeframes,
    /// per-moment inspection) and returns the answer WITH the moments it used.
    /// Falls back to single-shot grounding, then to the local heuristic, so a
    /// missing key or a flaky network never breaks asking.
    public func askRecord(_ question: String, conversation: [(user: String, assistant: String)] = []) async throws -> RecordAnswer {
        if keyStore.hasKey(),
           let answer = try? await recordAnswerer.answer(question: question, conversation: conversation) {
            return answer
        }
        let grounding = try await chatGrounding(for: question)
        if keyStore.hasKey(), let answer = try? await claudeAnswerer.answer(question: question, grounding: grounding) {
            return RecordAnswer(text: answer, citedMomentIDs: [])
        }
        return RecordAnswer(
            text: try await localAnswerer.answer(question: question, grounding: grounding),
            citedMomentIDs: []
        )
    }

    /// Resolves cited moment ids to renderable chips (privacy-filtered).
    public func citedMoments(_ ids: [Int64]) async -> [RecordedContext] {
        var moments: [RecordedContext] = []
        for id in ids {
            if let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) {
                moments.append(moment)
            }
        }
        return moments
    }

    /// Chat grounding, layered so any question about the user's day is answerable:
    /// the whole last-24h timeline (shape of the day), hourly on-screen content
    /// samples plus question-matched moments from the entire record (specifics
    /// seen at any time), and the freshest fully-decoded moments (what just
    /// happened). Privacy-filtered before anything reaches a provider.
    private func chatGrounding(for question: String) async throws -> ChatGrounding {
        let since = Date(timeIntervalSinceNow: -24 * 60 * 60)
        let recent = try await store.recentContexts(limit: 24)
        let timeline = (try? await store.contextTimeline(since: since)) ?? []
        let samples = (try? await store.contentSamples(since: since)) ?? []
        let relevant = (try? await store.relevantContexts(to: question)) ?? []
        return ChatGrounding(
            timeline: timeline.filter { !PrivacyRules.isSensitive($0) },
            samples: samples.filter { !PrivacyRules.isSensitive($0) },
            relevant: relevant.filter { !PrivacyRules.isSensitive($0) },
            recent: recent.filter { !PrivacyRules.isSensitive($0) }
        )
    }

    /// Proposes exactly one reviewed next step toward `goal`, grounded in recent
    /// privacy-filtered context. Requires a connected Claude key.
    public func proposeStep(goal: String) async throws -> ProposedStep {
        let contexts = try await store.recentContexts(limit: 24).filter { !PrivacyRules.isSensitive($0) }
        return try await planner.proposeNextStep(goal: goal, contexts: contexts)
    }

    /// What Cascade detected the user repeating, from recorded input anchored to
    /// the Rewind. Each is a candidate to turn into an agent built from real actions.
    public func detectedWaste(
        maxResults: Int = 5,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        useEpisodeMining: Bool = true
    ) async throws -> [DetectedWaste] {
        let contexts = try await store.recentContexts(limit: 400)
        let events = try await store.recentInputEvents(limit: 3000)
        return wasteDetector.detect(
            contexts: contexts,
            inputEvents: events,
            maxResults: maxResults,
            webAppIdentity: webAppIdentity,
            useEpisodeMining: useEpisodeMining
        )
    }

    /// Turns an arbitrary recorded time range into ONE named, grounded
    /// `CuratedAgent` — the single backend every *intentional* agent-creation front
    /// door shares (Teach-once today; a Reel selection next). It pulls the bracketed
    /// input events and the contexts that anchor their clicks, builds one
    /// `DetectedWaste` (or `nil` when the range holds nothing automatable — only
    /// scrolling/typing), and curates it with the user's spoken intent. Approving
    /// the result runs the exact same `createAgent(from:)` the automatic pipeline
    /// uses: one creation path, many doors.
    public func curateRange(
        from start: Date,
        to end: Date,
        statedIntent: String? = nil,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil
    ) async throws -> CuratedAgent? {
        let events = try await store.inputEvents(between: start, and: end)
        let contexts = try await store.contexts(between: start, and: end)
        guard let waste = wasteDetector.waste(fromInstance: events, contexts: contexts, surface: webAppIdentity) else {
            return nil
        }
        return await curator.curateOne(waste, statedIntent: statedIntent, onScreen: await onScreenText(for: waste))
    }

    /// The detector's candidates, judged and named by the curator into the few
    /// genuinely worth automating (R1). Cached against the candidate set so refresh
    /// churn doesn't re-spend a model call; with no key, degrades to the raw list.
    public func curate(_ candidates: [DetectedWaste]) async -> [CuratedAgent] {
        // `keyed` stays in the cache key so connecting a key mid-session invalidates
        // a fallback result — but the curator itself decides what to do without one
        // (it degrades internally), so an injected curator is always exercised.
        let keyed = keyStore.hasKey()
        let key = Set(candidates.map(\.signature))
        if let cache = curationCache, cache.key == key, cache.keyed == keyed {
            // Cache HIT, but refresh each proposal's `source` from the CURRENT
            // candidate of the same signature: a signature is the token SHAPE (counts
            // excluded), so it's stable while the user keeps repeating the workflow —
            // without this re-map the card's occurrences / minutes / last-seen (and the
            // numbers persisted on approve) would freeze at first curation.
            let bySignature = Dictionary(candidates.map { ($0.signature, $0) }, uniquingKeysWith: { first, _ in first })
            return cache.agents.map { agent in
                guard let fresh = bySignature[agent.signature] else { return agent }
                return CuratedAgent(id: agent.id, source: fresh, name: agent.name, why: agent.why, goal: agent.goal, value: agent.value)
            }
        }
        // On a miss only (so cache hits never touch the DB) AND only when a key is
        // connected: resolve the on-screen content of each candidate's most recent
        // occurrence so the curator can write a content-aware goal instead of a
        // shape-only one. With no key the curator degrades to mechanical naming and
        // ignores `onScreen`, so resolving it would be pure DB work on every refresh.
        var onScreen: [String: String] = [:]
        if keyed {
            for candidate in candidates {
                if let text = await onScreenText(for: candidate) { onScreen[candidate.signature] = text }
            }
        }
        let curated = await curator.curate(candidates, onScreen: onScreen)
        curationCache = (key: key, keyed: keyed, agents: curated)
        return curated
    }

    /// A short, privacy-filtered excerpt of the text that was actually on screen while
    /// a detected workflow happened — the OCR/AX content of the moments around its most
    /// recent occurrence (`lastSeenAt` back one run length). Feeds the curator so goals
    /// name the real subject matter ("reply to refund emails") rather than the shape
    /// ("reply to emails"). Returns nil when nothing legible/safe is on record.
    private func onScreenText(for waste: DetectedWaste) async -> String? {
        let runLength = max(8.0, Double(waste.estimatedSecondsPerRun))
        let start = waste.lastSeenAt.addingTimeInterval(-runLength - 3)
        let end = waste.lastSeenAt.addingTimeInterval(3)
        guard let moments = try? await store.contexts(between: start, and: end, limit: 12) else { return nil }
        var seen = Set<String>()
        var snippets: [String] = []
        for moment in moments where !PrivacyRules.isSensitive(moment) {
            guard let raw = moment.ocrText else { continue }
            // Collapse the OCR's runs of whitespace/newlines into single spaces, then
            // bound each snippet so one busy screen can't dominate the prompt.
            let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 8 else { continue }
            let snippet = String(cleaned.prefix(200))
            if seen.insert(snippet).inserted { snippets.append(snippet) }
            if snippets.count >= 3 { break }
        }
        let joined = snippets.joined(separator: " ⋯ ")
        return joined.isEmpty ? nil : String(joined.prefix(600))
    }

    /// Persists an agent from a curated proposal — the recorded recipe drives
    /// replay, but the agent takes the curator's human NAME so "Your agents" reads
    /// like the user's own words instead of "Repeated steps in <app>".
    @discardableResult
    public func createAgent(from curated: CuratedAgent) async throws -> CascadeAgent {
        let waste = curated.source
        return try await store.upsertAgent(CascadeAgent(
            name: curated.name,
            source: .detected,
            signature: waste.signature,
            recipe: waste.recipe,
            apps: waste.apps,
            estimatedSeconds: waste.estimatedTotalSeconds,
            estimatedSecondsPerRun: waste.estimatedSecondsPerRun,
            evidenceCount: waste.occurrences,
            goal: curated.goal
        ))
    }

    public func agents() async throws -> [CascadeAgent] {
        try await store.agents()
    }
}
