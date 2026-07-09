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

public struct AgentCreationPlan: Sendable, Equatable {
    public let schemaVersion: String
    public let signatureHash: String
    public let goalHash: String
    public let goalCharacterCount: Int
    public let traceHash: String
    public let recipeStepCount: Int
    public let occurrenceCount: Int
    public let occurrenceIDCount: Int
    public let occurrenceIDsHash: String
    public let appCount: Int
    public let surfaceFlow: [SurfaceSummary]
    public let targetChecks: [TargetCheck]
    public let liveValueSlots: [LiveValueSlot]
    public let dataflowEdges: [DataflowEdge]

    public struct SurfaceSummary: Sendable, Equatable {
        public let order: Int
        public let surfaceHash: String
        public let surfaceCharacterCount: Int
        public let appHash: String
        public let documentHash: String?
    }

    public struct TargetCheck: Sendable, Equatable {
        public let order: Int
        public let kind: RecipeStepKind
        public let surfaceHash: String
        public let documentHash: String?
        public let hasCoordinate: Bool
        public let targetDescriptorHash: String?
        public let anchorHash: String?

        public var hasReplayTarget: Bool {
            hasCoordinate || targetDescriptorHash != nil || anchorHash != nil
        }
    }

    public struct LiveValueSlot: Sendable, Equatable {
        public let order: Int
        public let keyHash: String
        public let keyCharacterCount: Int
        public let kind: RecipeParameterKind?
        public let valueShapeCount: Int
        public let valueHashCount: Int
        public let sourceStepCount: Int
        public let dataflowEdgeHash: String?
        public let targetSurfaceHash: String
        public let targetDocumentHash: String?
        public let isPasteShortcut: Bool
    }

    public struct DataflowEdge: Sendable, Equatable {
        public let edgeHash: String
        public let targetOrder: Int
        public let sourceOrders: [Int]
        public let sourceSurfaceHashes: [String]
        public let targetSurfaceHash: String
        public let sourceDocumentHashes: [String]
        public let targetDocumentHash: String?
        public let transform: String?
    }

    public func auditDetail(issueCodes: [String] = []) -> String {
        var fields = [
            "schema=\(schemaVersion)",
            "signatureHash=\(signatureHash)",
            "goalHash=\(goalHash)",
            "goalChars=\(goalCharacterCount)",
            "traceHash=\(traceHash)",
            "stepCount=\(recipeStepCount)",
            "occurrenceCount=\(occurrenceCount)",
            "occurrenceIDCount=\(occurrenceIDCount)",
            "occurrenceIDsHash=\(occurrenceIDsHash)",
            "appCount=\(appCount)",
            "surfaceCount=\(surfaceFlow.count)",
            "surfaceFlowHash=\(AuditIdentity.hash(surfaceFlow.map(\.surfaceHash).joined(separator: "|")))",
            "targetCount=\(targetChecks.count)",
            "anchoredTargetCount=\(targetChecks.filter(\.hasReplayTarget).count)",
            "liveSlotCount=\(liveValueSlots.count)",
            "dataflowEdgeCount=\(dataflowEdges.count)",
            "dataflowEdgeHash=\(AuditIdentity.hash(dataflowEdges.map(\.edgeHash).joined(separator: "|")))"
        ]
        if !issueCodes.isEmpty {
            fields.append("issueCount=\(issueCodes.count)")
            fields.append("issueCodes=\(issueCodes.map(AuditIdentity.safeToken).joined(separator: ","))")
        }
        return fields.joined(separator: " ")
    }
}

public struct AgentPlanSynthesizer: Sendable {
    public init() {}

    public func synthesize(from curated: CuratedAgent) -> AgentCreationPlan {
        synthesize(
            goal: curated.goal,
            signature: curated.signature,
            recipe: curated.source.recipe,
            apps: curated.source.apps,
            occurrenceCount: curated.source.occurrences,
            occurrenceIDs: curated.source.evidence
        )
    }

    public func synthesize(
        goal: String,
        signature: String,
        recipe: AgentRecipe,
        apps: [String],
        occurrenceCount: Int,
        occurrenceIDs: [Int64]
    ) -> AgentCreationPlan {
        let steps = recipe.steps.sorted { $0.order < $1.order }
        let byOrder = Dictionary(uniqueKeysWithValues: steps.map { ($0.order, $0) })
        let surfaceFlow = Self.surfaceFlow(for: steps)
        let targetChecks = steps.compactMap(Self.targetCheck(for:))
        let liveValueSlots = steps.filter(Self.isLiveValueStep).map(Self.liveValueSlot(for:))
        let dataflowEdges = liveValueSlots.compactMap { slot -> AgentCreationPlan.DataflowEdge? in
            guard let target = byOrder[slot.order] else { return nil }
            let sources = target.sourceStepIDs.compactMap { byOrder[$0] }
            guard !sources.isEmpty || target.dataflowEdgeID != nil else { return nil }
            let sourceOrders = sources.map(\.order).sorted()
            let sourceSurfaceHashes = Self.uniqueSortedHashes(sources.map(Self.surfaceIdentity))
            let sourceDocumentHashes = Self.uniqueSortedHashes(sources.compactMap(\.documentIdentityHash))
            let edgeIdentity = target.dataflowEdgeID ?? [
                "target:\(target.order)",
                "sources:\(sourceOrders.map(String.init).joined(separator: ","))"
            ].joined(separator: "|")
            return AgentCreationPlan.DataflowEdge(
                edgeHash: AuditIdentity.hash(edgeIdentity),
                targetOrder: target.order,
                sourceOrders: sourceOrders,
                sourceSurfaceHashes: sourceSurfaceHashes,
                targetSurfaceHash: AuditIdentity.hash(Self.surfaceIdentity(target)),
                sourceDocumentHashes: sourceDocumentHashes,
                targetDocumentHash: target.documentIdentityHash,
                transform: target.transform.map(AuditIdentity.safeToken)
            )
        }
        return AgentCreationPlan(
            schemaVersion: "agent-creation-plan.v1",
            signatureHash: AuditIdentity.hash(signature),
            goalHash: AuditIdentity.hash(goal),
            goalCharacterCount: AuditIdentity.count(goal),
            traceHash: Self.traceHash(for: steps),
            recipeStepCount: steps.count,
            occurrenceCount: occurrenceCount,
            occurrenceIDCount: occurrenceIDs.count,
            occurrenceIDsHash: AuditIdentity.hash(occurrenceIDs.sorted().map(String.init).joined(separator: ",")),
            appCount: Set(apps.map(AuditIdentity.safeToken)).count,
            surfaceFlow: surfaceFlow,
            targetChecks: targetChecks,
            liveValueSlots: liveValueSlots,
            dataflowEdges: dataflowEdges
        )
    }

    private static func surfaceFlow(for steps: [RecipeStep]) -> [AgentCreationPlan.SurfaceSummary] {
        var summaries: [AgentCreationPlan.SurfaceSummary] = []
        var previousKey: String?
        for step in steps {
            let surface = surfaceIdentity(step)
            let document = step.documentIdentityHash
            let key = "\(surface)|\(document ?? "none")"
            guard key != previousKey else { continue }
            summaries.append(AgentCreationPlan.SurfaceSummary(
                order: step.order,
                surfaceHash: AuditIdentity.hash(surface),
                surfaceCharacterCount: AuditIdentity.count(surface),
                appHash: AuditIdentity.hash(step.appName),
                documentHash: document
            ))
            previousKey = key
        }
        return summaries
    }

    private static func targetCheck(for step: RecipeStep) -> AgentCreationPlan.TargetCheck? {
        guard step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick else { return nil }
        return AgentCreationPlan.TargetCheck(
            order: step.order,
            kind: step.kind,
            surfaceHash: AuditIdentity.hash(surfaceIdentity(step)),
            documentHash: step.documentIdentityHash,
            hasCoordinate: step.x != nil && step.y != nil,
            targetDescriptorHash: step.targetDescriptor.map(AuditIdentity.hash),
            anchorHash: step.ocrAnchor.map(AuditIdentity.hash)
        )
    }

    private static func liveValueSlot(for step: RecipeStep) -> AgentCreationPlan.LiveValueSlot {
        let key = step.parameterKey ?? step.dataflowEdgeID ?? step.ocrAnchor ?? "step-\(step.order)"
        return AgentCreationPlan.LiveValueSlot(
            order: step.order,
            keyHash: AuditIdentity.hash(key),
            keyCharacterCount: AuditIdentity.count(key),
            kind: step.parameterKind,
            valueShapeCount: step.valueExamples.count,
            valueHashCount: step.valueHashes.count,
            sourceStepCount: step.sourceStepIDs.count,
            dataflowEdgeHash: step.dataflowEdgeID.map(AuditIdentity.hash),
            targetSurfaceHash: AuditIdentity.hash(surfaceIdentity(step)),
            targetDocumentHash: step.documentIdentityHash,
            isPasteShortcut: isPasteShortcut(step)
        )
    }

    private static func traceHash(for steps: [RecipeStep]) -> String {
        let components = steps.map { step in
            [
                "order:\(step.order)",
                "kind:\(step.kind.rawValue)",
                "surface:\(AuditIdentity.hash(surfaceIdentity(step)))",
                "document:\(step.documentIdentityHash ?? "none")",
                "target:\(step.idempotentActionKeyHash)",
                "edge:\(AuditIdentity.hash(step.dataflowEdgeID))",
                "parameter:\(step.isParameter ? "1" : "0")"
            ].joined(separator: ",")
        }
        return AuditIdentity.hash(components.joined(separator: "|"))
    }

    private static func isLiveValueStep(_ step: RecipeStep) -> Bool {
        step.isParameter && (step.kind == .type || isPasteShortcut(step) || !step.sourceStepIDs.isEmpty)
    }

    private static func isPasteShortcut(_ step: RecipeStep) -> Bool {
        guard step.kind == .key, step.key?.lowercased() == "v" else { return false }
        let modifiers = Set(step.modifiers.map { $0.lowercased() })
        return modifiers.contains("command") || modifiers.contains("cmd") || modifiers.contains("control") || modifiers.contains("ctrl")
    }

    private static func surfaceIdentity(_ step: RecipeStep) -> String {
        let surface = step.surface?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let surface, !surface.isEmpty { return surface }
        return step.appName
    }

    private static func uniqueSortedHashes(_ values: [String]) -> [String] {
        Array(Set(values.map(AuditIdentity.hash))).sorted()
    }
}

public struct AgentPlanValidator: Sendable {
    public init() {}

    public func validate(_ plan: AgentCreationPlan) throws {
        var issues: [String] = []
        if plan.goalCharacterCount == 0 { issues.append("empty_goal") }
        if plan.signatureHash == AuditIdentity.hash(nil) { issues.append("empty_signature") }
        if plan.recipeStepCount == 0 { issues.append("empty_recipe") }
        if plan.occurrenceCount <= 0 { issues.append("empty_occurrences") }
        if plan.surfaceFlow.isEmpty { issues.append("empty_surface_flow") }

        let missingTargets = plan.targetChecks.filter { !$0.hasReplayTarget }
        if !missingTargets.isEmpty { issues.append("missing_replay_targets") }

        let targetOrders = Set(plan.targetChecks.map(\.order))
        if targetOrders.count != plan.targetChecks.count { issues.append("duplicate_target_orders") }

        for edge in plan.dataflowEdges {
            if edge.sourceOrders.isEmpty {
                issues.append("dataflow_missing_source")
            }
            if edge.sourceOrders.contains(where: { $0 >= edge.targetOrder }) {
                issues.append("dataflow_source_not_before_target")
            }
            if edge.sourceSurfaceHashes.isEmpty && edge.sourceDocumentHashes.isEmpty {
                issues.append("dataflow_missing_source_identity")
            }
        }

        for slot in plan.liveValueSlots {
            if slot.kind == nil { issues.append("live_slot_missing_kind") }
            if slot.keyCharacterCount == 0 { issues.append("live_slot_missing_key") }
            if slot.isPasteShortcut && slot.sourceStepCount == 0 {
                issues.append("paste_slot_missing_source")
            }
        }

        if !issues.isEmpty {
            throw AgentPlanValidationError(issueCodes: Array(Set(issues)).sorted())
        }
    }
}

public struct AgentPlanValidationError: Error, LocalizedError, Sendable, Equatable {
    public let issueCodes: [String]

    public init(issueCodes: [String]) {
        self.issueCodes = issueCodes
    }

    public var errorDescription: String? {
        "Agent synthesis validation failed: \(issueCodes.joined(separator: ", "))"
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
            _ = try await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "computer.act",
                detail: result.auditDetail
            ))
            if result.status != .ok {
                if result.failureKind == .secureInput {
                    throw ComputerUseError.secureInput(result.failureKind?.rawValue ?? result.status.rawValue)
                }
                throw ComputerUseError.unsupported(result.failureKind?.rawValue ?? result.status.rawValue)
            }
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
    private static let experimentalParameterizedMiningKey = "cascade.experimentalParameterizedMining"

    private let store: CascadeStore
    private let localAnswerer: ContextQuestionAnswering
    private let claudeAnswerer: ContextQuestionAnswering
    private let recordAnswerer: RecordAnswering
    private let planner: SingleStepPlanner
    private let wasteDetector = WasteDetector()
    private let contextWasteDetector = ContextWasteDetector()
    private let curator: WorkflowCurator
    /// Curation is a model call; cache it against the set of candidate signatures
    /// (and whether a key is connected) so frequent refreshes don't re-curate the
    /// same unchanged list.
    private var curationCache: (key: Set<String>, keyed: Bool, agents: [CuratedAgent])?
    private var contextCurationCache: (key: Set<String>, keyed: Bool, agents: [CuratedContextWaste])?
    private let keyStore: AnthropicKeyStore
    private let detectedWasteReportObserver: (@Sendable () -> Void)?

    public init(
        store: CascadeStore,
        localAnswerer: ContextQuestionAnswering = LocalGroundedAnswerer(),
        claudeAnswerer: ContextQuestionAnswering = ClaudeGroundedAnswerer(),
        recordAnswerer: RecordAnswering? = nil,
        planner: SingleStepPlanner? = nil,
        curator: WorkflowCurator? = nil,
        modelCallCache: ModelCallCache? = nil,
        keyStore: AnthropicKeyStore = AnthropicKeyStore(),
        detectedWasteReportObserver: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.localAnswerer = localAnswerer
        self.claudeAnswerer = claudeAnswerer
        self.recordAnswerer = recordAnswerer ?? RecordSearchAnswerer(store: store, keyStore: keyStore)
        self.planner = planner ?? ClaudeSingleStepPlanner(cache: modelCallCache)
        self.curator = curator ?? WorkflowCurator(client: AnthropicClient(keyStore: keyStore), cache: modelCallCache)
        self.keyStore = keyStore
        self.detectedWasteReportObserver = detectedWasteReportObserver
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
    public func askRecord(
        _ question: String,
        conversation: [(user: String, assistant: String)] = [],
        sourcePlan: SourcePlan? = nil
    ) async throws -> RecordAnswer {
        if let sourcePlan, !Self.planAllowsRecordedMemory(sourcePlan) {
            return RecordAnswer(text: "source-mismatch: this ask was not routed to recorded memory.", citedMomentIDs: [])
        }
        let cleanPlanQuery = sourcePlan?.cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let routedQuestion = cleanPlanQuery?.isEmpty == false
            ? (cleanPlanQuery ?? question)
            : question
        if keyStore.hasKey(),
           let answer = try? await answerRecord(
            question: routedQuestion,
            conversation: conversation,
            sourcePlan: sourcePlan
           ) {
            return answer
        }
        let grounding = try await chatGrounding(for: routedQuestion)
        if keyStore.hasKey(), let answer = try? await claudeAnswerer.answer(question: routedQuestion, grounding: grounding) {
            return RecordAnswer(text: answer, citedMomentIDs: [])
        }
        return RecordAnswer(
            text: try await localAnswerer.answer(question: routedQuestion, grounding: grounding),
            citedMomentIDs: []
        )
    }

    private func answerRecord(
        question: String,
        conversation: [(user: String, assistant: String)],
        sourcePlan: SourcePlan?
    ) async throws -> RecordAnswer {
        if let planned = recordAnswerer as? SourcePlanRecordAnswering {
            return try await planned.answer(question: question, conversation: conversation, sourcePlan: sourcePlan)
        }
        return try await recordAnswerer.answer(question: question, conversation: conversation)
    }

    private static func planAllowsRecordedMemory(_ plan: SourcePlan) -> Bool {
        plan.candidateSources.contains(.recordedMemory)
            || plan.routingIntent == .answerRecord
            || plan.routingIntent == .instructionalWithRecordDependency
            || plan.routingIntent == .mixed
            || plan.routingIntent == .ambiguous
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
        useEpisodeMining: Bool = true,
        useParameterizedMining: Bool = false
    ) async throws -> [DetectedWaste] {
        let contexts = try await store.recentContexts(limit: 400)
        let events = try await store.recentInputEvents(limit: 3000)
        return wasteDetector.detect(
            contexts: contexts,
            inputEvents: events,
            maxResults: maxResults,
            webAppIdentity: webAppIdentity,
            useEpisodeMining: useEpisodeMining,
            useParameterizedMining: useParameterizedMining
        )
    }

    public func detectedWasteReport(
        maxResults: Int = 5,
        webAppIdentity: (@Sendable (InputEvent) -> String?)? = nil,
        useEpisodeMining: Bool = true,
        useParameterizedMining: Bool = false
    ) async throws -> WasteDetectionReport {
        detectedWasteReportObserver?()
        let contexts = try await store.recentContexts(limit: 400)
        let events = try await store.recentInputEvents(limit: 3000)
        return wasteDetector.detectReport(
            contexts: contexts,
            inputEvents: events,
            maxResults: maxResults,
            webAppIdentity: webAppIdentity,
            useEpisodeMining: useEpisodeMining,
            useParameterizedMining: useParameterizedMining
        )
    }

    /// Context-first waste detection: groups safe OCR/window/entity context into
    /// repeated real-work sessions. It does not create replay recipes. When action
    /// waste is supplied, candidates are tagged with a linked recipe signature only
    /// if the same apps overlap the candidate's evidence window.
    public func contextWasteReport(
        maxResults: Int = 5,
        linkingTo actionWastes: [DetectedWaste] = []
    ) async throws -> ContextWasteReport {
        let contexts = try await store.recentContexts(limit: 1_200)
        let report = contextWasteDetector.detectReport(contexts: contexts, maxResults: maxResults)
        return Self.linkContextWaste(report, to: actionWastes)
    }

    public func contextWaste(
        maxResults: Int = 5,
        linkingTo actionWastes: [DetectedWaste] = []
    ) async throws -> [ContextWasteCandidate] {
        try await contextWasteReport(maxResults: maxResults, linkingTo: actionWastes).results
    }

    private nonisolated static func linkContextWaste(
        _ report: ContextWasteReport,
        to actionWastes: [DetectedWaste]
    ) -> ContextWasteReport {
        guard !actionWastes.isEmpty, !report.results.isEmpty else { return report }
        let linked = report.results.map { candidate in
            candidate.linked(to: bestLinkedActionWaste(for: candidate, in: actionWastes))
        }
        return report.replacingResults(linked)
    }

    private nonisolated static func bestLinkedActionWaste(
        for candidate: ContextWasteCandidate,
        in actionWastes: [DetectedWaste]
    ) -> DetectedWaste? {
        let candidateApps = Set(candidate.apps.map { $0.lowercased() })
        let evidenceStart = candidate.startedAt.addingTimeInterval(-300)
        let evidenceEnd = candidate.endedAt.addingTimeInterval(300)
        let maxDistance = max(TimeInterval(candidate.estimatedSecondsPerRun), 600)
        let ranked = actionWastes.compactMap { waste -> (waste: DetectedWaste, score: Double)? in
            let wasteApps = Set(waste.apps.map { $0.lowercased() })
            let appOverlap = candidateApps.isEmpty || wasteApps.isEmpty || !candidateApps.isDisjoint(with: wasteApps)
            guard appOverlap else { return nil }
            let inWindow = evidenceStart...evidenceEnd ~= waste.lastSeenAt
            let distance = abs(waste.lastSeenAt.timeIntervalSince(candidate.lastSeenAt))
            guard inWindow || distance <= maxDistance else { return nil }
            let compatibility = contextRecipeCompatibility(candidate: candidate, waste: waste)
            guard compatibility > 0 else { return nil }
            let appScore = Double(candidateApps.intersection(wasteApps).count)
            let timeScore = max(0, 1.0 - min(distance, maxDistance) / maxDistance)
            let recipeScore = min(1.0, Double(waste.recipe.steps.count) / 6.0)
            return (waste, appScore + timeScore + recipeScore + compatibility)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.waste.signature < rhs.waste.signature
        }.first?.waste
    }

    private nonisolated static func contextRecipeCompatibility(
        candidate: ContextWasteCandidate,
        waste: DetectedWaste
    ) -> Double {
        let candidateTerms = Set(candidate.processTerms.map { normalizedContextToken($0) }.filter { !$0.isEmpty })
        let recipeTerms = Set(recipeVocabularyTerms(for: waste))
        let overlap = candidateTerms.intersection(recipeTerms)
        let vocabularyScore = min(2.0, Double(overlap.count) * 0.75)
        let candidateRoles = Set(candidate.parameters.map(\.role).map(normalizedContextToken).filter { !$0.isEmpty })
        let recipeRoles = Set(recipeRoleTerms(for: waste.recipe.steps))
        let roleOverlap = candidateRoles.intersection(recipeRoles)
        let roleScore = min(1.5, Double(roleOverlap.count) * 0.75)
        guard vocabularyScore > 0 || roleScore > 0 else { return 0 }
        return vocabularyScore + roleScore
    }

    private nonisolated static func recipeVocabularyTerms(for waste: DetectedWaste) -> [String] {
        var values = [waste.title]
        values += waste.recipe.humanSteps
        for step in waste.recipe.steps {
            values += [
                step.appName,
                step.surface,
                step.windowTitleHint,
                step.ocrAnchor,
                step.targetDescriptor,
                step.parameterKey,
                step.dataflowEdgeID
            ].compactMap { $0 }
        }
        return values.flatMap(contextTokens)
    }

    private nonisolated static func recipeRoleTerms(for steps: [RecipeStep]) -> [String] {
        var terms: [String] = []
        for step in steps {
            if let key = step.parameterKey {
                terms += contextTokens(key)
            }
            if let kind = step.parameterKind {
                terms.append(normalizedContextToken(kind.rawValue))
            }
            if step.dataflowEdgeID != nil || !step.sourceStepIDs.isEmpty {
                terms.append("data")
            }
            if step.isParameter {
                terms.append("record_value")
            }
        }
        return terms
    }

    private nonisolated static func contextTokens(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map { normalizedContextToken(String($0)) }
            .filter { token in
                token.count >= 3
                    && !contextStopwords.contains(token)
                    && token.rangeOfCharacter(from: .letters) != nil
            }
    }

    private nonisolated static func normalizedContextToken(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
        let collapsed = normalized.split(separator: " ").joined(separator: "")
        if collapsed.hasSuffix("ies"), collapsed.count > 4 {
            return String(collapsed.dropLast(3)) + "y"
        }
        if collapsed.hasSuffix("s"),
           !collapsed.hasSuffix("ss"),
           !collapsed.hasSuffix("us"),
           collapsed != "status" {
            return String(collapsed.dropLast())
        }
        return collapsed
    }

    private nonisolated static let contextStopwords: Set<String> = [
        "and", "app", "button", "click", "done", "from", "into", "key", "open",
        "screen", "step", "switch", "the", "then", "this", "type", "value", "with"
    ]

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

    public func curateContextWaste(_ candidates: [ContextWasteCandidate]) async -> [CuratedContextWaste] {
        let keyed = keyStore.hasKey()
        let key = Set(candidates.map(\.signature))
        if let cache = contextCurationCache, cache.key == key, cache.keyed == keyed {
            let bySignature = Dictionary(candidates.map { ($0.signature, $0) }, uniquingKeysWith: { first, _ in first })
            return cache.agents.map { agent in
                guard let fresh = bySignature[agent.signature] else { return agent }
                let feasibility: ContextWasteAgentFeasibility = fresh.linkedActionSignature == nil
                    ? agent.feasibility
                    : .linkedRecipe
                return CuratedContextWaste(
                    id: agent.id,
                    source: fresh,
                    name: agent.name,
                    why: agent.why,
                    goal: agent.goal,
                    value: agent.value,
                    feasibility: feasibility
                )
            }
        }
        let curated = await curator.curateContextWaste(candidates)
        contextCurationCache = (key: key, keyed: keyed, agents: curated)
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
        let demoSketch = TrajectorySketchBuilder(maxActions: 6, maxAnchors: 4, maxChecks: 3, maxCorrections: 2)
            .build(goal: curated.goal, recipe: waste.recipe)
        let persistedSketches = [AgentDemoSketch(demoSketch)].filter { !$0.promptText.isEmpty }
        let agent = CascadeAgent(
            name: curated.name,
            source: .detected,
            signature: waste.signature,
            recipe: waste.recipe,
            apps: waste.apps,
            estimatedSeconds: waste.estimatedTotalSeconds,
            estimatedSecondsPerRun: waste.estimatedSecondsPerRun,
            evidenceCount: waste.occurrences,
            evidenceIDs: curated.evidence,
            goal: curated.goal,
            demoSketches: Array(persistedSketches.prefix(3))
        )
        guard Self.agentSynthesisEnabled() else {
            return try await store.upsertAgent(agent)
        }

        let plan = AgentPlanSynthesizer().synthesize(from: curated)
        let batchPlan = BatchCompletionPlanner().plan(from: curated)
        do {
            try AgentPlanValidator().validate(plan)
            if let batchPlan {
                try BatchCompletionPlanValidator().validate(batchPlan)
            }
        } catch let validationError as AgentPlanValidationError {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "agent.synthesis.failed",
                detail: plan.auditDetail(issueCodes: validationError.issueCodes)
            ))
            throw validationError
        } catch let validationError as BatchCompletionPlanValidationError {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "agent.batch.plan.failed",
                detail: batchPlan?.auditDetail(issueCodes: validationError.issueCodes) ?? "schema=\(BatchCompletionPlan.schemaVersion) issueCodes=missing_plan"
            ))
            throw validationError
        } catch {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "agent.synthesis.failed",
                detail: plan.auditDetail(issueCodes: ["unknown_validation_error"])
            ))
            throw error
        }

        _ = try await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "agent.synthesis.validated",
            detail: plan.auditDetail()
        ))
        if let batchPlan {
            _ = try await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "agent.batch.plan.ready",
                detail: batchPlan.auditDetail()
            ))
        }
        return try await store.upsertAgent(agent)
    }

    /// Persists a context-first agent from repeated OCR/Rewind evidence. These agents
    /// intentionally do not replay mined clicks; they run from the curated goal through
    /// the normal assist/background agent path.
    @discardableResult
    public func createAgent(from curated: CuratedContextWaste) async throws -> CascadeAgent {
        let waste = curated.source
        if curated.feasibility == .linkedRecipe {
            guard let linkedWaste = waste.linkedActionWaste else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try await createAgent(from: CuratedAgent(
                id: curated.id,
                source: linkedWaste,
                name: curated.name,
                why: curated.why,
                goal: curated.goal,
                value: curated.value
            ))
        }
        let agent = CascadeAgent(
            name: curated.name,
            source: .detected,
            signature: waste.signature,
            recipe: AgentRecipe(steps: []),
            apps: waste.apps,
            estimatedSeconds: waste.estimatedTotalSeconds,
            estimatedSecondsPerRun: waste.estimatedSecondsPerRun,
            evidenceCount: waste.occurrences,
            evidenceIDs: curated.evidence,
            goal: curated.goal
        )
        return try await store.upsertAgent(agent)
    }

    public func agents() async throws -> [CascadeAgent] {
        try await store.agents()
    }

    private nonisolated static func agentSynthesisEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Self.experimentalParameterizedMiningKey)
    }
}

private extension AgentDemoSketch {
    init(_ sketch: TrajectorySketch) {
        self.init(
            id: sketch.id,
            appName: sketch.appName,
            windowTitle: sketch.windowTitle,
            normalizedGoalTokens: sketch.normalizedGoalTokens,
            promptText: sketch.promptText,
            actionCount: sketch.firstActions.count,
            anchorCount: sketch.safeAnchors.count,
            checkCount: sketch.expectedChecks.count
        )
    }
}
