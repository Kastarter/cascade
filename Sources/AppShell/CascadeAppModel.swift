import AgentOrchestrator
import AppKit
import ApplicationServices
import CascadeMemory
import Combine
import ComputerUseKit
import Foundation
import ImageIO
import MacContextKit
import ProviderKit
import SandboxKit
import WasteDetection

public struct VisualGrounderRuntimeStatus: Equatable, Sendable {
    public let preset: GrounderPreset
    public let backend: String
    public let modelID: String
    public let endpoint: String
    public let coordSpace: UITARSGrounder.CoordSpace
    public let probeStatus: String
    public let lastMiniEvalScore: Double?

    public init(
        preset: GrounderPreset,
        backend: String,
        modelID: String,
        endpoint: String,
        coordSpace: UITARSGrounder.CoordSpace,
        probeStatus: String,
        lastMiniEvalScore: Double?
    ) {
        self.preset = preset
        self.backend = backend
        self.modelID = modelID
        self.endpoint = endpoint
        self.coordSpace = coordSpace
        self.probeStatus = probeStatus
        self.lastMiniEvalScore = lastMiniEvalScore
    }
}

/// One real Q&A turn over local context — drives the Reel "Ask about this moment" thread.
/// A moment an answer was grounded in — rendered as a proof chip under the
/// reply; clicking it jumps the Reel to that exact point in time.
public struct CitedMoment: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let appName: String
    public let capturedAt: Date
    public let imagePath: String?

    public init(id: Int64, appName: String, capturedAt: Date, imagePath: String?) {
        self.id = id
        self.appName = appName
        self.capturedAt = capturedAt
        self.imagePath = imagePath
    }
}

public struct QATurn: Identifiable, Sendable {
    public let id = UUID()
    public let question: String
    public let answer: String
    public var citations: [CitedMoment] = []
}

public struct ReelClickMarker: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let capturedAt: Date
    public let x: Double
    public let y: Double
    public let label: String?
    public let targetDescriptor: String?

    public init?(event: InputEvent) {
        guard [.click, .doubleClick, .rightClick].contains(event.kind),
              let x = event.x,
              let y = event.y else { return nil }
        self.id = event.id
        self.capturedAt = event.capturedAt
        self.x = x
        self.y = y
        self.label = event.text
        self.targetDescriptor = event.targetDescriptor
    }
}

/// A background agent running in the isolated web sandbox.
public struct BackgroundAgentRun: Identifiable, Sendable {
    public let id: UUID
    public let task: String
    /// Set when this run deploys a saved agent — completion feeds its run count.
    public var agentID: Int64?
    // No status/snapshot/done/result: the live watch box renders the agent's own
    // WKWebView, so those were write-only — the snapshot in particular retained a
    // PNG per step that no view ever read.
}

@MainActor
public final class CascadeAppModel: ObservableObject {
    public enum AuditIntegrityStatus: Equatable, Sendable {
        case unchecked
        case trusted(AuditChainStatus)
        case untrusted(AuditChainStatus)
        case verificationFailed(String)

        public var isTrusted: Bool {
            switch self {
            case .trusted:
                true
            case .unchecked, .untrusted, .verificationFailed:
                false
            }
        }
    }

    public enum Tab: String, CaseIterable, Identifiable {
        case reel = "Reel"
        case cascades = "Cascades"
        case manager = "Manager"

        public var id: String { rawValue }
    }

    public struct LearningOpportunity: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable {
            case repeatedWorkflow
            case overlappingDrafts
            case recurringFailure
            case parameterizedRecipe
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String
        public let actionTitle: String

        public init(id: String, kind: Kind, title: String, detail: String, actionTitle: String) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.actionTitle = actionTitle
        }
    }

    public enum ProactiveMode: String, CaseIterable, Sendable {
        case off
        case quiet
        case askFirst
    }

    public enum ProactiveAppControl: String, Sendable {
        case neverSuggest
        case onlyInCascade
        case savedAgentsOnly
    }

    public enum SuggestionTimingPreference: String, CaseIterable, Sendable {
        case early
        case balanced
        case strongEvidence
    }

    public enum BackgroundAgentPreference: String, CaseIterable, Sendable {
        case prefer
        case askFirst
        case avoid
    }

    @Published public var selectedTab: Tab = .reel
    @Published public var showSettings = false
    /// First-run setup: permissions + keys, shown once over everything until
    /// dismissed (reopenable from Settings). Without it a new user lands on an
    /// empty Reel with no idea why nothing records.
    @Published public var showOnboarding: Bool
    @Published public var prefersDark = true
    /// Declined workflow signatures — "no" must survive a relaunch (persisted).
    @Published private var dismissedWasteSignatures: Set<String> {
        didSet { Self.persist(dismissedWasteSignatures, key: Self.dismissedWasteKey, defaults: defaultsStore) }
    }
    private static let dismissedWasteKey = "cascade.dismissedWaste"
    @Published private var dismissedNextActionOfferKeys: Set<String> {
        didSet { Self.persist(dismissedNextActionOfferKeys, key: Self.dismissedNextActionOffersKey, defaults: defaultsStore) }
    }
    static let dismissedNextActionOffersKey = "cascade.dismissedNextActionOffers"
    @Published private var snoozedProactiveOfferKeys: Set<String> {
        didSet { Self.persist(snoozedProactiveOfferKeys, key: Self.snoozedProactiveOffersKey, defaults: defaultsStore) }
    }
    static let snoozedProactiveOffersKey = "cascade.snoozedProactiveOffers"
    @Published private var alwaysOfferProactiveKeys: Set<String> {
        didSet { Self.persist(alwaysOfferProactiveKeys, key: Self.alwaysOfferProactiveKey, defaults: defaultsStore) }
    }
    static let alwaysOfferProactiveKey = "cascade.alwaysOfferProactive"
    @Published private var neverSuggestApps: Set<String> {
        didSet { Self.persist(neverSuggestApps, key: Self.neverSuggestAppsKey, defaults: defaultsStore) }
    }
    static let neverSuggestAppsKey = "cascade.proactive.neverSuggestApps"
    @Published private var onlyInCascadeApps: Set<String> {
        didSet { Self.persist(onlyInCascadeApps, key: Self.onlyInCascadeAppsKey, defaults: defaultsStore) }
    }
    static let onlyInCascadeAppsKey = "cascade.proactive.onlyInCascadeApps"
    @Published private var savedAgentsOnlyApps: Set<String> {
        didSet { Self.persist(savedAgentsOnlyApps, key: Self.savedAgentsOnlyAppsKey, defaults: defaultsStore) }
    }
    static let savedAgentsOnlyAppsKey = "cascade.proactive.savedAgentsOnlyApps"
    @Published private var dismissedLearningOpportunityKeys: Set<String> {
        didSet { Self.persist(dismissedLearningOpportunityKeys, key: Self.dismissedLearningOpportunitiesKey, defaults: defaultsStore) }
    }
    static let dismissedLearningOpportunitiesKey = "cascade.dismissedLearningOpportunities"

    private static func persist(_ values: Set<String>, key: String, defaults: UserDefaults) {
        // Capped so years of declines can't grow the defaults plist unbounded.
        defaults.set(Array(values.suffix(300)), forKey: key)
    }

    private static func restoreSet(key: String, defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
    @Published public private(set) var contexts: [RecordedContext] = []
    @Published public private(set) var searchResults: [RecordedContext] = []
    @Published public private(set) var searchQuery: String = ""
    @Published public private(set) var reelClickMarkersByContextID: [Int64: [ReelClickMarker]] = [:]
    @Published public private(set) var audit: [AuditEvent] = []
    @Published public private(set) var auditIntegrityStatus: AuditIntegrityStatus = .unchecked
    @Published public private(set) var privacySummary: PrivacySummary?
    @Published public private(set) var sloSnapshot: ReliabilityReport.SLOSnapshot?
    @Published public private(set) var valueSummary = AgentValueSummary(
        completedRuns: 0,
        reclaimedSeconds: 0,
        modelToolCostUSD: 0,
        toolActionCount: 0,
        hourlyRateUSD: 75
    )
    /// The raw recall layer: every repeated sequence the detector found, before the
    /// automatable filter and curation. Kept observable so the pipeline is testable.
    @Published public private(set) var detectedWaste: [DetectedWaste] = []
    /// The curated, judged, human-named view of `detectedWaste` — what the manager's
    /// review queue shows (the only place detected workflows surface to a person).
    @Published public private(set) var curatedWaste: [CuratedAgent] = []
    @Published public private(set) var learningOpportunities: [LearningOpportunity] = []
    @Published public private(set) var proactiveNextActionOffer: NextActionPredictor.Prediction?
    @Published public private(set) var proactiveOffer: ProactiveOffer?
    @Published public var proactiveMode: ProactiveMode {
        didSet { defaultsStore.set(proactiveMode.rawValue, forKey: Self.proactiveModeKey) }
    }
    @Published public var suggestionTimingPreference: SuggestionTimingPreference {
        didSet {
            defaultsStore.set(suggestionTimingPreference.rawValue, forKey: Self.suggestionTimingPreferenceKey)
            applySuggestionTimingPreference()
            Task { await recordColdStartPreference(kind: "suggestionTiming", value: suggestionTimingPreference.rawValue) }
        }
    }
    @Published public var backgroundAgentPreference: BackgroundAgentPreference {
        didSet {
            defaultsStore.set(backgroundAgentPreference.rawValue, forKey: Self.backgroundAgentPreferenceKey)
            Task { await recordColdStartPreference(kind: "backgroundAgent", value: backgroundAgentPreference.rawValue) }
        }
    }
    @Published public private(set) var agents: [CascadeAgent] = []
    @Published public private(set) var personalizationSnapshot = PersonalizationSnapshot(
        eventCount: 0,
        routineProfileCount: 0,
        disabledSignatureCount: 0,
        disabledAppCount: 0,
        lastEventAt: nil
    )
    @Published public private(set) var answer: String = "Ask Cascade what happened in the local record."
    @Published public private(set) var conversation: [QATurn] = []
    @Published public private(set) var thinking = false
    @Published public private(set) var statusLine: String = "Starting Cascade."
    @Published public private(set) var hasAnthropicKey = false
    @Published public private(set) var keyMessage = "Claude key is not connected."
    @Published public private(set) var hasOpenAIKey = false
    @Published public private(set) var openAIKeyMessage = "OpenAI key is not connected (for GPT-Realtime voice)."
    @Published public private(set) var hasGroqKey = false
    @Published public private(set) var groqKeyMessage = "Groq key is not connected (for the cheaper Groq models)."
    @Published public private(set) var hasOpenRouterKey = false
    @Published public private(set) var openRouterKeyMessage = "OpenRouter key is not connected (for hosted UI-TARS grounding)."
    @Published public private(set) var visualGrounderRuntime = VisualGrounderRuntimeStatus(
        preset: GrounderRegistry.preset(id: nil),
        backend: "uitars",
        modelID: GUIGrounderModel.uiTars15_7b,
        endpoint: GrounderRegistry.defaultHostedEndpoint,
        coordSpace: .smartResize,
        probeStatus: "not run",
        lastMiniEvalScore: nil
    )
    @Published public private(set) var permissionDiagnostics = PermissionProbe.diagnostics()
    @Published public private(set) var screenAgentReady = false
    @Published public private(set) var screenAgentMessage = "Checking real-screen driver health."
    @Published public private(set) var agentRunning = false
    @Published public private(set) var agentMessage = "Connect a Claude key and a goal, then watch Cascade use this Mac."
    @Published public private(set) var teachMessage = "Ask “where do I find X” and Cascade points at it on your screen."
    @Published public private(set) var voicePartialUtterance = ""
    @Published public private(set) var voicePartialAppHint: String?
    /// Teach-once: true while the user is demonstrating a task by hand for Cascade to
    /// turn into an agent. Recording is already always-on — this only BRACKETS a time
    /// range and reroutes any narration into the intent buffer.
    @Published public private(set) var teachingMode = false
    /// The live teaching banner ("Teaching — do the task…", "Saving…", or the
    /// nothing-repeatable result). Kept separate from `teachMessage` so the assist
    /// agent's status and the demonstration status never clobber each other.
    @Published public private(set) var teachStatus: String?
    /// The curated agent built from the last demonstration, awaiting the user's review
    /// in the preview sheet (nil = no sheet). They pick "Add to my agents" or "Send to
    /// manager" from there.
    @Published public var teachPreview: CuratedAgent?
    /// Demonstrations the employee chose to route to the MANAGER instead of adding
    /// directly — they surface in the manager's review queue alongside auto-detected
    /// workflows. In-memory for v1 (a taught recipe has no repeated waste behind it,
    /// so unlike auto-detected proposals it does not re-derive on relaunch).
    @Published public private(set) var taughtForReview: [CuratedAgent] = []
    /// When the demonstration started; the bracket's lower bound.
    private var teachStartedAt: Date?
    /// Everything the user narrated during the demonstration, in order — joined into
    /// the curator's `statedIntent` (their own words = the best naming signal).
    private var teachIntentBuffer: [String] = []

    /// The companion-cursor colorway (cursor, trail, ripple, and highlight marquee
    /// all follow it). Picked from the notch; persists across launches.
    @Published public var cursorTheme: CursorTheme {
        didSet {
            guidanceOverlay.setTheme(cursorTheme)
            defaultsStore.set(cursorTheme.rawValue, forKey: Self.cursorThemeKey)
        }
    }
    private static let cursorThemeKey = "cascade.cursorTheme"

    /// Power harness: lets the assist agent run shell commands, AppleScript, and
    /// file writes directly (read-only file tools are always on). Explicit
    /// Settings opt-in, default OFF; every call is audited verbatim and the
    /// destructive-command deny-list applies regardless.
    @Published public var powerHarnessEnabled: Bool {
        didSet { defaultsStore.set(powerHarnessEnabled, forKey: Self.powerHarnessKey) }
    }
    private static let powerHarnessKey = "cascade.powerHarness"
    @Published public var capturePrivacyPolicy: CapturePrivacyPolicy = .default {
        didSet {
            Self.persistCapturePrivacyPolicy(capturePrivacyPolicy, defaults: defaultsStore)
            recorder.updateCapturePolicy(capturePrivacyPolicy)
        }
    }
    private static let capturePrivacyPolicyKey = "cascade.capturePrivacyPolicy"
    static let experimentalExperienceLedgerKey = "cascade.experimentalExperienceLedger"
    static let experimentalEpisodeMiningKey = "cascade.experimentalEpisodeMining"
    static let experimentalParameterizedMiningKey = "cascade.experimentalParameterizedMining"
    static let experimentalSuggestionRankingKey = "cascade.experimentalSuggestionRanking"
    static let experimentalSkillConsolidationKey = "cascade.experimentalSkillConsolidation"
    static let experimentalModelCallCacheKey = "cascade.experimentalModelCallCache"
    static let experimentalStructuredContentKey = "cascade.experimentalStructuredContent"
    static let experimentalWorkGraphIndexKey = "cascade.experimentalWorkGraphIndex"
    static let experimentalGroundingVerifierKey = "cascade.experimentalGroundingVerifier"
    static let experimentalGroundingCacheKey = "cascade.experimentalGroundingCache"
    static let experimentalSearchRoutingKey = "cascade.experimentalSearchRouting"
    static let experimentalHistoryCompactionKey = "cascade.experimentalHistoryCompaction"
    static let experimentalHistoryCompactionTurnsKey = "cascade.experimentalHistoryCompactionTurns"
    static let experimentalActionChunkingKey = "cascade.experimentalActionChunking"
    nonisolated static let experimentalAutoRecallKey = "cascade.experimentalAutoRecall"
    nonisolated static let experimentalActionTrajectoryCacheKey = "cascade.experimentalActionTrajectoryCache"
    static let auditIntegrityEnforcementKey = "cascade.auditIntegrityEnforcement"
    static let valueHourlyRateKey = "cascade.value.hourlyRateUSD"
    static let valueMonthlyRunBudgetKey = "cascade.value.monthlyRunBudget"
    static let valueMonthlyActionBudgetKey = "cascade.value.monthlyActionBudget"
    static let valueMonthlyCostCentsBudgetKey = "cascade.value.monthlyCostCentsBudget"
    static let proactiveModeKey = "cascade.proactive.mode"
    static let suggestionTimingPreferenceKey = "cascade.personalization.suggestionTiming"
    static let backgroundAgentPreferenceKey = "cascade.personalization.backgroundAgent"

    static func experimentalModelCallCache(defaults: UserDefaults, store: CascadeStore? = nil) -> ModelCallCache? {
        defaults.bool(forKey: Self.experimentalModelCallCacheKey) ? ModelCallCache(store: store) : nil
    }

    static func experimentalGroundingCache(defaults: UserDefaults) -> GroundingCache? {
        defaults.bool(forKey: Self.experimentalGroundingCacheKey) ? GroundingCache() : nil
    }

    nonisolated static func experimentalActionTrajectoryCacheEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Self.experimentalActionTrajectoryCacheKey)
    }

    nonisolated static func experimentalAutoRecallEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Self.experimentalAutoRecallKey)
    }

    static func experimentalStructuredContentEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Self.experimentalStructuredContentKey)
    }

    static func experimentalWorkGraphIndexEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Self.experimentalWorkGraphIndexKey)
    }

    static func experimentalHistoryCompactionTurns(defaults: UserDefaults) -> Int {
        let configured = defaults.integer(forKey: Self.experimentalHistoryCompactionTurnsKey)
        return configured > 0 ? configured : ComputerUseAgent.historyCompactionRecentTurnDefault
    }

    private static func restoreCapturePrivacyPolicy(defaults: UserDefaults) -> CapturePrivacyPolicy {
        guard let data = defaults.data(forKey: capturePrivacyPolicyKey),
              let policy = try? CapturePrivacyPolicy.importJSONData(data) else { return .default }
        return policy
    }

    private static func persistCapturePrivacyPolicy(_ policy: CapturePrivacyPolicy, defaults: UserDefaults) {
        if let data = try? policy.exportedJSONData() {
            defaults.set(data, forKey: capturePrivacyPolicyKey)
        }
    }

    /// Thinking effort for the on-screen cursor agent — "medium" (Anthropic's
    /// benchmarked CU default) or "low". A runtime toggle, not a recompile, so
    /// the long-deferred low-vs-medium A/B is one switch in Settings; the new
    /// TTFT + assist.timing telemetry is what makes that A/B measurable. Default
    /// "medium" → zero behaviour change until the user flips it.
    @Published public var cuEffort: String {
        didSet { defaultsStore.set(cuEffort, forKey: Self.cuEffortKey) }
    }
    private static let cuEffortKey = "cascade.cuEffort"

    /// On-screen agent backend: "claude" (Opus computer-use) or "scout" (Llama 4
    /// Scout via Groq + the grounder). Read by `onScreenBackendIsScout()`.
    @Published public var onScreenBackend: String {
        didSet { defaultsStore.set(onScreenBackend, forKey: "cascade.onScreenBackend") }
    }
    /// Per-region Hamming threshold for "this action changed nothing on screen" —
    /// much tighter than the recorder's blink-tolerant dedup (`regionSkipThreshold`
    /// = 5). A dead click yields a near byte-identical frame; any real change
    /// shifts many bits, so a tight bound keeps a small SUCCESSFUL change from
    /// being mislabeled no-effect (the false positive that would make the agent
    /// undo/redo a step that actually worked).
    static let noEffectThreshold = 2

    public let store: CascadeStore
    public let driver: LocalMacDriver
    public let recorder: ContextRecorder
    public let dock: ControlDockModel
    public let hotkey: UseDeviceHotkeyMonitor
    /// ⌥⌃T starts/stops a Teach-once demonstration — the same monitor type as the
    /// use-device hotkey, just a different chord.
    public let teachHotkey: UseDeviceHotkeyMonitor
    private let orchestrator: CascadeOrchestrator
    private let keyStore = AnthropicKeyStore()
    private let openAIKeyStore = OpenAIKeyStore()
    private let groqKeyStore = GroqKeyStore()
    private let openRouterKeyStore = OpenRouterKeyStore()
    public let guidanceOverlay = GuidanceOverlayController()
    public let voice: RealtimeVoice
    public let pushToTalk = PushToTalkMonitor()
    /// Background agents running in the isolated web sandbox.
    @Published public private(set) var backgroundAgents: [BackgroundAgentRun] = []
    private var sandboxRuntimes: [UUID: BackgroundWebAgent] = [:]
    /// How many background web agents may run at once (each = a WKWebView + a CU loop).
    static let maxConcurrentSandboxAgents = 8
    private let sandboxBox = SandboxBoxController()
    private let elementLocator = ElementLocator()
    /// Per-app cheat sheets (tiptour-macos Markdown App Skills port): prompt
    /// instructions plus runtime policies, matched against the frontmost app.
    /// User files at App Support/Cascade/Skills override the bundled ones.
    private var appSkills: AppSkillRegistry
    private var previousGroundingAnchor: MixtureGrounder.VerifiedGroundingAnchor?
    private var groundingCandidateFailureCounts: [String: Int] = [:]
    private struct GroundingSelectionEvidence: Sendable {
        let app: String
        let target: String
        let source: GroundingSource
        let candidateID: String
        let confidence: Double
        let screenChanged: Bool
    }
    private var episodeGroundingSelections: [GroundingSelectionEvidence] = []
    private final class SparseAXProfileBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var profiles: [AXRuntimeProfile] = []

        func record(_ profile: AXRuntimeProfile) {
            lock.lock()
            profiles.append(profile)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            profiles.removeAll()
            lock.unlock()
        }

        func snapshot() -> [AXRuntimeProfile] {
            lock.lock()
            defer { lock.unlock() }
            return profiles
        }
    }
    private let episodeSparseAXProfiles = SparseAXProfileBuffer()
    /// Rolling conversation memory for the voice/hotkey assistant — follow-up
    /// questions resolve against it ("now reply to the first one").
    public let assistMemory = AssistMemory()
    /// Where the previous teach turn went, so a referential follow-up ("the second
    /// one too") inherits the route instead of being re-classified from scratch.
    private enum TeachRoute { case action, locate }
    private var lastTeachRoute: TeachRoute?
    /// Bumped by every new teach turn. Running assist loops check it each
    /// iteration and stand down when superseded — without this, the new turn's
    /// `runState.reset()` could revive a loop the barge-in just stopped, leaving
    /// two loops fighting over the same cursor.
    private var assistGeneration = 0
    /// Set when the agent used its highlight tool during the current run, so the
    /// end-of-task cleanup doesn't erase the box the user asked to see (it fades
    /// on the overlay's own timer instead).
    private var agentDidHighlight = false
    private var cancellables: Set<AnyCancellable> = []
    private var lastSettingsOpen = Date.distantPast
    private var lastNextActionOfferAt: Date?
    private var recentNextActionDismissals = 0
    private var loggedCuratedProposalKeys: Set<String> = []
    private var voicePartialAppHintSource = ""
    /// Tracks an explicit Pause so always-on auto-start doesn't immediately undo it.
    private var userPaused = false
    /// False in tests/headless: the model is built with an injected store +
    /// orchestrator and starts NO hardware — no CGEvent taps, no screen capture, no
    /// scheduler, no audio I/O — so the orchestration logic can be exercised in
    /// isolation. Production leaves it true and everything starts as before.
    private let startsSubsystems: Bool
    /// Injectable so tests get an ephemeral suite instead of polluting (and reading
    /// stale state from) the real `.standard` defaults. Production uses `.standard`.
    private let defaultsStore: UserDefaults
    private let learnedSkillDirectory: URL?
    private let modelCallCache: ModelCallCache?
    private let groundingCache: GroundingCache?
    private let recipeTargetCache = RecipeTargetCache()
    private let experimentalStructuredContent: Bool
    private let experimentalWorkGraphIndex: Bool
    private let visualGrounderOverride: (any VisualGrounder)?
    private let localRegionNarrowerOverride: (@Sendable (Data, String, Int, Int) async -> ElementRegion?)?
    private let actionCriticOverride: (any ActionCritic)?

    public init(
        store injectedStore: CascadeStore? = nil,
        orchestrator injectedOrchestrator: CascadeOrchestrator? = nil,
        defaults: UserDefaults = .standard,
        startsSubsystems: Bool = true,
        appSkills initialAppSkills: AppSkillRegistry? = nil,
        learnedSkillDirectory: URL? = nil,
        visualGrounderOverride: (any VisualGrounder)? = nil,
        localRegionNarrowerOverride: (@Sendable (Data, String, Int, Int) async -> ElementRegion?)? = nil,
        actionCriticOverride: (any ActionCritic)? = nil
    ) throws {
        self.startsSubsystems = startsSubsystems
        self.defaultsStore = defaults
        self.groundingCache = Self.experimentalGroundingCache(defaults: defaults)
        self.experimentalStructuredContent = Self.experimentalStructuredContentEnabled(defaults: defaults)
        self.experimentalWorkGraphIndex = Self.experimentalWorkGraphIndexEnabled(defaults: defaults)
        self.visualGrounderOverride = visualGrounderOverride
        self.localRegionNarrowerOverride = localRegionNarrowerOverride
        self.actionCriticOverride = actionCriticOverride
        self.appSkills = initialAppSkills ?? AppSkillRegistry.load()
        self.learnedSkillDirectory = learnedSkillDirectory
        self.voice = RealtimeVoice(audioEnabled: startsSubsystems)
        let initialCapturePolicy = Self.restoreCapturePrivacyPolicy(defaults: defaults)
        // Production store anchors its audit-chain head in the Keychain so
        // truncation/rewrite of the local audit log is detectable. Tests inject a
        // store and never hit this path.
        let store = try injectedStore ?? CascadeStore(auditAnchor: KeychainAuditAnchor())
        self.store = store
        self.modelCallCache = Self.experimentalModelCallCache(defaults: defaults, store: store)
        cursorTheme = defaults.string(forKey: Self.cursorThemeKey)
            .flatMap(CursorTheme.init(rawValue:)) ?? .green
        powerHarnessEnabled = defaults.bool(forKey: Self.powerHarnessKey)
        capturePrivacyPolicy = initialCapturePolicy
        // The "Cursor agent speed" picker was removed and CLAUDE.md puts effort:low
        // "off the table" (it makes the agent dumb), so pin medium — ignoring any
        // stale `cascade.cuEffort = "low"` a prior build's picker may have persisted.
        cuEffort = "medium"
        onScreenBackend = defaults.string(forKey: "cascade.onScreenBackend") ?? "claude"
        proactiveMode = defaults.string(forKey: Self.proactiveModeKey)
            .flatMap(ProactiveMode.init(rawValue:)) ?? .askFirst
        suggestionTimingPreference = defaults.string(forKey: Self.suggestionTimingPreferenceKey)
            .flatMap(SuggestionTimingPreference.init(rawValue:)) ?? .balanced
        backgroundAgentPreference = defaults.string(forKey: Self.backgroundAgentPreferenceKey)
            .flatMap(BackgroundAgentPreference.init(rawValue:)) ?? .askFirst
        dismissedWasteSignatures = Self.restoreSet(key: Self.dismissedWasteKey, defaults: defaults)
        dismissedNextActionOfferKeys = Self.restoreSet(key: Self.dismissedNextActionOffersKey, defaults: defaults)
        snoozedProactiveOfferKeys = Self.restoreSet(key: Self.snoozedProactiveOffersKey, defaults: defaults)
        alwaysOfferProactiveKeys = Self.restoreSet(key: Self.alwaysOfferProactiveKey, defaults: defaults)
        neverSuggestApps = Self.restoreSet(key: Self.neverSuggestAppsKey, defaults: defaults)
        onlyInCascadeApps = Self.restoreSet(key: Self.onlyInCascadeAppsKey, defaults: defaults)
        savedAgentsOnlyApps = Self.restoreSet(key: Self.savedAgentsOnlyAppsKey, defaults: defaults)
        dismissedLearningOpportunityKeys = Self.restoreSet(key: Self.dismissedLearningOpportunitiesKey, defaults: defaults)
        showOnboarding = !defaults.bool(forKey: Self.onboardedKey)
        recorder = ContextRecorder(
            store: store,
            options: ContextRecorder.Options(
                indexWorkGraph: true,
                structuredContent: experimentalStructuredContent,
                capturePolicy: initialCapturePolicy
            )
        )
        dock = ControlDockModel()
        hotkey = UseDeviceHotkeyMonitor()
        teachHotkey = UseDeviceHotkeyMonitor(hotkey: UseDeviceHotkey(
            keyCode: 17, requiredModifiers: [.control, .option], label: "Control-Option-T"))
        orchestrator = injectedOrchestrator ?? CascadeOrchestrator(
            store: store,
            recordAnswerer: RecordSearchAnswerer(
                store: store,
                includeStructuredContent: experimentalStructuredContent
            ),
            modelCallCache: modelCallCache
        )
        driver = LocalMacDriver(store: store)
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Stream newly recorded moments into the Reel live as the continuous
        // recorder captures them, without re-querying the whole table.
        recorder.$status
            .compactMap(\.latestContext)
            .removeDuplicates { $0.id == $1.id }
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] context in self?.ingestLiveMoment(context) }
            .store(in: &cancellables)
        dock.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        hotkey.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        hotkey.pressed
            .sink { [weak self] in
                self?.beginUseDeviceIntent(source: "hotkey")
            }
            .store(in: &cancellables)
        teachHotkey.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        teachHotkey.pressed
            .sink { [weak self] in
                self?.toggleTeaching()
            }
            .store(in: &cancellables)
        if startsSubsystems { hotkey.start(); teachHotkey.start() }
        // didSet doesn't fire during init — hand the restored theme to the overlay.
        guidanceOverlay.setTheme(cursorTheme)
        voice.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        voice.onUtterance = { [weak self] phrase in
            self?.teach(question: phrase)
        }
        voice.onPartialUtterance = { [weak self] partial in
            self?.handlePartialVoiceUtterance(partial)
        }
        // Barge-in: the user talking over the agent halts whatever it's doing.
        voice.onInterrupt = { [weak self] in
            self?.driver.runState.requestStop()
            self?.guidanceOverlay.hide()
        }
        pushToTalk.onPress = { [weak self] in
            self?.voice.beginTalking()
            // The user is about to ask for something on screen — warm the capture
            // pipeline AND the TLS connection to the API now, so neither the
            // screenshot nor the first model request pays a cold start when they
            // finish speaking.
            ScreenCaptureUtility.prewarm()
            AnthropicWarmup.prewarm()
        }
        pushToTalk.onRelease = { [weak self] in self?.voice.endTalking() }
        if startsSubsystems {
            pushToTalk.start()
            startScheduler()
        }
        dock.onStop = { [weak self] in
            guard let self else { return }
            self.driver.runState.requestStop()
            self.agentMessage = "Stopped. Control returned to you."
            Task { await self.driver.stop() }
        }
        refreshKeyStatus()
        if startsSubsystems { Task { await refreshAll() } }
    }

    public func refreshAll() async {
        do {
            refreshPermissionState()
            await refreshComputerUseHealth()
            contexts = try await store.recentContexts(limit: 80)
            let integrity = try await store.verifyAuditChain()
            auditIntegrityStatus = Self.auditIntegrityStatus(from: integrity)
            if trustedAuditHistoryForSensitiveAction() {
                audit = auditIntegrityEnforcementEnabled
                    ? try await store.recentChainedAudit(limit: 80)
                    : try await store.recentAudit(limit: 80)
            } else {
                audit = []
            }
            agents = try await orchestrator.agents()
            let trustedTraces = try await recentTrustedAuditTraces()
            await persistDerivedTraceRows(trustedTraces)
            await persistTraceFailureClusterMemories(from: trustedTraces)
            sloSnapshot = ReliabilityReport.sloSnapshot(from: trustedTraces)
            valueSummary = AgentValueSummary.from(
                agents: agents,
                traces: trustedTraces,
                hourlyRateUSD: valueHourlyRateUSD,
                budgets: valueBudgets
            )
            privacySummary = try await store.privacySummary(policy: capturePrivacyPolicy)
            personalizationSnapshot = (try? await store.personalizationSnapshot()) ?? personalizationSnapshot
            let personalizationEnabled = Self.enabledByDefault(defaultsStore, key: Self.experimentalSuggestionRankingKey)
            let episodeMiningEnabled = Self.enabledByDefault(defaultsStore, key: Self.experimentalEpisodeMiningKey)
            let parameterizedMiningEnabled = episodeMiningEnabled && defaultsStore.bool(forKey: Self.experimentalParameterizedMiningKey)
            let detectionReport = try await orchestrator.detectedWasteReport(
                webAppIdentity: Self.webAppIdentity,
                useEpisodeMining: episodeMiningEnabled,
                useParameterizedMining: parameterizedMiningEnabled
            )
            let rawDetectedWaste = detectionReport.results
            let preferenceModel = await suggestionPreferenceModel()
            var reviewableCount = 0
            if personalizationEnabled {
                detectedWaste = SuggestionRanker().rankDetectedWaste(rawDetectedWaste, using: preferenceModel)
                let reviewable = detectedWaste.filter { Self.isAutomatable($0, using: preferenceModel) }
                reviewableCount = reviewable.count
                let curated = await orchestrator.curate(reviewable)
                curatedWaste = Self.rankCuratedSuggestions(curated, using: preferenceModel)
                await recordCuratedProposalsShown(curatedWaste)
                await refreshProactiveNextActionOffer(now: Date())
            } else {
                detectedWaste = rawDetectedWaste
                // Only genuinely repeated, time-saving workflows (the automatable filter)
		                // reach the curator and the manager's review queue.
                let reviewable = detectedWaste.filter { Self.isAutomatable($0) }
                reviewableCount = reviewable.count
			                curatedWaste = await orchestrator.curate(reviewable)
			                proactiveNextActionOffer = nil
			                proactiveOffer = nil
			            }
            if parameterizedMiningEnabled {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "workflow.parameterized_mining",
                    detail: Self.parameterizedMiningAuditDetail(
                        detectionReport,
                        reviewableCount: reviewableCount,
                        curatedCount: curatedWaste.count,
                        managerPendingCount: taughtForReview.count + curatedWaste.count
                    )
                ))
            }
		            await refreshLearningOpportunities(from: detectedWaste)
		            statusLine = recorder.status.message
        } catch {
            auditIntegrityStatus = .verificationFailed(error.localizedDescription)
            if auditIntegrityEnforcementEnabled { audit = [] }
            statusLine = error.localizedDescription
        }
    }

    public func graphTimeline(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        limit: Int = 20,
        newestFirst: Bool = false
    ) async throws -> [WorkGraphTimelineEntry] {
        try await store.graphTimeline(
            kind: kind,
            canonicalValue: canonicalValue,
            limit: limit,
            newestFirst: newestFirst
        )
    }

    private static func auditIntegrityStatus(from status: AuditChainStatus) -> AuditIntegrityStatus {
        switch status {
        case .intact, .empty:
            .trusted(status)
        case .broken, .truncated, .unchained:
            .untrusted(status)
        }
    }

    private var auditIntegrityEnforcementEnabled: Bool {
        defaultsStore.bool(forKey: Self.auditIntegrityEnforcementKey)
    }

    private func trustedAuditHistoryForSensitiveAction() -> Bool {
        !auditIntegrityEnforcementEnabled || auditIntegrityStatus.isTrusted
    }

    private var untrustedAuditHistoryMessage: String {
        "Audit history is untrusted. Cascade disabled agents and harness actions until the audit log is repaired."
    }

    private func refuseUntrustedAuditHistory() {
        teachMessage = untrustedAuditHistoryMessage
        agentMessage = untrustedAuditHistoryMessage
        dock.show(title: "Audit history untrusted", detail: untrustedAuditHistoryMessage)
    }

    private var effectivePowerHarnessEnabled: Bool {
        powerHarnessEnabled && capturePrivacyPolicy.powerHarnessAvailable
    }

    private var valueHourlyRateUSD: Double {
        let value = defaultsStore.double(forKey: Self.valueHourlyRateKey)
        return value > 0 ? value : 75
    }

    private var valueBudgets: AgentValueBudgets {
        func positiveInt(_ key: String) -> Int? {
            let value = defaultsStore.integer(forKey: key)
            return value > 0 ? value : nil
        }
        return AgentValueBudgets(
            monthlyRunLimit: positiveInt(Self.valueMonthlyRunBudgetKey),
            monthlyActionLimit: positiveInt(Self.valueMonthlyActionBudgetKey),
            monthlyCostCentsLimit: positiveInt(Self.valueMonthlyCostCentsBudgetKey)
        )
    }

    private func recentTrustedAuditTraces(window: TimeInterval = 7 * 24 * 60 * 60) async throws -> [AgentTrace] {
        let status = try await store.verifyAuditChain()
        guard AgentAuditExportPackage.isTrusted(status) else { return [] }
        let end = Date()
        let start = end.addingTimeInterval(-window)
        let events = try await store.auditWindowForTraceAssembly(from: start, to: end, enableTraceAssembly: true)
        return AgentTraceBuilder.fromAuditEvents(events)
    }

    private func persistDerivedTraceRows(_ traces: [AgentTrace]) async {
        for trace in traces {
            let rows = trace.storageRows()
            _ = try? await store.upsertAgentTrace(rows.trace)
            for span in rows.spans {
                _ = try? await store.upsertAgentSpan(span)
            }
            let existingCosts = (try? await store.modelCosts(traceID: trace.traceID)) ?? []
            let existingCostSpanIDs = Set(existingCosts.map(\.spanID))
            for cost in rows.costs where !existingCostSpanIDs.contains(cost.spanID) {
                _ = try? await store.recordModelCost(cost)
            }
            let existingEvals = (try? await store.traceEvals(traceID: trace.traceID)) ?? []
            let existingEvalKeys = Set(existingEvals.map { "\($0.spanID ?? ""):\($0.evaluatorKind.rawValue):\($0.evaluatorName)" })
            for eval in rows.evals {
                let key = "\(eval.spanID ?? ""):\(eval.evaluatorKind.rawValue):\(eval.evaluatorName)"
                guard !existingEvalKeys.contains(key) else { continue }
                _ = try? await store.recordTraceEval(eval)
            }
        }
    }

    private func persistTraceFailureClusterMemories(from traces: [AgentTrace]) async {
        guard defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey) else { return }
        let candidates = ReliabilityReport.topFailureClusters(from: traces, minCount: 2).compactMap { $0.failureMemoryCandidate() }
        guard !candidates.isEmpty else { return }
        var existingHashes = Set((try? await store.agentFailureMemories(limit: 500).compactMap(\.recoveryEvidenceHash)) ?? [])
        for memory in candidates {
            guard let hash = memory.recoveryEvidenceHash, !existingHashes.contains(hash) else { continue }
            if let saved = try? await store.recordAgentFailureMemory(memory) {
                existingHashes.insert(hash)
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "agent.failure_memory.saved",
                    detail: Self.failureMemorySavedAuditDetail(saved)
                ))
            }
        }
    }

    @discardableResult
    private func refuseManagedPolicy(capability: String, reason: String) -> Bool {
        let detail = Self.policyDecisionAuditDetail(capability: capability, decision: "blocked", reason: reason)
        statusLine = "Managed policy blocked \(capability)."
        teachMessage = statusLine
        agentMessage = statusLine
        dock.show(title: "Managed policy", detail: statusLine)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "policy", action: "policy.enforced", detail: detail)) }
        return false
    }

    @discardableResult
    private func refuseBudgetStart(capability: String) -> Bool {
        let reason = valueSummary.budgetViolations.first ?? "budget_exhausted"
        let detail = Self.policyDecisionAuditDetail(capability: capability, decision: "blocked", reason: reason)
        statusLine = "Local budget blocked \(capability)."
        teachMessage = statusLine
        agentMessage = statusLine
        dock.show(title: "Budget reached", detail: statusLine)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "policy", action: "agent.budget.refused", detail: detail)) }
        return false
    }

    private func backgroundStartsAvailable(capability: String) -> Bool {
        guard !valueSummary.budgetExhausted else { return refuseBudgetStart(capability: capability) }
        return true
    }

    public func startRecording() {
        guard capturePrivacyPolicy.recordingAvailable else {
            recorder.pause()
            refuseManagedPolicy(capability: "recording", reason: "recording_unavailable")
            return
        }
        userPaused = false
        refreshPermissionState()
        recorder.start()
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "recording.resumed", detail: "source=manual"))
            await refreshAll()
        }
    }

    public func pauseRecording() {
        userPaused = true
        recorder.pause()
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "recording.paused", detail: "source=manual"))
            await refreshAll()
        }
    }

    /// Always-on: begin recording automatically whenever Screen Recording is
    /// granted (on launch and right after the user grants it), unless the user has
    /// explicitly paused. `recorder.start()` is idempotent, so repeated calls are
    /// safe.
    private func autoStartIfPermitted() {
        guard startsSubsystems, !userPaused,
              capturePrivacyPolicy.recordingAvailable,
              recorder.status.permissions.canRecordContext,
              !recorder.status.running else { return }
        recorder.start()
    }

    public func captureOnce() {
        guard capturePrivacyPolicy.recordingAvailable else {
            refuseManagedPolicy(capability: "capture_once", reason: "recording_unavailable")
            return
        }
        refreshPermissionState()
        recorder.captureOnce()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await refreshAll()
        }
    }

    /// The Reel chat. Replies briefly. Questions that refer to the current screen
    /// ("where is the send button", "show me X") point the companion cursor at the
    /// element AND reply; everything else is a brief grounded answer about the record.
    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if defaultsStore.bool(forKey: Self.experimentalSearchRoutingKey) {
            let routePlan = Self.routeIntentHeuristic(trimmed)
            if routePlan.routingIntent != .noSearch, routePlan.routingIntent != .action {
                if routePlan.candidateSources.first == .onScreen {
                    Task {
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "source.route",
                            detail: Self.sourceRouteAuditDetail(goal: trimmed, plan: routePlan, status: "chat")
                        ))
                    }
                    showOnScreen(trimmed)
                    return
                }
                answer = "Checking the right source…"
                thinking = true
                let history = conversation.suffix(4).map { (user: $0.question, assistant: $0.answer) }
                Task {
                    let routed = await answerChat(trimmed, routePlan: routePlan, history: Array(history))
                    answer = routed.text
                    conversation.append(QATurn(question: trimmed, answer: routed.text, citations: routed.citations))
                    assistMemory.remember(user: trimmed, assistant: routed.text, ok: routed.answered)
                    thinking = false
                }
                return
            }
        }

        if Self.refersToScreen(trimmed) {
            showOnScreen(trimmed)
            return
        }

        answer = "Searching your record…"
        thinking = true
        // Recent turns let "and after that?" follow-ups inherit context.
        let history = conversation.suffix(4).map { (user: $0.question, assistant: $0.answer) }
        Task {
            var result: String
            var citations: [CitedMoment] = []
            var answered = true
            do {
                let recordAnswer = try await orchestrator.askRecord(trimmed, conversation: Array(history))
                // Show the FULL answer in the text thread. brief() is the ~280-char
                // SPOKEN cap (voice replies stay short) — applying it here chopped
                // multi-item summaries mid-word ("2. **Keyn…") even though the chat
                // bubble is scrollable and has no line limit.
                result = recordAnswer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                citations = await orchestrator.citedMoments(recordAnswer.citedMomentIDs).map {
                    CitedMoment(id: $0.id, appName: $0.appName, capturedAt: $0.capturedAt, imagePath: $0.imagePath)
                }
            } catch {
                result = error.localizedDescription
                answered = false
            }
            answer = result
            conversation.append(QATurn(question: trimmed, answer: result, citations: citations))
            // One brain: the voice agent sees what was said in chat, and vice
            // versa. Errors stay short-lived context, never archived.
            assistMemory.remember(user: trimmed, assistant: result, ok: answered)
            thinking = false
        }
    }

    // MARK: - Citation → Reel jump

    /// When set, the Reel scrubs to the moment nearest this time (then clears).
    @Published public var reelJumpTarget: Date?

    /// Click a proof chip → see the actual recorded moment in the Reel.
    public func jumpToMoment(_ citation: CitedMoment) {
        searchQuery = ""
        selectedTab = .reel
        reelJumpTarget = citation.capturedAt
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "reel.jump", detail: "citation #\(citation.id)")) }
    }

    /// Jump the Reel to a recorded time — the Teach-once provenance chip's "show me
    /// the recording this agent was built from".
    public func jumpToReel(at date: Date) {
        searchQuery = ""
        selectedTab = .reel
        reelJumpTarget = date
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "reel.jump", detail: "teach provenance")) }
    }

    /// Captures the current screen, points the blue companion cursor at the element
    /// the user asked about, and adds a brief reply to the chat. Falls back to a text
    /// answer when there's no key or no screen access.
    private func showOnScreen(_ q: String) {
        thinking = true
        answer = "Looking at your screen…"
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        Task {
            defer { thinking = false }
            guard hasAnthropicKey else {
                await answerAsText(q)
                return
            }
            guard let screen else {
                conversation.append(QATurn(question: q, answer: "Grant Screen Recording so I can see your screen."))
                return
            }
            let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
                conversation.append(QATurn(question: q, answer: "Grant Screen Recording so I can see your screen."))
                return
            }
            let guidance = await elementLocator.guide(
                screenshot: shot,
                question: q,
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height),
                conversation: assistMemory.historyForAPI()
            )
            if let local = guidance.point {
                let global = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
                guidanceOverlay.present(atGlobalPoint: global, label: "this one")
                assistMemory.rememberPointed(label: q, globalPoint: global)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "reel.point", detail: Self.textAuditDetail("question", q)))
            } else {
                guidanceOverlay.hide()
            }
            conversation.append(QATurn(question: q, answer: Self.brief(guidance.speech)))
            // One brain: chat pointing lands in the same memory the voice agent uses.
            assistMemory.remember(user: q, assistant: Self.brief(guidance.speech), ok: guidance.point != nil)
        }
    }

    private func answerAsText(_ q: String) async {
        let result = (try? await orchestrator.ask(q)) ?? "I couldn't answer that from the local record."
        conversation.append(QATurn(question: q, answer: Self.brief(result)))
    }

    private func answerChat(
        _ question: String,
        routePlan: SourcePlan,
        history: [(user: String, assistant: String)]
    ) async -> (text: String, citations: [CitedMoment], answered: Bool) {
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "source.route",
            detail: Self.sourceRouteAuditDetail(goal: question, plan: routePlan, status: "chat")
        ))
        let evidence = await collectEvidence(for: routePlan)
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "source.evidence",
            detail: Self.sourceEvidenceAuditDetail(evidence)
        ))
        for source in routePlan.candidateSources {
            switch source {
            case .onScreen:
                return ("I need the live screen for that; ask again with the screen visible.", [], false)
            case .recordedMemory:
                do {
                    let recordAnswer = try await orchestrator.askRecord(question, conversation: history, sourcePlan: routePlan)
                    guard !recordAnswer.text.hasPrefix("source-mismatch:") else { continue }
                    let citations = await orchestrator.citedMoments(recordAnswer.citedMomentIDs).map {
                        CitedMoment(id: $0.id, appName: $0.appName, capturedAt: $0.capturedAt, imagePath: $0.imagePath)
                    }
                    return (recordAnswer.text.trimmingCharacters(in: .whitespacesAndNewlines), citations, true)
                } catch {
                    continue
                }
            case .localFiles:
                if evidence.evidenceBySource[.localFiles]?.state == .checkedSupported,
                   let text = evidence.textBySource[.localFiles]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    return (String(text.prefix(1800)), [], true)
                }
            case .web:
                if capturePrivacyPolicy.backgroundWebRunsAvailable, hasAnthropicKey {
                    let started = createSandboxAgent(task: "Find and answer: \(question)")
                    if started {
                        return ("I started a background web check for that.", [], true)
                    }
                }
                return ("That needs web access, but background web is unavailable right now.", [], false)
            case .action:
                continue
            }
        }
        return (evidence.hasEvidence ? evidence.findingText : "I couldn't find supporting evidence in the routed sources.", [], evidence.hasEvidence)
    }

    /// Whether a chat question is about the *current screen* (point the cursor) vs.
    /// the *recorded past* (answer as text). Retrospective phrasing wins so that
    /// "what did I do today" is never mistaken for a screen command.
    private static func refersToScreen(_ text: String) -> Bool {
        let t = text.lowercased()
        let retrospective = ["what did", "what was", "what have", "did i ", "summar", "recap",
                             "today", "yesterday", "earlier", "this week", "last week", "history", "happened"]
        if retrospective.contains(where: { t.contains($0) }) { return false }
        let screenReferring = ["where", "show me", "show the", "find ", "which ", "point", "take me to",
                              "locate", "highlight", "how do i", "how can i", "open ", "click", "button",
                              "menu", "icon", " tab", "field", "on screen", "on my screen", "this screen"]
        return screenReferring.contains { t.contains($0) }
    }

    /// Caps a reply so the chat stays brief even if a provider rambles.
    private static func brief(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 280 else { return trimmed }
        return String(trimmed.prefix(280)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public func beginUseDeviceIntent(source: String = "manual") {
        selectedTab = .reel
        dock.show(
            title: "Cascade is listening",
            detail: "Say or type what you want done — Esc stops it at any time."
        )
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "device.intent", detail: source))
            await refreshAll()
        }
    }

    /// Captures the current screen (excluding Cascade's own windows), asks Claude's
    /// Computer Use tool *where* the target is, and flies the blue companion cursor
    /// to it. If the request was a command ("open / click / do X"), it also
    /// **performs the click** (gated on Accessibility + Input Monitoring); otherwise
    /// it just points and explains ("where / how / show me X").
    /// Spawns a background agent that carries out `task` inside the isolated web
    /// sandbox (its own hidden browser), streaming progress to a small watch box —
    /// the user keeps using their Mac while it works.
    /// Returns true if a background agent actually started — false if the request was
    /// refused (too vague, no key, or the concurrency cap). The scheduler relies on
    /// this so a cap-refusal doesn't consume the agent's daily slot.
    @discardableResult
    public func createSandboxAgent(task: String, forAgent agentID: Int64? = nil) -> Bool {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capturePrivacyPolicy.backgroundWebRunsAvailable else {
            return refuseManagedPolicy(capability: "background_web_run", reason: "background_web_runs_unavailable")
        }
        if let reason = capturePrivacyPolicy.deniedURLReason(in: trimmed) {
            return refuseManagedPolicy(capability: "background_web_run", reason: reason)
        }
        guard backgroundStartsAvailable(capability: "background_web_run") else { return false }
        // Too vague to act on — ask rather than letting the agent wander (e.g. off
        // googling "how to create an agent"). Also catch a topic-LESS request — a bare
        // verb ending in a dangling preposition ("research about", "look up", "find")
        // where the voice trailed off — which otherwise runs and "completes" instantly.
        let words = trimmed.lowercased().split(separator: " ")
        let danglingTail: Set<String> = ["about", "for", "on", "regarding", "of", "at", "into", "to", "the", "a", "an", "up", "out"]
        let topicless = words.count < 2 || (words.last.map { danglingTail.contains(String($0)) } ?? true)
        if trimmed.count < 5 || topicless {
            teachMessage = "What should the background agent actually do? e.g. \"in the background, find the cheapest flight to Tokyo next month.\""
            voice.speak("What should the background agent research or do?")
            return false
        }
        guard hasAnthropicKey else {
            teachMessage = "Connect your Claude key in Settings first."
            showSettings = true
            return false
        }
        guard trustedAuditHistoryForSensitiveAction() else {
            refuseUntrustedAuditHistory()
            return false
        }
        // Each agent owns a live WKWebView + a Computer Use loop; cap how many run at
        // once so the box stack and resource use stay sane. Refuse rather than queue —
        // the user can stop one and retry.
        guard sandboxRuntimes.count < Self.maxConcurrentSandboxAgents else {
            teachMessage = "Already running \(sandboxRuntimes.count) background agents — stop one before starting another."
            voice.speak("I'm already running a few background agents. Stop one first.")
            return false
        }
        let id = UUID()
        let runtime = configuredBackgroundWebAgent(id: id, attachCursor: true)
        sandboxRuntimes[id] = runtime
        backgroundAgents.insert(BackgroundAgentRun(id: id, task: trimmed, agentID: agentID), at: 0)
        teachMessage = "Running in the background: \(trimmed)"
        assistMemory.remember(user: trimmed, assistant: "Started a background agent on it.")
        voice.speak("On it. I'll handle that in the background.")
        sandboxBox.show(id, webView: runtime.sandbox.webView, task: trimmed, onStop: { [weak self] in
            self?.stopSandboxAgent(id)
        }, onSteer: { [weak self] message in
            guard let self else { return }
            self.sandboxRuntimes[id]?.steer(message)
            // Audit the steer so its timing vs the agent's reaction is on the record.
            Task {
                _ = try? await self.store.appendAudit(AuditEvent(
                    actor: "employee",
                    action: "sandbox.steer",
                    detail: Self.sandboxSteerAuditDetail(runID: id, message: message)
                ))
            }
        })
        Task {
            await runtime.run(task: trimmed) { [weak self] update in
                self?.applySandboxUpdate(id, update)
            }
        }
        return true
    }

    private func configuredBackgroundWebAgent(id: UUID, attachCursor: Bool) -> BackgroundWebAgent {
        let runtime = BackgroundWebAgent(modelCallCache: modelCallCache)
        if attachCursor {
            runtime.onCursor = { [weak self] point in self?.sandboxBox.moveCursor(id, toPagePoint: point) }
        }
        runtime.auditTag = String(id.uuidString.prefix(8))
        runtime.onAudit = { [weak self] action, detail in
            guard let self else { return }
            Task {
                _ = try? await self.store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: action,
                    detail: String(detail.prefix(240))
                ))
            }
        }
        runtime.planningContextProvider = { [weak self] goal in
            guard let self else { return nil }
            let rendered = await self.contextPack(goal: goal, surface: .backgroundWeb, affordanceMode: .assist)
            return rendered.text.isEmpty ? nil : rendered.text
        }
        runtime.harnessTier = effectivePowerHarnessEnabled ? .full : .readOnly
        runtime.recallEnabled = capturePrivacyPolicy.recordRecallAvailable
        runtime.includeStructuredRecallContent = experimentalStructuredContent
        runtime.harnessProvider = { [weak self] name, input in
            guard let self else { return "Cascade is shutting down — stop." }
            guard self.trustedAuditHistoryForSensitiveAction() else { return self.untrustedAuditHistoryMessage }
            if RecordRecall.isRecallTool(name, includeStructuredContent: self.experimentalStructuredContent) {
                guard self.capturePrivacyPolicy.recordRecallAvailable else {
                    _ = try? await self.store.appendAudit(AuditEvent(
                        actor: "policy",
                        action: "policy.enforced",
                        detail: Self.policyDecisionAuditDetail(capability: "record_recall", decision: "blocked", reason: "record_recall_unavailable")
                    ))
                    return "Managed policy has disabled record recall for agents."
                }
                return await RecordRecall(store: self.store).perform(RecordRecall.Call(name: name, input: input))
            }
            guard let call = HarnessCall(name: name, input: input) else {
                return "Unknown harness tool “\(name)”."
            }
            if let reason = self.deniedURLReason(inHarnessInput: input) {
                _ = try? await self.store.appendAudit(AuditEvent(
                    actor: "policy",
                    action: "policy.enforced",
                    detail: Self.policyDecisionAuditDetail(capability: "harness_url", decision: "blocked", reason: reason)
                ))
                return "Managed policy blocked this site."
            }
            return await AgentHarness.perform(call, powerEnabled: self.effectivePowerHarnessEnabled)
        }
        return runtime
    }

    public func stopSandboxAgent(_ id: UUID) {
        // No-op if the run already finalized (e.g. Stop tapped during the box's brief
        // post-completion window) — otherwise we'd log a false "user stopped" against
        // a run that actually completed. The box is hidden by the tap handler anyway.
        guard sandboxRuntimes[id] != nil || backgroundAgents.contains(where: { $0.id == id }) else { return }
        let entry = backgroundAgents.first { $0.id == id }
        sandboxRuntimes[id]?.stop()
        sandboxRuntimes[id] = nil
        // Drop the entry now: a late "Stopped." update then finds no entry and is a
        // no-op, so the stop is never re-announced or mis-counted.
        backgroundAgents.removeAll { $0.id == id }
        sandboxBox.hide(id)
        Task {
            if defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey),
               let entry,
               let agentID = entry.agentID,
               let agent = try? await store.agent(id: agentID) {
                await recordTerminalAgentExperience(
                    for: agent,
                    update: BackgroundWebAgent.Update(status: "Stopped.", snapshotPNG: nil, url: "", done: true, result: nil),
                    fallbackGoal: entry.task
                )
            }
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "sandbox.stopped", detail: "user stopped a background agent"))
        }
    }

    private func applySandboxUpdate(_ id: UUID, _ update: BackgroundWebAgent.Update) {
        sandboxBox.updateStatus(id, update.status)
        guard update.done else { return }
        // The entry's presence is the "still live, not yet finalized" sentinel: a
        // stop removes it, so a late terminal update finds nothing and bails — no
        // double-report, no double-count.
        guard let entry = backgroundAgents.first(where: { $0.id == id }) else { return }

        // Sign-in wall: keep the entry AND the runtime so Continue resumes at the
        // pending part of the plan — earlier parts' findings intact.
        if update.needsLogin {
            let said = update.result ?? "Sign-in needed — open the box and log in."
            teachMessage = said
            voice.speak(said)
            sandboxBox.requestLogin(id, message: said) { [weak self] in
                guard let self, let runtime = self.sandboxRuntimes[id] else { return }
                Task { await runtime.resume { [weak self] update in self?.applySandboxUpdate(id, update) } }
            }
            return
        }

        _ = finishSandboxRun(id: id, entry: entry, update: update)
    }

    /// Terminal sandbox branch: finalize once, then drop the entry so
    /// `backgroundAgents` stays bounded across a long session.
    /// Returns the completion task so tests can await the shipped recording hook.
    @discardableResult
    func finishSandboxRun(id: UUID, entry: BackgroundAgentRun, update: BackgroundWebAgent.Update) -> Task<Void, Never> {
        let task = entry.task
        sandboxRuntimes[id] = nil
        backgroundAgents.removeAll { $0.id == id }
        // Stop, failure, or running out of steps report honestly and count NOTHING;
        // only a genuine completion says "done" and feeds the reclaimed-time math.
        let message = Self.sandboxCompletionMessage(for: update)
        teachMessage = message
        assistMemory.remember(user: "[background agent: \(task)]", assistant: message)
        voice.speak(message)
        let deployedAgentID = entry.agentID
        let completionTask = Task {
            await recordSandboxCompletion(deployedAgentID: deployedAgentID, update: update, task: task)
            if update.completed, deployedAgentID != nil { await refreshAll() }
        }
        // Leave the box up briefly so the user can glance at the result, then close it.
        Task { try? await Task.sleep(for: .seconds(5)); sandboxBox.hide(id) }
        return completionTask
    }

    /// The honest user-facing line for a finished/aborted background run: a genuine
    /// completion is announced as done; a stop, failure, or step-limit shows its own
    /// status instead of a fake "Finished in the background."
    static func sandboxCompletionMessage(for update: BackgroundWebAgent.Update) -> String {
        let detail = update.result.flatMap { $0.isEmpty ? nil : $0 } ?? update.status
        return update.completed ? "Background agent done — \(detail)" : detail
    }

    /// Records a background run's end. ONLY a genuine completion increments the run
    /// counter + audits `agent.run.completed` — a stop / failure / step-limit must
    /// never inflate the reclaimed-time math (the on-screen replay path, which gates
    /// `markAgentRun` on `!stoppedEarly`, counts the same way).
    func recordSandboxCompletion(deployedAgentID: Int64?, update: BackgroundWebAgent.Update, task: String) async {
        if update.completed, let deployedAgentID {
            await recordCompletedAgentRun(agentID: deployedAgentID, auditDetail: task)
        } else if defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey),
                  let deployedAgentID,
                  let agent = try? await store.agent(id: deployedAgentID) {
            await recordTerminalAgentExperience(for: agent, update: update, fallbackGoal: task)
        }
        let outcome = update.completed ? "completed" : "ended without completing"
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "sandbox.task",
            detail: Self.sandboxTaskAuditDetail(task: task, outcome: outcome, agentID: deployedAgentID)
        ))
    }

    func recordOnScreenAgentCompletion(_ agent: CascadeAgent) async {
        await recordCompletedAgentRun(agentID: agent.id, auditDetail: agent.name)
    }

    private func recordCompletedAgentRun(agentID: Int64, auditDetail: String) async {
        try? await store.markAgentRun(id: agentID)
        let agent = try? await store.agent(id: agentID)
        if defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey),
           let agent {
            await recordSuccessfulAgentExperience(for: agent, fallbackGoal: auditDetail)
        }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "agent.run.completed",
            detail: Self.completedRunAuditDetail(agentID: agentID, label: auditDetail)
        ))
        await appendPreferenceEvent(
            kind: .agentRunCompleted,
            reward: 0.7,
            surface: "agent.run",
            appName: agent?.apps.first,
            workflowSignature: agent?.signature,
            agentID: agentID,
            features: agent.map(Self.agentFeaturePayload) ?? ["candidateType": "savedAgent"],
            evidence: (agent.map(Self.agentEvidencePayload) ?? [:]).merging(["labelHash": Self.auditHash(auditDetail)]) { current, _ in current }
        )
    }

    private func recordSuccessfulAgentExperience(for agent: CascadeAgent, fallbackGoal: String) async {
        await recordAgentExperience(for: agent, fallbackGoal: fallbackGoal, outcome: .success, verificationSignal: .completed)
    }

    private func recordTerminalAgentExperience(
        for agent: CascadeAgent,
        update: BackgroundWebAgent.Update,
        fallbackGoal: String
    ) async {
        let classification = Self.sandboxExperienceClassification(for: update)
        let failureMemoryContext = Self.sandboxFailureMemoryContext(for: update, failureKind: classification.failureKind)
        await recordAgentExperience(
            for: agent,
            fallbackGoal: fallbackGoal,
            outcome: classification.outcome,
            failureKind: classification.failureKind,
            failureMemoryContext: failureMemoryContext
        )
    }

	    private func recordAgentExperience(
	        for agent: CascadeAgent,
        fallbackGoal: String,
        outcome: AgentExperienceOutcome,
        verificationSignal: AgentExperienceVerificationSignal? = nil,
        failureKind: CascadeMemory.AgentFailureKind? = nil,
        failureMemoryContext: FailureMemoryContext? = nil
    ) async {
	        let appName = Self.experienceAppName(for: agent)
	        let goalPattern = Self.experienceGoalPattern(for: agent, fallback: fallbackGoal)
	        let recipeSignature = Self.experienceRecipeSignature(for: agent)
	        let saved = try? await store.recordAgentExperience(AgentExperienceCase(
	            appName: appName,
	            goalPattern: goalPattern,
	            recipeSignature: recipeSignature,
	            outcome: outcome,
	            verificationSignal: verificationSignal,
	            failureKind: failureKind,
	            evidenceIDs: agent.evidenceIDs,
	            actionCount: agent.recipe.steps.count
	        ))
	        if saved?.outcome == .success, saved?.verificationSignal != nil {
	            let expired = (try? await store.recordAgentFailureCounterexample(
	                appName: appName,
	                goalPattern: goalPattern
	            )) ?? []
	            for memory in expired where memory.expiredAt != nil {
	                _ = try? await store.appendAudit(AuditEvent(
	                    actor: "agent",
	                    action: "agent.failure_memory.counterexample",
	                    detail: Self.failureMemoryCounterexampleAuditDetail(memory)
	                ))
	            }
	        }
	        if outcome == .failure, let failureKind, let failureMemoryContext {
	            await recordAgentFailureMemory(
                agent: agent,
                appName: appName,
                goalPattern: goalPattern,
                recipeSignature: recipeSignature,
                failureKind: failureKind,
                context: failureMemoryContext
            )
        }
    }

    private func recordAgentFailureMemory(
        agent: CascadeAgent,
        appName: String,
        goalPattern: String,
        recipeSignature: String,
        failureKind: CascadeMemory.AgentFailureKind,
        context: FailureMemoryContext
    ) async {
        let goalTokens = TrajectorySketch.normalizedGoalTokens(from: goalPattern).prefix(8)
        let firstBadAction = agent.recipe.steps.sorted { $0.order < $1.order }.first.map(Self.failureMemoryActionDescriptor)
        let target = agent.recipe.steps.lazy.compactMap { $0.targetDescriptor ?? $0.ocrAnchor }.first
        let memory = AgentFailureMemory(
            appName: appName,
            normalizedGoalTokens: Array(goalTokens),
            failureKind: failureKind,
            firstBadAction: firstBadAction,
            screenSignatureHash: Self.auditHash(recipeSignature),
            targetHash: target.map(Self.auditHash),
            stateSummary: context.stateSummary,
            repairHint: Self.failureMemoryRepairHint(for: failureKind),
            recoveryEvidenceHash: context.recoveryEvidenceHash
        )
	        if let saved = try? await store.recordAgentFailureMemory(memory) {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "agent.failure_memory.saved",
                detail: Self.failureMemorySavedAuditDetail(saved)
            ))
	        }
	    }

    struct FailureMemoryContext: Sendable, Equatable {
        let stateSummary: String
        let recoveryEvidenceHash: String
    }

    nonisolated static func sandboxFailureMemoryContext(
        for update: BackgroundWebAgent.Update,
        failureKind: CascadeMemory.AgentFailureKind?
    ) -> FailureMemoryContext? {
        guard let failureKind, failureKind != .unknown else { return nil }
        let detail = (update.result?.isEmpty == false ? update.result : nil) ?? update.status
        let lower = detail.lowercased()
        let externallyObserved =
            update.needsLogin
            || lower.contains("no effect")
            || lower.contains("unchanged")
            || lower.contains("stopped changing")
            || lower.contains("modal")
            || lower.contains("dialog")
            || lower.contains("sheet")
            || lower.contains("ran out of steps")
            || lower.contains("step limit")
            || lower.contains("verify")
            || lower.contains("verified")
            || lower.contains("couldn't open")
            || lower.contains("failed")
            || lower.contains("error")
            || lower.contains("unsafe")
            || lower.contains("guardrail")
            || lower.contains("refus")
        guard externallyObserved else { return nil }
        let summary = failureMemoryStateSummary(
            status: update.status,
            url: update.url,
            failureKind: failureKind
        )
        return FailureMemoryContext(
            stateSummary: summary,
            recoveryEvidenceHash: auditHash("\(failureKind.rawValue)|\(summary)")
        )
    }

    nonisolated static func failureMemoryStateSummary(
        status: String,
        url: String,
        failureKind: CascadeMemory.AgentFailureKind
    ) -> String {
        let host = URL(string: url)?.host() ?? ""
        let redactedStatus = PIIDetector.redact(status).redacted
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["failureKind=\(safeAuditToken(failureKind.rawValue))"]
        if !host.isEmpty { parts.append("host=\(safeAuditToken(host))") }
        if !redactedStatus.isEmpty {
            parts.append("status=\(String(redactedStatus.prefix(120)))")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func sandboxExperienceClassification(
        for update: BackgroundWebAgent.Update
    ) -> (outcome: AgentExperienceOutcome, failureKind: CascadeMemory.AgentFailureKind?) {
        guard !update.completed else { return (.success, nil) }
        let failureKind = sandboxExperienceFailureKind(for: update)
        switch failureKind {
        case .unsafeAction:
            return (.refusal, failureKind)
        case .userStop:
            return (.userStop, failureKind)
        default:
            return (.failure, failureKind)
        }
    }

    nonisolated static func sandboxExperienceFailureKind(for update: BackgroundWebAgent.Update) -> CascadeMemory.AgentFailureKind {
        let detail = (update.result?.isEmpty == false ? update.result : nil) ?? update.status
        let lower = detail.lowercased()
        if update.needsLogin || lower.contains("needs_login") || lower.contains("sign in") || lower.contains("log in") {
            return .loginRequired
        }
        if lower.contains("no effect") || lower.contains("unchanged") || lower.contains("stopped changing") {
            return .noEffect
        }
        if lower.contains("refus") || lower.contains("unsafe") || lower.contains("guardrail") {
            return .unsafeAction
        }
        if lower.contains("modal") || lower.contains("dialog") || lower.contains("sheet") {
            return .modalBlocked
        }
        if lower.contains("ran out of steps")
            || lower.contains("step limit")
            || lower.contains("kept looking without making progress")
            || lower.contains("without making progress, so i stopped")
            || update.result != nil {
            return .stepLimit
        }
        if lower == "stopped." || lower.contains("user stopped") {
            return .userStop
        }
        if lower.contains("couldn't finish") || lower.contains("incomplete") || lower.contains("verify") {
            return .verifierRejected
        }
        if lower.contains("couldn't reach") || lower.contains("failed") || lower.contains("error") {
            return .toolError
        }
        return .unknown
    }

    nonisolated static func experienceFailureKind(
        for failure: AgentOrchestrator.AgentFailureKind
    ) -> CascadeMemory.AgentFailureKind {
        switch failure {
        case .wrongStartState:
            return .wrongStartState
        case .permissionMissing:
            return .permissionDenied
        case .secureInput:
            return .secureInput
        case .targetNotFound:
            return .targetNotFound
        case .groundingMiss, .lowConfidenceGrounding:
            return .groundingMiss
        case .noEffect, .effectMismatch:
            return .noEffect
        case .staleFrameBatch:
            return .staleFrameBatch
        case .unexpectedModal:
            return .modalBlocked
        case .verificationUnavailable:
            return .verificationUnavailable
        case .validatorIncomplete, .preconditionFailed, .verifierDisagreement:
            return .verifierRejected
        case .transportFailure:
            return .toolError
        case .unsafeActionRefused:
            return .unsafeAction
        case .parameterNeedsLiveValue:
            return .parameterNeedsLiveValue
        case .stepLimit:
            return .stepLimit
        case .timeout:
            return .timeout
        case .userStop:
            return .userStop
        case .artifactWrongLane:
            return .artifactWrongLane
        }
    }

    private static func experienceAppName(for agent: CascadeAgent) -> String {
        firstNonBlank(agent.apps.first, agent.recipe.steps.first?.appName, "Agent")
    }

    private static func experienceGoalPattern(for agent: CascadeAgent, fallback: String) -> String {
        firstNonBlank(agent.goal, fallback, agent.name, "completed agent run")
    }

    private static func experienceRecipeSignature(for agent: CascadeAgent) -> String {
        firstNonBlank(agent.signature, agent.name, "agent-\(agent.id)")
    }

    private static func failureMemoryActionDescriptor(_ step: RecipeStep) -> String {
        switch step.kind {
        case .activateApp:
            return "activate_app"
        case .click:
            return "click"
        case .doubleClick:
            return "double_click"
        case .rightClick:
            return "right_click"
        case .type:
            return "type"
        case .key:
            return "key"
        case .scroll:
            return "scroll"
        }
    }

    private static func failureMemoryRepairHint(for failureKind: CascadeMemory.AgentFailureKind) -> String {
        switch failureKind {
        case .targetNotFound, .groundingMiss:
            return "Re-ground on a visible control label or nearby role before acting; do not reuse the old target."
        case .noEffect:
            return "If the screen does not change, switch strategy: choose a different visible control, menu, or shortcut."
        case .wrongStartState, .staleFrameBatch:
            return "Confirm the frontmost app and starting screen before replaying the learned steps."
        case .verifierRejected:
            return "Check the visible end state before declaring done; continue until the requested result is present."
        case .verificationUnavailable:
            return "Prefer deterministic visible evidence before relying on narration."
        case .loginRequired:
            return "Stop and ask for sign-in instead of looping behind an authentication wall."
        case .modalBlocked:
            return "Handle or dismiss the blocking dialog before continuing with the task."
        case .permissionDenied, .secureInput:
            return "Respect the permission or secure-input boundary and ask the user to take over."
        case .unsafeAction:
            return "Do not perform the unsafe action; explain the boundary and offer a safer alternative."
        case .parameterNeedsLiveValue:
            return "Ask for or retrieve the current live value before filling the parameter."
        case .toolError, .timeout, .stepLimit, .userStop, .artifactWrongLane, .unknown:
            return "Slow down, verify each visible step, and stop instead of repeating an uncertain action."
        }
    }

    nonisolated static func failureMemorySavedAuditDetail(_ memory: AgentFailureMemory) -> String {
        [
            "id=\(memory.id)",
            "failureKind=\(safeAuditToken(memory.failureKind.rawValue))",
            "appHash=\(auditHash(memory.appName))",
            "goalTokenCount=\(memory.normalizedGoalTokens.count)",
            "targetHash=\(memory.targetHash ?? "none")",
            "retainedScore=\(String(format: "%.2f", memory.retainedScore))",
        ].joined(separator: " ")
    }

    nonisolated static func reflectionInjectAuditDetail(_ memory: AgentFailureMemory) -> String {
        [
            "status=saved",
            "id=\(memory.id)",
            "failureKind=\(safeAuditToken(memory.failureKind.rawValue))",
            "appHash=\(auditHash(memory.appName))",
            "goalTokenCount=\(memory.normalizedGoalTokens.count)",
            "firstActionHash=\(memory.firstBadAction.map(auditHash) ?? "none")",
            "targetHash=\(memory.targetHash ?? "none")",
            "stateHash=\(memory.stateSummary.map(auditHash) ?? "none")",
            "repairHintHash=\(auditHash(memory.repairHint))",
            "evidenceHash=\(memory.recoveryEvidenceHash ?? "none")",
        ].joined(separator: " ")
    }

    private static func firstNonBlank(_ values: String?...) -> String {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "unknown"
    }

    /// Did the user ask for a background agent ("create an agent…", "in the background",
    /// "in the sandbox")?
    private static func isBackgroundRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.range(of: #"\b(create|make|build|spin\s*up|run|start|set\s*up)\b.{0,16}\bagent\b"#,
                   options: .regularExpression) != nil { return true }
        return t.contains("in the background") || t.contains("background agent")
            || t.contains("in the sandbox") || t.contains("in a sandbox") || t.contains("local sandbox")
    }

    /// Recovers the actual task from a "create an agent that …" style request, robust
    /// to phrasing ("create me a background agent to …", "build an agent that …"). The
    /// trigger words must NOT leak into the task, or the agent ends up *researching*
    /// "how to create an agent" instead of doing the work.
    private static func backgroundTask(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the leading "(please) create/make/build (me) a(n) (background)(computer-use)
        // agent (that/to/which/for/and)" preamble, keeping everything after it.
        let preamble = #"^(?:hey\s+)?(?:cascade[,\s]+)?(?:can you\s+|could you\s+|please\s+|i(?:'?d like| want)(?:\syou)?\sto\s+|go ahead and\s+)?(?:create|make|build|spin\s*up|run|start|set\s*up)\s+(?:me\s+)?(?:a|an)?\s*(?:new\s+)?(?:background\s+)?(?:computer[-\s]?use\s+)?agent\b\s*(?:that\s+(?:can\s+|will\s+)?|to\s+|which\s+(?:can\s+|will\s+)?|for\s+|and\s+|:\s*)?"#
        if let range = t.range(of: preamble, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[range.upperBound...])
        }
        // Also strip the verb-less request form — "let / have / tell / get the agent
        // (to / that / which) …" — which the create-preamble above doesn't cover, so the
        // goal doesn't carry "let the agent …" cruft.
        let agentLet = #"^(?:hey\s+)?(?:cascade[,\s]+)?(?:can you\s+|could you\s+|please\s+|go ahead and\s+)?(?:let|have|tell|get|ask)\s+(?:the\s+|your\s+|our\s+)?agent\b\s*(?:to\s+|that\s+(?:can\s+|will\s+|should\s+)?|which\s+(?:can\s+|will\s+|should\s+)?|should\s+|and\s+)?"#
        if let range = t.range(of: agentLet, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[range.upperBound...])
        }
        // Remove sandbox/background qualifiers wherever they appear.
        let qualifiers = [
            "and let it work in the background", "let it work in the background",
            "run in the background", "in the background", "as a background agent", "background agent",
            "in the local sandbox", "in a local sandbox", "in the sandbox", "in a sandbox", "local sandbox",
        ]
        for phrase in qualifiers {
            t = t.replacingOccurrences(of: phrase, with: " ", options: .caseInsensitive)
        }
        let cleaned = t
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,")))
        return cleaned
    }

    private func handlePartialVoiceUtterance(_ partial: String) {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        voicePartialUtterance = trimmed
        teachStatus = "Listening - \(String(trimmed.prefix(80)))"
        ScreenCaptureUtility.prewarm()
        AnthropicWarmup.prewarm()
        if let hint = appSkills.appNamed(inGoal: trimmed) {
            voicePartialAppHint = hint
            voicePartialAppHintSource = trimmed
        }
    }

    private func appNameHint(forCompletedVoiceGoal goal: String) -> String? {
        let normalizedGoal = goal.lowercased()
        let normalizedSource = voicePartialAppHintSource.lowercased()
        if let hint = voicePartialAppHint,
           !normalizedSource.isEmpty,
           normalizedGoal.contains(normalizedSource) {
            return hint
        }
        return appSkills.appNamed(inGoal: goal)
    }

    public func teach(question: String) {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { teachMessage = "Ask where something is, or what to do."; return }
        // Teach-once: while demonstrating, the user narrates what they're doing.
        // Those words are the agent's INTENT — captured for the curator, never run as
        // a command. Buffer them and stand down; nothing launches mid-demonstration.
        if teachingMode {
            teachIntentBuffer.append(q)
            teachStatus = "Teaching — heard “\(q.prefix(48))”. Press ⌥⌃T to finish."
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.intent", detail: Self.textAuditDetail("intent", q))) }
            voice.done()
            return
        }
        // Voice gives us everything the user says — including acknowledgments
        // ("Sure!", "Ok.") and stop requests. Neither is a goal: an ack must not
        // supersede (and kill) a running task, and "stop" means STOP, not a new
        // run named "Stop". The audit log showed both arriving as tasks.
        let bare = q.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if Self.stopPhrases.contains(bare) {
            if assistTaskRunning {
                driver.runState.requestStop()
                teachMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: teachMessage)
            } else {
                teachMessage = "Nothing is running."
            }
            voice.done()
            return
        }
        if Self.acknowledgmentPhrases.contains(bare) {
            if !assistTaskRunning { teachMessage = q }
            voice.done()
            return
        }
        // Transcription noise gate, structural: the mic hands teach() everything
        // it hears, and one-word interjections / filler sentences kept spawning
        // full runs — each superseding (killing) the real task ("Iii!" murdered
        // the 13:28Z Keynote run). Fragments are ignored; dangling lead-in
        // filler ("And create…") is stripped so the command underneath survives.
        switch VoiceFragmentGate.classify(q) {
        case .noise:
            if !assistTaskRunning { teachMessage = "I heard “\(q.prefix(60))” — tell me the full task." }
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "voice.fragment.ignored", detail: Self.textAuditDetail("utterance", q))) }
            voice.done()
            return
        case .goal(let cleaned):
            q = cleaned
        }
        guard hasAnthropicKey else {
            teachMessage = "Connect your Claude key in Settings first."
            showSettings = true
            return
        }
        // "create an agent that … in the background" → run it in the isolated web
        // sandbox instead of taking over the screen.
        if Self.isBackgroundRequest(q) {
            createSandboxAgent(task: Self.backgroundTask(from: q))
            return
        }
        // A re-fired identical/near-identical command while a run is in flight is the
        // voice re-triggering the SAME goal — it must NOT supersede (kill) the run.
        // (Stop is handled above; a genuinely different command still supersedes.)
        // The audit showed the same "Open Keynote and design…" task re-firing ~4s in
        // and restarting the run at the chooser every time.
        if assistTaskRunning, let active = assistTaskGoal, Self.isSameGoal(q, active) {
            teachMessage = "Already on it — “\(active.prefix(40))”."
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "voice.duplicate.ignored", detail: Self.textAuditDetail("utterance", q))) }
            voice.done()
            return
        }
        // Every new turn supersedes whatever an earlier turn is still doing. The
        // token is captured HERE, synchronously, so a stale task suspended in an
        // await can never pick up the newer generation after resuming.
        assistGeneration += 1
        let gen = assistGeneration
        // "Click that / open it" right after Cascade pointed at something: act on
        // the remembered element instantly — no vision round-trip (openclicky's
        // last-pointed-element pattern).
        if Self.isBareReferentialClick(q), let pointed = assistMemory.freshPointed() {
            clickRememberedElement(pointed, utterance: q, gen: gen)
            return
        }
        // "What did I do today?" → answer from the local record; no screen driving.
        if Self.isRetrospective(q) {
            teachMessage = "Checking your record…"
            Task {
                let answer = Self.brief((try? await orchestrator.ask(q)) ?? "I couldn't answer that from the local record.")
                guard assistGeneration == gen else { return }
                assistMemory.remember(user: q, assistant: answer)
                teachMessage = answer
                voice.speak(answer)
                voice.done()
            }
            return
        }
        // A referential follow-up inside a live conversation keeps the previous
        // turn's route: "now do the second one" after an action stays an action even
        // though the words alone wouldn't classify as one.
        let referential = Self.isReferential(q) && assistMemory.isFollowUpWindowOpen()
        let wantsAction = Self.isActionRequest(q) || (referential && lastTeachRoute == .action)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        teachMessage = wantsAction ? "On it — looking at your screen…" : "Looking at your screen…"
        Task {
            // Capture once, directly at the model resolution, as JPEG — no OCR, no
            // full-resolution PNG. Every consumer (locator, agent episodes) declares
            // this exact size, so the frame passes through to base64 untouched.
            let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
                teachMessage = "Grant Screen Recording so Cascade can see your screen."
                voice.speak("I need Screen Recording permission to see your screen.")
                voice.done()
                return
            }
            guard assistGeneration == gen else { return }  // superseded while capturing

            // Commands ("open X and do Y") run as a multi-step Computer Use loop so
            // Cascade finishes the whole task, not just the first click. Questions
            // ("where / how / show me X") stay single-shot: point and explain.
            if wantsAction {
                lastTeachRoute = .action
                await runAssistTask(goal: q, screen: screen, firstScreenshotPNG: shot, gen: gen)
                return
            }
            lastTeachRoute = .locate

            // "Where do I find/do X" → frame the region with the dashed marquee.
            let region = await locateRegionGrounded(
                screenshot: shot,
                question: q,
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height),
                conversation: assistMemory.historyForAPI()
            )
            guard assistGeneration == gen else { return }  // superseded while locating
            guard let local = region.rect else {
                // Not on the current screen — don't give up. Navigate (open the app/menu/
                // tab, scroll) to surface it, then frame it.
                await findAndReveal(question: q, screen: screen, firstScreenshotPNG: shot, gen: gen)
                return
            }

            let globalRect = CGRect(
                x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                width: local.width, height: local.height
            )
            guidanceOverlay.highlight(globalRect: globalRect)
            guidanceOverlay.present(atGlobalPoint: CGPoint(x: globalRect.midX, y: globalRect.midY), label: "here")
            assistMemory.rememberPointed(label: q, globalPoint: CGPoint(x: globalRect.midX, y: globalRect.midY))
            assistMemory.remember(user: q, assistant: region.speech)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.region", detail: Self.textAuditDetail("question", q)))
            teachMessage = region.speech
            voice.speak(region.speech)
            voice.done()
            await refreshAll()
        }
    }

    /// Clicks the element Cascade just pointed at — the "click that" fast path.
    private func clickRememberedElement(_ pointed: AssistMemory.PointedElement, utterance: String, gen: Int) {
        guard trustedAuditHistoryForSensitiveAction() else {
            refuseUntrustedAuditHistory()
            voice.done()
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointed.globalPoint) }) ?? NSScreen.main else { return }
        let working = "Clicking what I pointed at…"
        teachMessage = working
        Task {
            guard assistGeneration == gen else { return }  // superseded
            driver.runState.reset()
            let local = CGPoint(x: pointed.globalPoint.x - screen.frame.minX, y: pointed.globalPoint.y - screen.frame.minY)
            let said: String
            let clicked = await executeCU(.click(x: local.x, y: local.y), on: screen)
            if clicked {
                said = "Done — clicked it."
            } else {
                // executeCU surfaces permission failures into teachMessage; STOP
                // leaves it untouched.
                said = teachMessage == working ? "Stopped." : teachMessage
            }
            assistMemory.remember(user: utterance, assistant: said, ok: clicked)
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "teach.clickPointed",
                detail: Self.teachPointedAuditDetail(utterance: utterance, label: pointed.label)
            ))
            teachMessage = said
            voice.speak(said)
            voice.done()
        }
    }

    /// "Click that / open it / press that one" — referential commands that act on
    /// the element Cascade last pointed at, with no new target named.
    private static func isBareReferentialClick(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!"))
        let patterns = ["click that", "click it", "click there", "click this", "click that one",
                        "press that", "press it", "press that one", "open that", "open it",
                        "select that", "select it", "yes click", "tap that", "tap it"]
        return patterns.contains { t == $0 || t.hasSuffix($0) } && t.count <= 28
    }

    /// Does the utterance lean on the conversation ("it", "that one", "the first
    /// one", "now …") rather than naming its own target?
    private static func isReferential(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        let markers = [" it ", " that ", " them ", " those ", " this one", " that one",
                       " the first", " the second", " the third", " the last one",
                       " same ", " again ", " too ", " also ", " what about", " and the "]
        if markers.contains(where: { t.contains($0) }) { return true }
        return t.hasPrefix(" now ") || t.hasPrefix(" then ")
    }

    /// True while a screen-driving assist run is in flight — used to keep
    /// non-goals (acknowledgments) from superseding it and to route spoken
    /// stop requests to STOP instead of a new task.
    private var assistTaskRunning = false
    /// The goal of the in-flight run, so a re-fired identical command (the voice
    /// re-triggering the SAME task) doesn't supersede and restart it.
    private var assistTaskGoal: String?

    /// Whether two goals are the SAME command (an exact-ish voice re-fire of a
    /// running task), by word-set overlap. Only guards against a literally-identical
    /// command re-firing while a run is in flight; transcription-drift variants are
    /// NOT treated as the same (that "wording" approach was the wrong lever — the
    /// sudden stops aren't a re-fire problem). Both need ≥3 words. Pure + pinned.
    nonisolated static func isSameGoal(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let sa = words(a), sb = words(b)
        guard sa.count >= 3, sb.count >= 3 else { return false }
        let union = sa.union(sb).count
        return union > 0 && Double(sa.intersection(sb).count) / Double(union) >= 0.8
    }

    /// Utterances that mean "halt the run", never a goal.
    private static let stopPhrases: Set<String> = [
        "stop", "stop it", "stop that", "cancel", "cancel that", "never mind", "nevermind",
    ]

    /// Bare acknowledgments — conversational filler, never a task. The audit
    /// log showed "Sure!" and "Ok." arriving as goals and killing live runs.
    private static let acknowledgmentPhrases: Set<String> = [
        "ok", "okay", "k", "sure", "yes", "yep", "yeah", "thanks", "thank you",
        "cool", "nice", "good", "great", "perfect", "awesome", "alright", "all right",
    ]

    /// Carries out a spoken command across as many steps as it takes — open the app
    /// *and* do the thing — by driving Claude's Computer Use tool with a fresh
    /// screenshot after every action (observe → act → re-observe). Multi-part
    /// commands ("do X, then Y in another app") are split up front; each part runs
    /// as its own episode with its own step budget, and every finished part hands
    /// its one-line result to the next, so the orchestrator — not the model's stop
    /// reason — decides when the whole job is done. The blue companion cursor flies
    /// to each target so you can watch; STOP (and the caps) keep control with you,
    /// and every run is audited.
    private func runAssistTask(goal: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int) async {
        guard trustedAuditHistoryForSensitiveAction() else {
            refuseUntrustedAuditHistory()
            voice.done()
            return
        }
        driver.runState.reset()
        let traceRecorder = CascadeAgentTraceRecorder(store: store)
        let traceSnapshot = AppWindowObserver.snapshot()
        let traceContext = try? await traceRecorder.beginTrace(TraceStart(
            surface: "assist",
            title: "assist.task",
            goalHash: Self.auditHash(goal),
            appName: traceSnapshot.appName,
            bundleIdentifier: traceSnapshot.bundleIdentifier,
            metadata: ["runtime": "runAssistTask"]
        ))
        let rootTraceSpan: SpanContext?
        if let traceContext {
            rootTraceSpan = try? await traceRecorder.beginSpan(SpanStart(
                kind: .run,
                name: "assist.task",
                genAIOperation: "invoke_agent",
                appName: traceSnapshot.appName,
                attributes: ["goal.hash": Self.auditHash(goal)]
            ), in: traceContext)
        } else {
            rootTraceSpan = nil
        }
        assistTaskRunning = true
        assistTaskGoal = goal
        defer { assistTaskRunning = false; assistTaskGoal = nil }
        agentDidHighlight = false
        episodeAppActions = [:]
        episodeGroundingSelections = []
        episodeSparseAXProfiles.reset()
        ScreenCaptureUtility.prewarm()  // warm the capture pipeline for fast re-observes
        dock.show(title: "Cascade is doing it", detail: "\(goal) · press STOP to take control.")

        // Haiku keeps the up-front planning round-trip short, and trivially simple
        // commands skip the round-trip entirely — a one-part plan runs exactly like
        // the old single loop. The conversation memo lets the planner split
        // follow-ups ("now reply to the first one") against what just happened.
        let planningSnapshot = AppWindowObserver.snapshot()
        let planningContext = [
            assistMemory.contextMemo(),
            "Frontmost app: \(planningSnapshot.appName)\nWindow: \(planningSnapshot.windowTitle ?? "")",
            await planningPriorNote(for: goal, frontmostApp: planningSnapshot.appName),
        ].compactMap { $0 }.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
        let taskPlan: AgentTaskPlan
        if Self.isSinglePartCommand(goal) {
            taskPlan = AgentTaskPlan(originalTask: goal, subtasks: [AgentSubtask(task: goal)])
        } else {
            // Downgraded helper task: Groq llama-3.3-70b when a key is set, else
            // Anthropic haiku. Planning is text-only, so no Claude needed.
            let h = TextHelperModel.resolve()
            taskPlan = await AgentTaskPlanner(client: h.client, model: h.model, cache: modelCallCache).taskPlan(
                for: goal, in: .onScreen, conversationContext: planningContext
            )
        }
        var plan = taskPlan.subtasks
        let searchRoutingEnabled = defaultsStore.bool(forKey: Self.experimentalSearchRoutingKey)
        var routeHints: [String: SearchRouteHint] = [:]
        if searchRoutingEnabled {
            let h = TextHelperModel.resolve()
            let router = AgentTaskPlanner(client: h.client, model: h.model, cache: modelCallCache)
            for subtask in plan {
                let fallback = Self.routeIntentHeuristic(subtask.task)
                guard Self.routeNeedsSourceEvidence(fallback) else { continue }
                let routed = await router.routeSearch(
                    for: subtask.task,
                    in: .onScreen,
                    conversationContext: planningContext
                )
                let routeHint = Self.routeNeedsSourceEvidence(routed) ? routed : fallback
                routeHints[subtask.task] = routeHint
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "source.route",
                    detail: Self.sourceRouteAuditDetail(goal: subtask.task, plan: routeHint, status: "assist")
                ))
            }
        }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "assist.plan",
            detail: Self.assistPlanAuditDetail(taskPlan)
        ))
        var findings: [(task: String, result: String)] = []
        var ranLongOn: String?
        var stalledOn: String?
        var interrupted = false
        var shot: Data? = firstScreenshotPNG
        var appliedSearchRoutingKeys = Set<String>()

        // All frames in this run are captured at the model resolution as JPEG and
        // pass through to base64 untouched.
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        func freshShot() async -> Data? {
            await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h)
        }

        // Beginning-latency fix (2026-06-11m forensics): single-part goals skip
        // the planner and lose the parts loop's app pre-open below — the model
        // then spent two turns (~8s) opening the app its own goal names. Open it
        // before the first frame instead, so turn 1 already sees it frontmost.
        if let first = plan.first, first.app.isEmpty,
           let named = appNameHint(forCompletedVoiceGoal: goal) {
            await executeCU(.openApp(named), on: screen)
            if let fresh = await freshShot() { shot = fresh }
        }

        var index = 0
        parts: while index < plan.count {
            if driver.runState.isStopRequested || assistGeneration != gen { interrupted = true; break }
            var sub = plan[index]
            let prefix = plan.count > 1 ? "Part \(index + 1)/\(plan.count) — " : ""
            var replannedCurrent = false

            subgoal: while true {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "assist.subgoal.start",
                    detail: Self.assistSubgoalAuditDetail(index: index, total: plan.count, subtask: sub, status: "start")
                ))

                let subRouteHint = routeHints[sub.task]
                if searchRoutingEnabled,
                   let routeHint = subRouteHint,
                   appliedSearchRoutingKeys.insert(Self.auditHash(sub.task)).inserted {
                    var localVerdict: SearchEvidenceVerdict?
                    if routeHint.usesCheapLocalSources {
                        let evidence = await collectEvidence(for: routeHint)
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "source.evidence",
                            detail: Self.sourceEvidenceAuditDetail(evidence)
                        ))
                        let verdict = await reviewEvidence(plan: routeHint, evidence: evidence)
                        localVerdict = verdict
                        if verdict == .sufficient {
                            findings.append((task: sub.task, result: evidence.findingText))
                            _ = try? await store.appendAudit(AuditEvent(
                                actor: "agent",
                                action: "assist.search.local",
                                detail: Self.assistSearchUngatedAuditDetail(goal: sub.task, routeHint: routeHint, status: "local_sufficient")
                            ))
                            index += 1
                            break subgoal
                        }
                        if evidence.hasEvidence {
                            sub = AgentSubtask(
                                task: "\(sub.task)\n\nLocal evidence already checked; use it as context and search another source only if needed:\n\(evidence.findingText)",
                                startURL: sub.startURL,
                                app: sub.app,
                                web: sub.web,
                                note: sub.note,
                                expectedEffects: sub.expectedEffects,
                                risk: sub.risk
                            )
                            plan[index] = sub
                        }
                    }
                    let shouldUseWeb = Self.shouldPreferBackgroundWeb(routeHint: routeHint)
                        || localVerdict.map { Self.shouldEscalateSearchToWeb(routeHint: routeHint, verdict: $0) } == true
                    if shouldUseWeb {
                        switch await runAssistBackgroundWebSearch(subtask: sub, routeHint: routeHint) {
                        case .finding(let finding):
                            findings.append((task: finding.task, result: finding.result))
                            index += 1
                            break subgoal
                        case .pause(let reason):
                            findings.append((task: sub.task, result: reason))
                            stalledOn = sub.task
                            break parts
                        case .unavailable:
                            if Self.webRequired(routeHint) {
                                let reason = "This subtask needs web evidence, but background web is unavailable right now."
                                findings.append((task: sub.task, result: reason))
                                stalledOn = sub.task
                                break parts
                            }
                            break
                        }
                    }
                }

                // Jump straight to the part's app or site — instant, no vision round-trip.
                if !sub.app.isEmpty {
                    await executeCU(.openApp(sub.app), on: screen)
                    shot = nil
                } else if !sub.startURL.isEmpty {
                    await executeCU(.openURL(sub.startURL), on: screen)
                    shot = nil
                }
                if shot == nil {
                    try? await Task.sleep(for: .milliseconds(260))
                    shot = await freshShot()
                }
                guard let episodeShot = shot else {
                    teachMessage = "I lost sight of the screen — try again."
                    interrupted = true
                    break parts
                }

                var attempt = await runAssistEpisode(
                    goal: AgentTaskPlanner.goal(for: sub, index: index, total: plan.count, job: goal, findings: findings, firmer: false),
                    prefix: prefix, screen: screen, firstScreenshotPNG: episodeShot, gen: gen,
                    routeHint: subRouteHint
                )
                // The model replied without doing anything — usually narration or a
                // question. One firmer retry on a fresh frame; its answer stands.
                if case .finished(_, let acted) = attempt, !acted, !driver.runState.isStopRequested, assistGeneration == gen,
                   let retryShot = await freshShot() {
                    attempt = await runAssistEpisode(
                        goal: AgentTaskPlanner.goal(for: sub, index: index, total: plan.count, job: goal, findings: findings, firmer: true),
                        prefix: prefix, screen: screen, firstScreenshotPNG: retryShot, gen: gen,
                        routeHint: subRouteHint
                    )
                }

                switch attempt {
                case .finished(let text, _):
                    let forceValidator = plan.count > 1 || sub.risk == .high || Self.onScreenBackendIsScout()
                    let verification = await verifyAssistSubgoal(
                        subtask: sub,
                        claimed: text,
                        screen: screen,
                        forceValidator: forceValidator
                    )
                    if verification.passed {
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "assist.subgoal.verify",
                            detail: Self.assistSubgoalAuditDetail(index: index, total: plan.count, subtask: sub, status: "passed")
                        ))
                        findings.append((task: sub.task, result: text))
                        index += 1
                        break subgoal
                    }

                    let reason = verification.reason ?? "subgoal evidence did not match the expected effect"
                    _ = try? await store.appendAudit(AuditEvent(
                        actor: "agent",
                        action: "assist.subgoal.fail",
                        detail: Self.assistSubgoalAuditDetail(
                            index: index,
                            total: plan.count,
                            subtask: sub,
                            status: "failed",
                            failureKind: verification.failureKind,
                            reason: reason
                        )
                    ))
                    let recovery = Self.recoveryAction(for: verification.failureKind, attempt: 1)
                    await recordAssistRecoveryMemory(
                        goal: goal,
                        subtask: sub,
                        failureKind: verification.failureKind,
                        reason: reason,
                        recovery: recovery
                    )
                    if !replannedCurrent, Self.shouldReplanAssistSubgoal(failureKind: verification.failureKind) {
                        let memo = AgentRecoveryMemo(
                            failedSubtask: sub,
                            failureKind: verification.failureKind,
                            attemptedRecovery: recovery,
                            targetHash: Self.auditHash(sub.task),
                            stateSummary: reason,
                            evidenceSummary: "claimed=\(String(text.prefix(180)))",
                            completedFindings: findings.map { AgentTaskFinding(task: $0.task, result: $0.result) }
                        )
                        let h = TextHelperModel.resolve()
                        let decision = await AgentTaskPlanner(client: h.client, model: h.model, cache: modelCallCache).replan(
                            originalTask: goal,
                            memo: memo,
                            environment: .onScreen,
                            conversationContext: assistMemory.contextMemo()
                        )
                        switch decision {
                        case .replaceCurrent(let replacement):
                            plan[index] = replacement
                            sub = replacement
                            replannedCurrent = true
                            shot = nil
                            _ = try? await store.appendAudit(AuditEvent(
                                actor: "agent",
                                action: "assist.subgoal.replan",
                                detail: Self.assistSubgoalAuditDetail(
                                    index: index,
                                    total: plan.count,
                                    subtask: replacement,
                                    status: "replace",
                                    failureKind: verification.failureKind,
                                    reason: reason
                                )
                            ))
                            continue subgoal
                        case .pause(let pauseReason):
                            stalledOn = sub.task
                            findings.append((task: sub.task, result: pauseReason))
                            break parts
                        }
                    }
                    findings.append((task: sub.task, result: reason))
                    stalledOn = sub.task
                    break parts
                case .stalled(let text):
                    // The part did NOT complete — moving on to the next part would
                    // build on a missing foundation. Stop here and say so honestly.
                    findings.append((task: sub.task, result: text))
                    stalledOn = sub.task
                    break parts
                case .stopped, .failed:
                    interrupted = true  // the episode already surfaced why
                    break parts
                case .stepLimit:
                    ranLongOn = sub.task
                    break parts
                }
            }
            shot = nil  // every later part observes a fresh frame
        }

        if !interrupted {
            let summary = AgentTaskPlanner.summary(findings: findings, skipped: [], ranLongOn: ranLongOn, stalledOn: stalledOn)
            teachMessage = summary
            // Don't say the same sentence twice — if the last progress line IS
            // the summary, the user already heard it.
            if summary.caseInsensitiveCompare(lastNarratedLine) != .orderedSame {
                voice.speak(summary)
            }
            lastNarratedLine = ""
            dock.show(title: ranLongOn == nil && stalledOn == nil ? "Done" : "Paused", detail: summary)
            assistMemory.remember(user: goal, assistant: summary)
            // A clean run in an app with no skill yet is exactly the material
            // skills are made of — draft one for the user to review.
            if ranLongOn == nil && stalledOn == nil { maybeDistillSkill(goal: goal, findings: findings) }
        } else {
            assistMemory.remember(user: goal, assistant: teachMessage, ok: false)
        }
        // Keep the agent's highlight up — erasing it at "Done" would defeat the
        // point of asking for it. The overlay fades it on its own timer.
        if !agentDidHighlight { guidanceOverlay.hide() }
        let traceFailure: AgentOrchestrator.AgentFailureKind? = interrupted ? .stepLimit : (ranLongOn != nil || stalledOn != nil ? .stepLimit : nil)
        let traceStatus: AgentStoredTraceStatus = traceFailure == nil ? .ok : .failed
        if let rootTraceSpan {
            try? await traceRecorder.endSpan(rootTraceSpan, SpanResult(
                status: traceStatus,
                failureKind: traceFailure,
                attributes: [
                    "subgoal.count": "\(plan.count)",
                    "subgoal.completed_count": "\(findings.count)",
                ]
            ))
        }
        if let traceContext {
            try? await traceRecorder.endTrace(traceContext, TraceResult(
                status: traceStatus,
                failureKind: traceFailure,
                metadata: [
                    "subgoal.count": "\(plan.count)",
                    "subgoal.completed_count": "\(findings.count)",
                ]
            ))
        }
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.task", detail: Self.textAuditDetail("goal", goal)))
        voice.done()
        await refreshAll()
    }

    private struct AssistSubgoalVerification: Sendable, Equatable {
        let passed: Bool
        let reason: String?
        let failureKind: AgentOrchestrator.AgentFailureKind
    }

    private func verifyAssistSubgoal(
        subtask: AgentSubtask,
        claimed: String,
        screen: NSScreen,
        forceValidator: Bool
    ) async -> AssistSubgoalVerification {
        let snapshot = AppWindowObserver.snapshot()
        var missing: [String] = []
        var ocrText: String?

        func visibleText() async -> String {
            if let ocrText { return ocrText }
            let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
                ocrText = ""
                return ""
            }
            let recognized = await ScreenTextRecognizer.recognize(inPNG: shot)
            ocrText = recognized
            return recognized
        }

        for effect in subtask.expectedEffects {
            switch effect {
            case .frontmostApp(let expected):
                if !Self.containsCaseInsensitive(snapshot.appName, expected) {
                    missing.append("frontmost app is not \(expected)")
                }
            case .windowTitleContains(let expected):
                let title = snapshot.windowTitle ?? ""
                if !Self.containsCaseInsensitive(title, expected) {
                    missing.append("window title does not contain \(expected)")
                }
            case .visibleText(let expected):
                let text = await visibleText()
                if !Self.containsCaseInsensitive(text, expected) {
                    missing.append("visible text does not include \(expected)")
                }
            case .urlContains(let expected):
                let pageText = await visibleText()
                let evidence = [snapshot.windowTitle ?? "", pageText].joined(separator: "\n")
                if !Self.containsCaseInsensitive(evidence, expected) {
                    missing.append("visible URL/title evidence does not include \(expected)")
                }
            case .artifactExists(let path):
                let expanded = (path as NSString).expandingTildeInPath
                if !FileManager.default.fileExists(atPath: expanded) {
                    missing.append("artifact is missing")
                }
            case .noUnexpectedModal:
                let title = (snapshot.windowTitle ?? "").lowercased()
                if title.contains("alert") || title.contains("dialog") || title.contains("permission") {
                    missing.append("unexpected modal may still be visible")
                }
            }
        }

        if !missing.isEmpty {
            return AssistSubgoalVerification(
                passed: false,
                reason: missing.joined(separator: "; "),
                failureKind: .validatorIncomplete
            )
        }
        if forceValidator || subtask.expectedEffects.isEmpty {
            if let reason = await validateAssistCompletion(goal: subtask.task, claimed: claimed, screen: screen, force: forceValidator) {
                return AssistSubgoalVerification(passed: false, reason: reason, failureKind: .validatorIncomplete)
            }
        }
        return AssistSubgoalVerification(passed: true, reason: nil, failureKind: .validatorIncomplete)
    }

    nonisolated static func containsCaseInsensitive(_ haystack: String, _ needle: String) -> Bool {
        let cleanNeedle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNeedle.isEmpty else { return true }
        return haystack.range(of: cleanNeedle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    nonisolated static func shouldReplanAssistSubgoal(failureKind: AgentOrchestrator.AgentFailureKind) -> Bool {
        switch failureKind {
        case .validatorIncomplete, .groundingMiss, .noEffect:
            return true
        default:
            return false
        }
    }

    private func recordAssistRecoveryMemory(
        goal: String,
        subtask: AgentSubtask,
        failureKind: AgentOrchestrator.AgentFailureKind,
        reason: String,
        recovery: RecoveryAction
    ) async {
        await recordReflectionFailureMemory(
            appName: Self.normalizedFrontmostApp(AppWindowObserver.snapshot().appName) ?? subtask.app,
            goal: goal,
            failureKind: Self.experienceFailureKind(for: failureKind),
            stateSummary: reason,
            repairHint: "Recovery rung: \(recovery.rawValue). Replan the current subgoal before advancing.",
            recoveryEvidenceSeed: "\(failureKind.rawValue)|\(recovery.rawValue)|\(reason)"
        )
    }

    private func recordReflectionFailureMemory(
        appName: String?,
        goal: String,
        failureKind: CascadeMemory.AgentFailureKind,
        firstBadAction: String? = nil,
        targetHash: String? = nil,
        stateSummary: String?,
        repairHint: String,
        recoveryEvidenceSeed: String? = nil
    ) async {
        guard defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey) else { return }
        guard let appName = Self.normalizedFrontmostApp(appName) else { return }
        let redactedGoal = PIIDetector.redact(goal).redacted
        let tokens = TrajectorySketch.normalizedGoalTokens(from: redactedGoal)
        guard !tokens.isEmpty else { return }
        let redactedAction = firstBadAction.map { String(PIIDetector.redact($0).redacted.prefix(120)) }
        let redactedState = stateSummary.map { String(PIIDetector.redact($0).redacted.prefix(180)) }
        let redactedHint = String(PIIDetector.redact(repairHint).redacted.prefix(240))
        let memory = AgentFailureMemory(
            appName: appName,
            normalizedGoalTokens: Array(tokens.prefix(10)),
            failureKind: failureKind,
            firstBadAction: redactedAction?.isEmpty == true ? nil : redactedAction,
            targetHash: targetHash,
            stateSummary: redactedState?.isEmpty == true ? nil : redactedState,
            repairHint: redactedHint,
            recoveryEvidenceHash: recoveryEvidenceSeed.map(Self.auditHash)
        )
        guard let saved = try? await store.recordAgentFailureMemory(memory) else { return }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "reflection.inject",
            detail: Self.reflectionInjectAuditDetail(saved)
        ))
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "agent.failure_memory.saved",
            detail: Self.failureMemorySavedAuditDetail(saved)
        ))
    }

    private enum AssistEpisodeOutcome {
        case finished(String, acted: Bool)
        /// The model talked itself out (three idle turns) without declaring the
        /// part done. NOT success: later parts must not run on top of it.
        case stalled(String)
        case stopped
        case stepLimit
        case failed
    }

    struct SourceEvidenceBundle: Sendable, Equatable {
        let query: String
        let sourcePlan: SourcePlan
        var evidenceBySource: [SourceID: SourceEvidence]
        var textBySource: [SourceID: String]

        init(query: String, sourcePlan: SourcePlan) {
            self.query = query
            self.sourcePlan = sourcePlan
            var evidence: [SourceID: SourceEvidence] = [:]
            for source in sourcePlan.candidateSources {
                evidence[source] = SourceEvidence.notChecked(source: source)
            }
            self.evidenceBySource = evidence
            self.textBySource = [:]
        }

        var hasEvidence: Bool {
            evidenceBySource.values.contains { $0.state == .checkedSupported }
        }

        var combinedText: String {
            sourcePlan.candidateSources.compactMap { source -> String? in
                guard let text = textBySource[source]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                let label: String
                switch source {
                case .recordedMemory: label = "Recorded memory"
                case .localFiles: label = "Local files"
                case .onScreen: label = "On-screen"
                case .web: label = "Web"
                case .action: label = "Action"
                }
                return "\(label):\n\(text)"
            }.joined(separator: "\n\n")
        }

        var findingText: String {
            let text = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "No local evidence found." }
            return String(text.prefix(1800))
        }

        mutating func set(_ evidence: SourceEvidence, text: String? = nil) {
            evidenceBySource[evidence.source] = evidence
            if let text {
                textBySource[evidence.source] = text
            }
        }
    }

    enum SearchEvidenceVerdict: String, Sendable, Equatable {
        case sufficient
        case insufficient
        case abstain

        static func parse(_ raw: String) -> SearchEvidenceVerdict {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let token = normalized.split { !$0.isLetter }.first.map(String.init) ?? normalized
            switch token {
            case "SUFFICIENT": return .sufficient
            case "INSUFFICIENT": return .insufficient
            case "ABSTAIN": return .abstain
            default: return .abstain
            }
        }
    }

    enum AssistBackgroundWebResult: Sendable, Equatable {
        case finding(AgentTaskFinding)
        case pause(String)
        case unavailable
    }

    /// Steps one Computer Use episode through a single part: observe → act →
    /// re-observe until the model finishes, the user stops it, or the step budget
    /// runs out. Returns the model's closing line plus whether it acted at all.
    /// Builds an on-screen assist agent at a given model. Factored out of
    /// `runAssistEpisode` so drift can rebuild on a stronger model mid-episode
    /// without duplicating the skill/harness/recall wiring. Handlers
    /// (streamSink / onThinkingPulse / onActionRefused) are set by the caller —
    /// they capture episode-local state.
    /// Skill provider shared by the Opus + Scout on-screen paths: resolve a skill by
    /// name, deny scripting playbooks unless the goal asks (the structural gate), and
    /// audit each pull.
    private func assistSkillProvider(goal: String) -> (String) -> String? {
        { [appSkills, store] name in
            guard let skill = appSkills.skill(named: name) else { return nil }
            if skill.explicitAskOnly && !AppSkill.goalAsksForScript(goal) {
                Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.skill.denied", detail: Self.textAuditDetail("skill", name))) }
                return """
                Skill \(skill.name) is unavailable for this task: it is a scripting \
                playbook and the user did not ask for a script. Do the work on \
                screen in the app's own UI — pull the app's other listed skills \
                instead. Do not write or run any script for this task: no script \
                editors, no shell, no writing files to open in the app.
                """
            }
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.skill", detail: Self.textAuditDetail("skill", name))) }
            return skill.promptBlock
        }
    }

    /// Harness + recall provider shared by both on-screen paths: recall tools route
    /// to performRecall (read-only memory); everything else to performHarness
    /// (file/shell, gated + audited).
    private func assistHarnessProvider(
        goal: String,
        gen: Int,
        onSearchToolCall: (@MainActor (String) -> Void)? = nil
    ) -> @MainActor (String, [String: Any]) async -> String {
        { [weak self] name, input in
            guard let self else { return "Cascade is shutting down — stop." }
            if RecordRecall.isRecallTool(name, includeStructuredContent: self.experimentalStructuredContent) {
                onSearchToolCall?(name)
                return await self.performRecall(name: name, input: input, gen: gen)
            }
            if AgentHarness.isReadOnlyTool(name) {
                onSearchToolCall?(name)
            }
            return await self.performHarness(name: name, input: input, goal: goal, gen: gen)
        }
    }

    private func makeAssistAgent(
        model: String,
        goal: String,
        gen: Int,
        onSearchToolCall: (@MainActor (String) -> Void)? = nil
    ) -> ComputerUseAgent {
        // Structural grounding split: when a grounder is configured (hosted UI-TARS
        // via OpenRouter, or Claude), Opus drives the screen by NAMING targets and
        // the runtime grounds each — the model never emits pixel coordinates. The
        // proven coordinate computer-tool path runs whenever no grounder is present
        // (no OpenRouter key) or the user opts out, so existing behaviour is intact.
        let grounder = assistGrounder(ownsGroundingCache: false)
        let mode: ComputerUseAgent.GroundingMode =
            (grounder != nil && Self.structuralGroundingEnabled()) ? .structural : .coordinate
        let agent = ComputerUseAgent(
            model: model,
            effort: cuEffort,
            environmentNote: ComputerUseAgent.foregroundBrowserNote + "\n\n" + AgentDateContext.line(),
            skillProvider: assistSkillProvider(goal: goal),
            // Direct-Mac tools beside the computer tool: find/read is always on;
            // run/script/write only with the user's Power harness opt-in.
            harnessTier: effectivePowerHarnessEnabled ? .full : .readOnly,
            harnessProvider: assistHarnessProvider(goal: goal, gen: gen, onSearchToolCall: onSearchToolCall),
            // Let the agent recall what the user already saw on screen — the whole
            // point of a context recorder. The same in-process tools the Ask panel
            // hunts the record with, so a retrospective goal resolves before acting.
            recallEnabled: capturePrivacyPolicy.recordRecallAvailable,
            includeStructuredRecallContent: experimentalStructuredContent,
            resourceCatalogEnabled: defaultsStore.bool(forKey: Self.experimentalSearchRoutingKey),
            // Grounding split: the grounder locates named targets. In structural
            // mode it backs click_target/fill_target/scroll (the model never emits
            // coordinates); in coordinate mode it backs the optional fill_target aid.
            grounder: grounder,
            groundingMode: mode,
            groundingCropProvider: Self.assistGroundingCropProvider(),
            groundingCache: groundingCache,
            groundingCacheKeyProvider: Self.assistGroundingCacheKeyProvider(),
            actionCritic: assistActionCritic(),
            historyCompactionEnabled: defaultsStore.bool(forKey: Self.experimentalHistoryCompactionKey),
            historyCompactionRecentTurns: Self.experimentalHistoryCompactionTurns(defaults: defaultsStore),
            actionChunkingEnabled: defaultsStore.bool(forKey: Self.experimentalActionChunkingKey)
        )
        // Pre-action safety gate (default OFF): refuse irreversible quit/trash keys
        // unless the goal asks. Set here so it re-applies when escalation rebuilds
        // the agent on Opus. Opt in via `cascade.guardIrreversibleActions`.
        agent.guardIrreversibleActions = capturePrivacyPolicy.forceIrreversibleActionGuard || Self.guardIrreversibleEnabled()
        agent.onUsage = { [store] usage in
            Task {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "assist.capture",
                    detail: Self.assistCaptureAuditDetail(usage)
                ))
            }
        }
        agent.onHistoryCompacted = { [store] audit in
            Task {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "history.compacted",
                    detail: Self.historyCompactedAuditDetail(audit)
                ))
            }
        }
        return agent
    }

    private static func assistGroundingCropProvider() -> @Sendable (CGRect, Int, Int) async -> GroundingCrop? {
        { rect, displayWidth, displayHeight in
            let normalized = normalizedTopLeftRect(
                displayLocalRect: rect,
                displayWidth: displayWidth,
                displayHeight: displayHeight
            )
            guard let jpeg = await ScreenCaptureUtility.captureCursorScreenZoomJPEG(normalizedRect: normalized) else {
                return nil
            }
            return GroundingCrop(screenshot: jpeg, displayBounds: rect)
        }
    }

    private static func assistGroundingCacheKeyProvider() -> ComputerUseAgent.GroundingCacheKeyProvider {
        { frame, target, displayWidthPoints, displayHeightPoints, mode in
            guard let gridHashes = Self.gridHashes(ofJPEG: frame) else { return nil }
            let snapshot = await MainActor.run { AppWindowObserver.snapshot() }
            return GroundingCacheKey(
                targetText: target,
                appName: snapshot.appName,
                bundleIdentifier: snapshot.bundleIdentifier,
                windowTitle: snapshot.windowTitle,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                screenHash: PerceptualHash.combinedHash(gridHashes),
                gridHashes: gridHashes,
                mode: mode
            )
        }
    }

    nonisolated static func normalizedTopLeftRect(
        displayLocalRect rect: CGRect,
        displayWidth: Int,
        displayHeight: Int
    ) -> CGRect {
        let width = CGFloat(max(1, displayWidth))
        let height = CGFloat(max(1, displayHeight))
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clamped.isNull, !clamped.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: clamped.minX / width,
            y: (height - clamped.maxY) / height,
            width: clamped.width / width,
            height: clamped.height / height
        )
    }

    private func recordGroundingNoEffect(from agent: ComputerUseAgent) {
        guard let id = agent.lastGroundCandidateID,
              let source = agent.lastGroundSource,
              let confidence = agent.lastGroundConfidence else { return }
        groundingCandidateFailureCounts[id, default: 0] += 1
        previousGroundingAnchor = MixtureGrounder.VerifiedGroundingAnchor(
            score: confidence,
            source: source,
            hash: id,
            verifiedAt: Date()
        )
        recordGroundingSelectionEvidence(from: agent, screenChanged: false)
    }

    private func recordGroundingVisibleEffect(from agent: ComputerUseAgent) {
        guard let id = agent.lastGroundCandidateID,
              let source = agent.lastGroundSource,
              let confidence = agent.lastGroundConfidence else { return }
        groundingCandidateFailureCounts[id] = 0
        previousGroundingAnchor = MixtureGrounder.VerifiedGroundingAnchor(
            score: confidence,
            source: source,
            hash: id,
            verifiedAt: Date()
        )
        recordGroundingSelectionEvidence(from: agent, screenChanged: true)
    }

    private func recordGroundingVisibleEffect(from agent: ScoutAgent) {
        guard let id = agent.lastGroundCandidateID,
              let source = agent.lastGroundSource,
              let confidence = agent.lastGroundConfidence else { return }
        groundingCandidateFailureCounts[id] = 0
        previousGroundingAnchor = MixtureGrounder.VerifiedGroundingAnchor(
            score: confidence,
            source: source,
            hash: id,
            verifiedAt: Date()
        )
        recordGroundingSelectionEvidence(from: agent, screenChanged: true)
    }

    private func recordGroundingSelectionEvidence(from agent: ComputerUseAgent, screenChanged: Bool) {
        guard let id = agent.lastGroundCandidateID,
              let source = agent.lastGroundSource,
              let confidence = agent.lastGroundConfidence,
              let target = agent.lastGroundTarget else { return }
        let front = NSWorkspace.shared.frontmostApplication
        episodeGroundingSelections.append(GroundingSelectionEvidence(
            app: front?.localizedName ?? "Unknown",
            target: target,
            source: source,
            candidateID: id,
            confidence: confidence,
            screenChanged: screenChanged
        ))
    }

    private func recordGroundingSelectionEvidence(from agent: ScoutAgent, screenChanged: Bool) {
        guard let id = agent.lastGroundCandidateID,
              let source = agent.lastGroundSource,
              let confidence = agent.lastGroundConfidence,
              let target = agent.lastGroundTarget else { return }
        let front = NSWorkspace.shared.frontmostApplication
        episodeGroundingSelections.append(GroundingSelectionEvidence(
            app: front?.localizedName ?? "Unknown",
            target: target,
            source: source,
            candidateID: id,
            confidence: confidence,
            screenChanged: screenChanged
        ))
    }

    /// Whether the structural grounding split is the active on-screen mode. ON by
    /// default whenever a grounder is configured (Opus names targets, the grounder
    /// locates) — opt out with `cascade.onScreenGrounding = "coordinate"` to A/B
    /// against the proven computer-tool path. See [[cascade-cu-downgrade-research]].
    static func structuralGroundingEnabled() -> Bool {
        UserDefaults.standard.string(forKey: "cascade.onScreenGrounding") != "coordinate"
    }

    /// Whether the pre-action irreversible-key gate is armed — refuse quit /
    /// force-quit / log-out / empty-Trash keys (unless the goal itself asks for
    /// them). OFF by default; opt in with `cascade.guardIrreversibleActions = true`.
    /// Best suited to unattended / scheduled runs where no one is watching to hit
    /// STOP and a stray cmd+Q silently abandons the task. See `irreversibleRefusal`.
    static func guardIrreversibleEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "cascade.guardIrreversibleActions")
    }

    private func assistActionCritic() -> (any ActionCritic)? {
        if let actionCriticOverride { return actionCriticOverride }
        guard hasAnthropicKey else { return nil }
        let helper = TextHelperModel.resolve()
        return PromptActionCritic(client: helper.client, model: helper.model)
    }

    /// Builds the on-screen grounder. ON by default — opt out with
    /// `cascade.visualGrounder = false`. Backend defaults to "uitars": **hosted
    /// UI-TARS-1.5-7B over OpenRouter** (OpenAI-compatible), so end users never run
    /// a 7B model locally. Authenticates with the OpenRouter key in the Keychain;
    /// with no key it returns nil — the agent then runs the proven coordinate
    /// computer-tool path, never broken. Set `cascade.visualGrounder.backend =
    /// "claude"` to ground with the cloud ElementLocator instead (zero setup, costs
    /// a Claude call per locate). The grounder MODEL is swappable without a rebuild
    /// via `cascade.visualGrounder.model` (e.g. UI-Venus-1.5 / Holo1.5 once a host
    /// serves them — see docs/AGENT_FAILURE_RATE_RESEARCH.md), with an explicit
    /// `…endpoint` (a NEW key — the old `…uitarsURL` once inherited a stale
    /// dead-localhost value and stalled every run) and a `…coordSpace`
    /// (smartResize | sent | normalized) for models that don't share UI-TARS's
    /// Qwen2.5-VL space. All default to the proven hosted UI-TARS over OpenRouter.
    /// See [[cascade-cu-downgrade-research]].
    ///
    /// The chosen visual grounder is wrapped in a `MixtureGrounder` (AX-first, ON by
    /// default; `cascade.mixtureGrounding = false` to disable) so labeled chrome
    /// controls resolve structurally — free, exact, no transport flakiness — and only
    /// canvas/custom elements fall through to the visual model. Instance method so it
    /// can pass the live `appSkills` registry (the mixture grounder skips AX on the
    /// apps that registry flags `axUnreliable`).
    func assistGrounder(ownsGroundingCache: Bool = true) -> VisualGrounder? {
        let d = defaultsStore
        // Default ON: unset → enabled; explicit false → disabled.
        let enabled = (d.object(forKey: "cascade.visualGrounder") as? Bool) ?? true
        guard enabled else { return nil }
        let base: VisualGrounder
        if let visualGrounderOverride {
            base = visualGrounderOverride
        } else {
            let backend = d.string(forKey: "cascade.visualGrounder.backend")
            let presetID = backend == "claude"
                ? "claude"
                : (d.string(forKey: "cascade.visualGrounder.preset") ?? GrounderRegistry.defaultPresetID)
            guard let grounder = GrounderRegistry.makeGrounder(
                presetID: presetID,
                apiKey: OpenRouterKeyStore().readKey(),
                endpointOverride: d.string(forKey: "cascade.visualGrounder.endpoint"),
                modelOverride: d.string(forKey: "cascade.visualGrounder.model"),
                coordSpaceOverride: d.string(forKey: "cascade.visualGrounder.coordSpace")
            ) else { return nil }
            base = grounder
        }
        // Default ON: unset → enabled; explicit false → disabled (pure visual A/B).
        let mixture = (d.object(forKey: "cascade.mixtureGrounding") as? Bool) ?? true
        let verifyCandidates = (d.object(forKey: Self.experimentalGroundingVerifierKey) as? Bool) ?? mixture
        return mixture ? MixtureGrounder(
            base: base,
            skills: appSkills,
            verifyCandidates: verifyCandidates,
            previousAnchor: previousGroundingAnchor,
            candidateFailureCounts: groundingCandidateFailureCounts,
            groundingCache: ownsGroundingCache ? groundingCache : nil,
            cacheMode: Self.structuralGroundingEnabled() ? .structural : .coordinate,
            onRuntimeProfile: { [store = self.store, profileBuffer = self.episodeSparseAXProfiles] profile in
                profileBuffer.record(profile)
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "grounding.ax_profile",
                    detail: profile.safeAuditDetail
                ))
            },
            onVerifierOutcome: { [weak self, store = self.store] outcome in
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "grounding.verifier",
                    detail: Self.groundingVerifierAuditDetail(outcome)
                ))
                guard outcome.verifierResult.verdict != .accept else { return }
                guard let self else { return }
                let appName = await MainActor.run { AppWindowObserver.snapshot().appName }
                await self.recordReflectionFailureMemory(
                    appName: appName,
                    goal: outcome.target,
                    failureKind: .groundingMiss,
                    firstBadAction: "ground target",
                    targetHash: outcome.selectedCandidateHash ?? Self.auditHash(outcome.target),
                    stateSummary: "verifier=\(outcome.verifierResult.verdict.rawValue) failure=\(outcome.verifierResult.failureKind?.rawValue ?? "none") source=\(outcome.selectedSource?.rawValue ?? "unknown")",
                    repairHint: "Re-describe the visible target once and prefer independent AX/OCR agreement over the rejected source.",
                    recoveryEvidenceSeed: "\(outcome.verifierResult.verdict.rawValue)|\(outcome.selectedCandidateHash ?? Self.auditHash(outcome.target))"
                )
            }
        ) : base
    }

    /// Region locator for the "where is X" highlight: deterministic local AX/OCR
    /// narrowing first, then the configured grounder, then the proven Claude
    /// ElementLocator on any miss. This keeps common visible-text targets on-device
    /// even when no visual grounder is configured.
    func locateRegionGrounded(
        screenshot: Data, question: String,
        displayWidthPoints: Int, displayHeightPoints: Int,
        conversation: [(user: String, assistant: String)]
    ) async -> ElementRegion {
        if let localRegion = await localRegionNarrowed(
            screenshot: screenshot,
            question: question,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ) {
            return localRegion
        }
        if let grounder = assistGrounder(),
           let region = await grounder.groundRegion(
               screenshot: screenshot, target: question,
               displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
           ) {
            return region
        }
        return await elementLocator.locateRegion(
            screenshot: screenshot, question: question,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints,
            conversation: conversation
        )
    }

    private func localRegionNarrowed(
        screenshot: Data,
        question: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementRegion? {
        if let localRegionNarrowerOverride {
            return await localRegionNarrowerOverride(
                screenshot,
                question,
                displayWidthPoints,
                displayHeightPoints
            )
        }
        let narrower = LocalRegionNarrower(
            skills: appSkills,
            onRuntimeProfile: { [store = self.store, profileBuffer = self.episodeSparseAXProfiles] profile in
                profileBuffer.record(profile)
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "grounding.ax_profile",
                    detail: profile.safeAuditDetail
                ))
            }
        )
        return await narrower.narrow(
            screenshot: screenshot,
            target: question,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
    }

    /// On-screen backend: Scout (Groq plan + grounder) vs the Opus computer-use loop.
    /// ONE BRAIN: Scout is the DEFAULT whenever it's fully set up — a Groq key (the
    /// planner) AND an OpenRouter key (the grounder) are both present — matching the
    /// background agent. Force either way with `cascade.onScreenBackend` = "scout" /
    /// "opus"; with the keys missing it falls back to the proven Opus path, so a
    /// keyless setup is never broken.
    static func onScreenBackendIsScout() -> Bool {
        switch UserDefaults.standard.string(forKey: "cascade.onScreenBackend") {
        case "scout": return true
        case "opus", "claude": return false
        default: return GroqKeyStore().hasKey() && OpenRouterKeyStore().hasKey()
        }
    }

    /// The Tier 2 on-screen loop: Scout (Groq, vision) plans the next action and
    /// names its target; UI-TARS grounds the target to a coordinate; the result is
    /// the same CUAction batch the Opus path produces, executed by the same
    /// `executeCU` under the same generation/STOP gates. A leaner loop than the
    /// Opus path (no SSE streaming, no skills/harness) — additive, opt-in, so the
    /// Opus loop is untouched. RUNTIME-UNVERIFIED (needs Scout + UI-TARS serving).
    private func runScoutEpisode(
        goal: String,
        prefix: String,
        screen: NSScreen,
        firstScreenshotPNG: Data,
        gen: Int,
        routeHint: SearchRouteHint? = nil
    ) async -> AssistEpisodeOutcome {
        // Scout grounds EVERY click, so it can't run without a working grounder.
        // Fail clearly rather than fall back to a dead localhost endpoint (the old
        // `?? UITARSGrounder()` silently pointed at :8000 and every click missed).
        guard let grounder = assistGrounder() else {
            teachMessage = "The Scout backend needs a grounder — connect an OpenRouter key in Settings → Model Keys to use it."
            dock.show(title: "Scout needs a grounder", detail: "Add an OpenRouter key in Settings.")
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.timing", detail: "no-grounder · scout · 0 turns"))
            return .stalled("The Scout backend needs a grounder — connect an OpenRouter key (Settings → Model Keys), or switch the on-screen engine back to Claude.")
        }
        // Same in-process tool harness as the Opus path: use_skill (pull), the
        // file/shell harness, and record recall — shared providers, so Scout can
        // reach for them too (it may underuse pull-tools, but the capability is here).
        // Planner backend is configurable via `cascade.scoutPlanner.*`: defaults to
        // Llama-4 Scout via Groq (Groq's only capable multimodal model), or a
        // multimodal model on OpenRouter (e.g. qwen/qwen3.6-plus). The grounder is
        // configured separately (`cascade.visualGrounder.*`).
        let planner = ScoutPlannerBackend.resolve(defaults: defaultsStore)
        let sourcePlan = routeHint ?? Self.routeIntentHeuristic(goal)
        let searchShapedGoal = defaultsStore.bool(forKey: Self.experimentalSearchRoutingKey) && Self.routeNeedsSourceEvidence(sourcePlan)
        var searchToolCalls = 0
        var searchFinishBlocked = false
        let agent = ScoutAgent(
            vision: planner.vision,
            grounder: grounder,
            model: planner.model,
            // The SAME environment context Opus gets — foreground-browser behavior note
            // + today's date — so the planner is told everything Opus is told (parity).
            environmentNote: ComputerUseAgent.foregroundBrowserNote + "\n\n" + AgentDateContext.line(),
            skillProvider: assistSkillProvider(goal: goal),
            skillIndex: appSkills.indexText,
            harnessProvider: assistHarnessProvider(goal: goal, gen: gen, onSearchToolCall: { _ in
                searchToolCalls += 1
            }),
            harnessTier: effectivePowerHarnessEnabled ? .full : .readOnly,
            recallEnabled: capturePrivacyPolicy.recordRecallAvailable,
            includeStructuredRecallContent: experimentalStructuredContent,
            resourceCatalogEnabled: defaultsStore.bool(forKey: Self.experimentalSearchRoutingKey)
        )
        let dw = Int(screen.frame.width), dh = Int(screen.frame.height)
        let res = AgentResolution.best(forWidth: dw, height: dh)
        let maxSteps = 60
        var acted = false
        var idleTurns = 0
        // Observability: the Scout loop used to return from many paths (failed,
        // superseded, capture-fail, step-limit) with NO audit, so a sudden stop left
        // nothing in the log to explain it. Track timing and log EVERY exit + reason.
        let episodeStart = ContinuousClock.now
        var count = 0
        var modelTime = Duration.zero
        func scoutEnd(_ outcome: AssistEpisodeOutcome, _ why: String) async -> AssistEpisodeOutcome {
            let total = episodeStart.duration(to: .now)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.timing",
                detail: "\(why) · scout · \(count) turns · total \(Int(total / .milliseconds(1)))ms · model \(Int(modelTime / .milliseconds(1)))ms"))
            return outcome
        }
        // No-effect detection — ported from the Opus path (`runAssistEpisode`). Scout
        // is cheap and weak at perceiving change, so without this it re-clicks/
        // re-pastes the same dead spot (audited: the SAME 20 chars pasted 7× at one
        // point). Diff the frame with the recorder's grid hash (zero extra model
        // calls); on a no-op acting turn, nudge with the controls actually on screen,
        // and stop after 3 in a row. This is the single biggest harness Scout lacked.
        var noEffectTurns = 0
        var noEffectVerifierUsed = false
        // Fast-fail counter for un-findable targets: a ground miss on a view that exposes
        // NO controls at all means the target simply isn't on screen — re-nudging can't
        // help, so bail after a couple instead of grinding the verifier/best-of-N stack.
        var emptyViewMissTurns = 0
        var lastFrameHashes = Self.gridHashes(ofJPEG: firstScreenshotPNG)
        var nudge: String?

        // Parity with the Opus path's harness: seed cross-turn memory, push the
        // frontmost app's skill (Scout can't pull), and pass the grounding note.
        let initialNote = await initialScoutNote(goal: goal)
        var modelStart = ContinuousClock.now
        var step = await agent.begin(
            goal: goal, screenshot: firstScreenshotPNG, displayWidthPoints: dw, displayHeightPoints: dh,
            conversation: assistMemory.historyForAPI(), note: initialNote,
            skill: scoutSkillPush(goal: goal)
        )
        modelTime += modelStart.duration(to: .now); count += 1
        var currentShot = firstScreenshotPNG
        for _ in 0..<maxSteps {
            if assistGeneration != gen { return await scoutEnd(.stopped, "superseded") }
            if driver.runState.isStopRequested {
                agentMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: agentMessage)
                return await scoutEnd(.stopped, "user-stop")
            }
            if step.failed { return await scoutEnd(.failed, Self.assistPlannerFailedTimingReason(step.text)) }
            if !step.text.isEmpty {
                teachMessage = prefix + step.text
                // Speak the turn's intent aloud like the Opus path, so the agent is
                // audibly alive during the run instead of silent — a silent Scout
                // reads as "stopped" even while it's working. When it actually spoke
                // AND this turn acts, give the voice a 450ms head start before the
                // actions land (mirrors runAssistEpisode's batch narration). The
                // done turn is skipped here — its summary is spoken by the caller.
                if !step.done, narrateProgress(step.text), !step.actions.isEmpty {
                    try? await Task.sleep(for: .milliseconds(450))
                }
            }
            if step.done {
                let claimed = step.text.isEmpty ? "Done." : step.text
                if searchShapedGoal, searchToolCalls == 0 {
                    if searchFinishBlocked {
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "assist.search.ungated",
                            detail: Self.assistSearchUngatedAuditDetail(goal: goal, routeHint: routeHint, status: "stalled")
                        ))
                        return await scoutEnd(.stalled("I tried to finish without searching any source, so I paused instead of guessing."), "search-ungated-stall")
                    }
                    searchFinishBlocked = true
                    let searchNudge = Self.searchSufficiencyNudge(routeHint: routeHint)
                    _ = try? await store.appendAudit(AuditEvent(
                        actor: "agent",
                        action: "assist.search.ungated",
                        detail: Self.assistSearchUngatedAuditDetail(goal: goal, routeHint: routeHint, status: "blocked")
                    ))
                    modelStart = ContinuousClock.now
                    step = await agent.proceed(
                        screenshot: currentShot,
                        note: [scoutGroundingNote(), searchNudge].compactMap { $0 }.joined(separator: "\n"),
                        skill: scoutSkillPush(goal: goal)
                    )
                    modelTime += modelStart.duration(to: .now); count += 1
                    continue
                }
                if acted, let missing = await validateAssistCompletion(goal: goal, claimed: claimed, screen: screen) {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.validate", detail: Self.assistValidationAuditDetail(missing)))
                    return await scoutEnd(.stalled("I'm not sure that finished — \(missing)"), "validate-incomplete")
                }
                return await scoutEnd(.finished(claimed, acted: acted), "finished")
            }

            // Grounding visibility: log where each grounded click landed (or that it
            // found nothing) so the audit shows the WHERE-to-click decisions.
            if let g = agent.lastGroundLog {
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.ground", detail: Self.groundAuditDetail(g)))
            }
            // Fresh nudge each turn; the idle / no-effect branches below may set it.
            nudge = nil
            // Stall guard with observation-only accounting (parity with the Opus
            // path): a turn with NO executable actions (grounding miss / unparseable
            // plan) OR one that only waits is the planner staring, not working — count
            // it toward the guard. (A wait-only turn no longer trips no-effect after
            // the predicted-effect gate, so without this it could loop unchecked.)
            // Tolerate 1, nudge at 2, stop at 3.
            var actedThisTurn = false
            let observationOnly = !step.actions.isEmpty && step.actions.allSatisfy {
                if case .wait = $0 { return true } else { return false }
            }
            if step.actions.isEmpty || observationOnly {
                idleTurns += 1
                if idleTurns >= 3 {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.stalled", detail: Self.assistStalledAuditDetail(engine: "scout", text: step.text)))
                    return await scoutEnd(.stalled(step.text.isEmpty ? "I couldn't make progress on this." : step.text), "idle-stall")
                }
                if idleTurns == 2 {
                    nudge = "You've now spent two turns without acting on the screen. Act NOW — name a control to click or fill — or, if the task is already done or can't be done, set action to \"done\" and say why. Do not just narrate."
                }
            } else {
                idleTurns = 0
            }
            // Execute whatever the turn produced (a lone wait still settles the UI);
            // an idle/empty turn simply has nothing to run.
            for action in step.actions {
                if assistGeneration != gen { return await scoutEnd(.stopped, "superseded") }
                if driver.runState.isStopRequested { return await scoutEnd(.stopped, "user-stop") }
                let ok = await executeCU(action, on: screen)
                if !ok { return await scoutEnd(.failed, "action-failed") }  // executeCU surfaced why
                acted = true
                actedThisTurn = true
                try? await Task.sleep(for: .milliseconds(120))   // pace gap between actions
            }
            if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }   // let the UI settle before re-observing

            guard let shot0 = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else { return await scoutEnd(.failed, "capture-failed") }
            if assistGeneration != gen { return await scoutEnd(.stopped, "superseded") }

            // No-effect check (with the same slow-render re-check the Opus path uses).
            // Predicted-effect gate (VeriGUI): a turn that only copied or waited
            // legitimately leaves the screen unchanged — don't charge it as a failure.
            let expectsChange = Self.turnExpectsVisibleChange(step.actions)
            var observedShot = shot0
            var observedHashes = Self.gridHashes(ofJPEG: shot0)
            if actedThisTurn, expectsChange, let last = lastFrameHashes, let first = observedHashes,
               PerceptualHash.isDuplicateGrid(first, of: last, threshold: Self.noEffectThreshold) {
                try? await Task.sleep(for: .milliseconds(400))
                if let recheck = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) {
                    observedShot = recheck
                    observedHashes = Self.gridHashes(ofJPEG: recheck)
                }
                if let confirmed = observedHashes,
                   !PerceptualHash.isDuplicateGrid(confirmed, of: last, threshold: Self.noEffectThreshold) {
                    noEffectTurns = 0  // the effect just rendered late — it DID work
                } else {
                    noEffectTurns += 1
                    // The controls list is PUSHED proactively into turnNote below
                    // (harvested once), so the nudge just steers — no second AX walk.
                    nudge = "Your last action did NOT change the screen at all — do NOT repeat that same action; pick a DIFFERENT control from those listed below, open the right menu/panel, or set action to \"done\" if it truly can't be done."
                    if noEffectTurns >= 2, !noEffectVerifierUsed {
                        noEffectVerifierUsed = true
                        if let verifierNudge = await runNoEffectVerifier(
                            goal: goal,
                            lastAction: Self.actionSummary(step.actions),
                            screenshot: observedShot,
                            turn: count,
                            engine: "scout"
                        ) {
                            nudge = [nudge, verifierNudge].compactMap { $0 }.joined(separator: " ")
                        }
                    }
                    if noEffectTurns >= Self.recoveryAttemptLimit(for: AgentOrchestrator.AgentFailureKind.noEffect) {
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent", action: "assist.noeffect",
                            detail: Self.assistNoEffectAuditDetail(turn: count, status: "scout-stopping", noEffectStreak: noEffectTurns)
                        ))
                        return await scoutEnd(.stalled("My actions aren't changing anything on screen, so I've stopped — please take over or tell me another way."), "noeffect-stall")
                    }
	                    _ = try? await store.appendAudit(AuditEvent(
	                        actor: "agent", action: "assist.noeffect",
	                        detail: Self.assistNoEffectAuditDetail(turn: count, status: "scout-no-effect", noEffectStreak: noEffectTurns)
	                    ))
	                }
                    if let risky = agent.lastRiskyVisualClick,
                       let verifierNudge = await runVisualStateVerifier(
                           goal: goal,
                           risky: risky,
                           screenshot: observedShot,
                           turn: count,
                           engine: "scout"
                       ) {
                        nudge = [nudge, verifierNudge].compactMap { $0 }.joined(separator: " ")
                    }
	            } else if actedThisTurn, expectsChange {
	                noEffectTurns = 0
                    recordGroundingVisibleEffect(from: agent)
                    if let risky = agent.lastRiskyVisualClick,
                       let verifierNudge = await runVisualStateVerifier(
                           goal: goal,
                           risky: risky,
                           screenshot: observedShot,
                           turn: count,
                           engine: "scout"
                       ) {
                        nudge = [nudge, verifierNudge].compactMap { $0 }.joined(separator: " ")
                    }
	            }
            // A copy-only/wait-only turn (acted but expectsChange == false) leaves
            // noEffectTurns untouched: it neither failed nor proved progress.
            if let observedHashes { lastFrameHashes = observedHashes }
            // Proactive Set-of-Marks push (the literature's grounding>reasoning
            // finding + Cascade's "push controls, never a pull tool" lesson): harvest
            // the controls actually on screen ONCE per turn and PUSH them to the weak
            // planner EVERY turn — not only on a failure — so it names targets that
            // exist and the grounder (AX-first, then visual) hits them. Bounded AX
            // walk (≤24, ≤0.3s); empty on canvas/Electron apps that expose nothing.
            let controls = AXElementResolver.interactables(limit: 24)
            let controlSummary = AXElementResolver.interactableSummary(controls)
            // Grounding-miss feedback — fires on ANY missed target this turn, idle OR
            // a partially-grounded batch (where step.actions is non-empty so the idle
            // path above is skipped). Tells Scout to re-describe instead of silently
            // re-naming an un-findable target, and audits what was actually on screen.
            if let missed = agent.lastGroundMiss {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent", action: "agent.ground.miss",
                    detail: Self.groundMissAuditDetail(
                        turn: count,
                        missedTarget: missed,
                        controlCount: controls.count,
                        labels: controlSummary
                    )
                ))
                // Fast-fail: a miss on a view exposing ZERO controls means the target
                // isn't here — re-nudging can't help. Bail after 2 rather than grinding
                // the grounder/verifier/best-of-N stack for a minute-plus.
                if controls.count == 0 {
                    emptyViewMissTurns += 1
                    if emptyViewMissTurns >= 2 {
                        return await scoutEnd(.stalled("I can't find “\(missed)” on this screen — there's nothing here I can target. Open the view that has it, or tell me another way."), "ground-miss-empty-view")
                    }
                } else {
                    emptyViewMissTurns = 0
                }
                let missNote = "Couldn't locate “\(missed)” on screen — that may be the text you want to ENTER rather than a control. Name a VISIBLE field, button, or placeholder from the controls listed below (or the text already shown in it), not the text you intend to type. If you have ALREADY clicked into the field, use the type action with NO target."
                nudge = [nudge, missNote].compactMap { $0 }.joined(separator: " ")
            }
            // Refresh the grounding line + the proactive controls list + app skill
            // every turn (the frontmost app changes once Scout opens the target),
            // merged with any nudge above.
            // Canvas perception: when AX is sparse (Keynote slide canvas, Blender),
            // OCR the live frame and hand Scout the on-screen text as nameable targets
            // so it stops ASSUMING what's on the page. Mirrors the AX controls push —
            // structural, gated to sparse-AX turns, off-main so it doesn't stall the loop.
            let ocrMarks = await ocrSetOfMarks(forFrame: observedShot, axControlCount: controls.count, turn: count)
            let turnNote = [scoutGroundingNote(), scoutControlsLine(controlSummary), ocrMarks, nudge].compactMap { $0 }.joined(separator: "\n")
            modelStart = ContinuousClock.now
            currentShot = observedShot
            step = await agent.proceed(
                screenshot: observedShot,
                note: turnNote.isEmpty ? nil : turnNote,
                skill: scoutSkillPush(goal: goal)
            )
            modelTime += modelStart.duration(to: .now); count += 1
        }
        return await scoutEnd(.stepLimit, "step-limit")
    }

    private func runAssistEpisode(
        goal: String,
        prefix: String,
        screen: NSScreen,
        firstScreenshotPNG: Data,
        gen: Int,
        routeHint: SearchRouteHint? = nil
    ) async -> AssistEpisodeOutcome {
        // Tier 2 downgrade: when selected, the cheap on-screen brain (Scout plans,
        // UI-TARS grounds) replaces the Opus computer-use loop. This guard is the
        // ONLY change to the Opus path — default is Claude, so behaviour is
        // unchanged unless the user opts in. See [[cascade-cu-downgrade-research]].
        if Self.onScreenBackendIsScout() {
            return await runScoutEpisode(
                goal: goal,
                prefix: prefix,
                screen: screen,
                firstScreenshotPNG: firstScreenshotPNG,
                gen: gen,
                routeHint: routeHint
            )
        }
        // Pull-based skills: the agent gets a one-line index and fetches a
        // skill's full instructions itself via the use_skill tool. Content
        // never rides the prompt (token cost stays flat as the library grows).
        //
        // On-screen assist runs on Opus 4.8 (the most capable model that still
        // supports the computer-use-2025-11-24 beta). Slower per turn than Sonnet,
        // but its stronger planning does the work in far fewer turns — and the
        // 2026-06-22 audit confirmed turns, not per-turn latency, dominate
        // wall-clock (Sonnet-first ballooned the same Keynote task from ~10 turns
        // to 15 and over-thought; reverted). Effort stays medium — CU default.
        let cuModel = AnthropicModel.opus
        let sourcePlan = routeHint ?? Self.routeIntentHeuristic(goal)
        let searchShapedGoal = defaultsStore.bool(forKey: Self.experimentalSearchRoutingKey) && Self.routeNeedsSourceEvidence(sourcePlan)
        let actionChunkingEnabled = defaultsStore.bool(forKey: Self.experimentalActionChunkingKey)
        let actionCacheLookup = await actionTrajectoryCachePreflight(
            goal: goal,
            firstScreenshotPNG: firstScreenshotPNG
        )
        if let executable = actionCacheLookup?.executable,
           let cachedAction = Self.actionTrajectoryCUAction(kind: executable.row.actionKind, json: executable.row.actionJSON) {
            let before = await Self.uiState()
            let ok = await executeCU(cachedAction, on: screen)
            let verification = await Self.verifyUIChange(after: before)
            let openAppVerified: Bool
            if case .openApp(let name) = cachedAction {
                openAppVerified = await Self.frontmostAppMatches(name)
            } else {
                openAppVerified = false
            }
            if ok && (verification.changed || openAppVerified) {
                _ = try? await store.promoteActionTrajectoryCache(
                    source: executable.row.source,
                    goal: goal,
                    state: await actionTrajectoryState(firstScreenshotPNG: firstScreenshotPNG),
                    targetDescriptor: executable.row.targetDescriptor,
                    targetText: executable.row.targetTextNorm,
                    action: ActionTrajectoryCacheAction(
                        kind: executable.row.actionKind,
                        json: executable.row.actionJSON,
                        preconditionJSON: executable.row.preconditionJSON,
                        postconditionJSON: executable.row.postconditionJSON
                    )
                )
                return .finished("Used a verified cached action.", acted: true)
            }
            _ = try? await store.demoteActionTrajectoryCache(
                id: executable.row.id,
                reason: ok ? .wrongScreen : .disallowedAction
            )
        }
        var searchToolCalls = 0
        var searchFinishBlocked = false
        let agent = makeAssistAgent(model: cuModel, goal: goal, gen: gen, onSearchToolCall: { _ in
            searchToolCalls += 1
        })
        // Structural mode: the model names targets and the grounder locates them —
        // it emits NO coordinates, so the flail nudge below must push target NAMES
        // (to re-describe via click_target), never click coordinates it can't use.
        let structuralGrounding = agent.isStructural
        // Runaway backstop, not a budget. The episode's real terminators are the
        // model finishing, STOP / barge-in, stall detection, or a newer turn
        // superseding this one — a low cap here just killed long honest tasks.
        let maxSteps = 80
        let episodeStart = ContinuousClock.now
        var modelTime = Duration.zero
        var actionTime = Duration.zero
        // Streamed execution: the reply arrives as SSE and each completed tool
        // call runs HERE while the rest is still generating — the cursor starts
        // moving seconds into the round trip instead of after it. Narration is
        // buffered until the turn's first action (an action-less turn is a
        // closing/idle line, which episode paths narrate). Same gates as the
        // batch path below: generation + STOP before every action, pace gap
        // between actions, executeCU failures end the episode.
        var streamActed = false               // an action ran mid-stream this turn
        var streamFailed = false              // executeCU refused — episode is over
        var streamActionTime = Duration.zero  // this turn's in-stream action time
        var streamExpectedChange = false      // a streamed action this turn expected a visible change
        var pendingNarration: String?         // clause buffered until the turn proves it has actions
        // Wiring captures the episode-local state above, so escalation re-applies
        // it to the rebuilt Opus agent by calling this again.
        func wire(_ agent: ComputerUseAgent) {
            agent.onActionRefused = { [weak self] detail in
                guard let self else { return }
                Task { _ = try? await self.store.appendAudit(AuditEvent(actor: "agent", action: "agent.action.refused", detail: detail)) }
            }
            agent.onActionChunkPlanned = { [weak self] plan in
                guard let self else { return }
                Task {
                    _ = try? await self.store.appendAudit(AuditEvent(
                        actor: "agent",
                        action: "action.chunk",
                        detail: Self.actionChunkAuditDetail(
                            length: plan.length,
                            groups: plan.groups.count,
                            kindTokens: plan.kindTokens + plan.deferredKindTokens,
                            status: "deferred",
                            deferred: plan.deferredToolUseIDs.count,
                            breakReason: plan.breakReason
                        )
                    ))
                }
            }
            // A long think used to look like a hang — the dock kept showing the
            // previous turn's line for 30+ seconds. The pulse carries the thinking
            // summary's tail, so the user watches the deliberation happen instead.
            agent.onThinkingPulse = { [weak self] tail in
                guard let self, self.assistGeneration == gen else { return }
                // Keep the companion cursor visibly alive (sonar pulse) through the
                // round-trip freeze, not just the dock text.
                self.guidanceOverlay.setThinking(true)
                self.dock.show(title: "Cascade is thinking…", detail: tail)
            }
            agent.streamSink = { [weak self] item in
                guard let self, self.assistGeneration == gen, !self.driver.runState.isStopRequested else { return false }
                switch item {
                case .text(let line):
                    self.teachMessage = prefix + line
                    // Buffer instead of speaking: a turn that ends with no actions
                    // is the model's closing or idle line, and those are narrated by
                    // the episode's own paths (final summary, stall handling) —
                    // voicing them here too would say everything twice at task end.
                    pendingNarration = line
                    return true
                case .action(let action):
                    if let line = pendingNarration {
                        pendingNarration = nil
                        // Same head start the batch path gave: the user hears
                        // "writing the poem now" BEFORE the typing starts.
                        if self.narrateProgress(line) {
                            try? await Task.sleep(for: .milliseconds(450))
                        }
                    }
                    if streamActed { try? await Task.sleep(for: .milliseconds(120)) }  // pace gap between actions
                    let start = ContinuousClock.now
                    guard await self.executeCU(action, on: screen) else {
                        streamFailed = true
                        return false
                    }
                    let spent = start.duration(to: .now)
                    streamActionTime += spent
                    actionTime += spent
                    streamActed = true
                    if Self.expectsVisibleChange(action) { streamExpectedChange = true }
                    return true
                }
            }
        }
        wire(agent)
        let initialNoteText = [
            await initialAssistNote(goal: goal),
            actionCacheLookup?.hints.first.map { "Action cache hint: \($0)" },
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let initialNote = initialNoteText.isEmpty ? nil : initialNoteText
        var step = await agent.begin(
            goal: goal,
            screenshot: firstScreenshotPNG,
            displayWidthPoints: Int(screen.frame.width),
            displayHeightPoints: Int(screen.frame.height),
            conversation: assistMemory.historyForAPI(),
            note: initialNote,
            skillIndex: appSkills.indexText
        )
        // begin() IS the first model turn; in-stream action time isn't model time.
        modelTime += episodeStart.duration(to: .now) - streamActionTime
        var currentShot = firstScreenshotPNG
        var acted = false
        var count = 0
        // Stall guard: a turn with no actions and no done is the model talking
        // instead of working. One is tolerated (thinking out loud), the second
        // gets a firm nudge, the third ends the episode — never a spam loop to
        // the step cap repeating the same line.
        var idleTurns = 0
        var nudge: String?
        // "No state change after an action" — the cheapest, most universal failure
        // signal in the GUI-agent literature (WILBUR / VeriGUI / AgentRR check
        // functions): if an acting turn leaves EVERY screen region unchanged, the
        // action had no effect (a dead/disabled control, a missed target, a click
        // that hit nothing). The stall guard can't catch this — a dead click is a
        // real action, so it resets idleTurns and the agent re-clicks the same
        // point forever (the audited 657,675 ×2 and 569→570→572 loops). We diff
        // frames with the recorder's existing grid hash (zero extra model calls)
        // and tell the model to change approach. `lastFrameHashes` is the
        // fingerprint of the frame the current `step` was generated from.
        var noEffectTurns = 0
        var noEffectVerifierUsed = false
        var lastFrameHashes = Self.gridHashes(ofJPEG: firstScreenshotPNG)
        func auditTiming(outcome: String) {
            let total = episodeStart.duration(to: .now)
            let detail = "\(outcome) · \(count + 1) turns · total \(Int(total / .milliseconds(1)))ms · model \(Int(modelTime / .milliseconds(1)))ms · actions \(Int(actionTime / .milliseconds(1)))ms · effort \(cuEffort) · \(cuModel)"
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.timing", detail: detail)) }
        }
        while count < maxSteps {
            if assistGeneration != gen {
                auditTiming(outcome: "superseded")  // a newer voice turn took over
                return .stopped
            }
            if driver.runState.isStopRequested {
                auditTiming(outcome: "stopped")
                teachMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: teachMessage)
                return .stopped
            }
            if streamFailed {
                auditTiming(outcome: "failed-action")  // executeCU already surfaced why mid-stream
                return .failed
            }
            if !step.text.isEmpty {
                teachMessage = prefix + step.text
                // Turns that streamed actions already narrated their clause at
                // the first action — re-narrating the joined text here would
                // double-speak once the 4s throttle expires on long turns.
                if !step.done, step.streamedActions == 0, narrateProgress(step.text), !step.actions.isEmpty {
                    // Give the spoken line a head start so the user hears
                    // "writing the poem now" BEFORE the typing starts, not after.
                    try? await Task.sleep(for: .milliseconds(450))
                }
            }
            if step.done {
                let claimed = step.text.isEmpty ? "Done." : step.text
                if searchShapedGoal, searchToolCalls == 0 {
                    if searchFinishBlocked {
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "assist.search.ungated",
                            detail: Self.assistSearchUngatedAuditDetail(goal: goal, routeHint: routeHint, status: "stalled")
                        ))
                        auditTiming(outcome: "search-ungated-stall")
                        return .stalled("I tried to finish without searching any source, so I paused instead of guessing.")
                    }
                    searchFinishBlocked = true
                    nudge = Self.searchSufficiencyNudge(routeHint: routeHint)
                    _ = try? await store.appendAudit(AuditEvent(
                        actor: "agent",
                        action: "assist.search.ungated",
                        detail: Self.assistSearchUngatedAuditDetail(goal: goal, routeHint: routeHint, status: "blocked")
                    ))
                    let modelStart = ContinuousClock.now
                    step = await agent.continueAfterNudge(
                        screenshot: currentShot,
                        note: await episodeNote(nudge) ?? Self.searchSufficiencyNudge(routeHint: routeHint)
                    )
                    modelTime += modelStart.duration(to: .now) - streamActionTime
                    count += 1
                    continue
                }
                // Validator stage: a run that DID work and claims done is checked
                // against fresh on-screen evidence (gated off by default → nil, no
                // overhead). A clear mismatch is reported honestly instead of a
                // false "done".
                if acted, let missing = await validateAssistCompletion(goal: goal, claimed: claimed, screen: screen) {
                    auditTiming(outcome: "incomplete")
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.validate", detail: Self.assistValidationAuditDetail(missing)))
                    return .stalled("I'm not sure that finished — \(missing)")
                }
                auditTiming(outcome: "finished")
                return .finished(claimed, acted: acted)
            }

            // A turn that only LOOKED — screenshot/wait requests, nothing else —
            // is staring, not acting: it must count toward the stall guard, not
            // reset it. Four consecutive look-only turns rode out the 31s
            // thinking burst un-nudged on 2026-06-11 because .screenshot lands
            // in step.actions. Zoom stays a real action (it reads new pixels).
            let observationOnly = step.streamedActions == 0 && !step.actions.isEmpty
                && step.actions.allSatisfy { action in
                    if case .screenshot = action { return true }
                    if case .wait = action { return true }
                    return false
                }
            if (step.actions.isEmpty && step.streamedActions == 0) || observationOnly {
                idleTurns += 1
                if idleTurns >= 3 {
                    auditTiming(outcome: "stalled")
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.stalled", detail: Self.assistStalledAuditDetail(text: step.text)))
                    return .stalled(step.text.isEmpty ? "I couldn't make progress on this." : step.text)
                }
                if idleTurns == 2 {
                    nudge = "You have now spent two turns looking or talking without acting. Either make the tool calls that do the work RIGHT NOW, or — if the task is already complete or impossible — say so and stop. Do not repeat yourself."
                }
            } else {
                idleTurns = 0
                nudge = nil
                acted = true
            }
            // Zoom is answered with the cropped frame, not a regular screenshot —
            // pull it out and run everything else first.
            var zoomRegion: CGRect?
            var actedThisTurn = streamActed
            var chunkExecutedToolUseIDs: Set<String>?
            var chunkBaselineHashes = lastFrameHashes
            if actionChunkingEnabled, !step.actionGroups.isEmpty {
                let result = await Self.executeActionChunkGroups(
                    step.actionGroups,
                    shouldStop: { assistGeneration != gen || driver.runState.isStopRequested },
                    execute: { action in
                        if case .zoom(let nx, let ny, let nw, let nh) = action {
                            zoomRegion = CGRect(x: nx, y: ny, width: nw, height: nh)
                            Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.zoom", detail: String(format: "region %.2f,%.2f %.2f×%.2f", nx, ny, nw, nh))) }
                            return true
                        }
                        actedThisTurn = true
                        let actionStart = ContinuousClock.now
                        guard await executeCU(action, on: screen) else { return false }
                        actionTime += actionStart.duration(to: .now)
                        return true
                    },
                    modalTitle: { await Self.unexpectedModal() },
                    noEffectAfterGroup: { completed in
                        guard let lastGroup = completed.last,
                              Self.turnExpectsVisibleChange(lastGroup.actions),
                              let baseline = chunkBaselineHashes else {
                            return false
                        }
                        let size = agent.captureSize
                        try? await Task.sleep(for: .milliseconds(260))
                        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height),
                              let first = Self.gridHashes(ofJPEG: shot) else {
                            return false
                        }
                        if !PerceptualHash.isDuplicateGrid(first, of: baseline, threshold: Self.noEffectThreshold) {
                            chunkBaselineHashes = first
                            return false
                        }
                        try? await Task.sleep(for: .milliseconds(400))
                        guard let recheck = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height),
                              let confirmed = Self.gridHashes(ofJPEG: recheck) else {
                            return true
                        }
                        if PerceptualHash.isDuplicateGrid(confirmed, of: baseline, threshold: Self.noEffectThreshold) {
                            return true
                        }
                        chunkBaselineHashes = confirmed
                        return false
                    },
                    pace: { hasMoreActions in
                        if hasMoreActions { try? await Task.sleep(for: .milliseconds(120)) }
                    }
                )
                chunkExecutedToolUseIDs = result.executedToolUseIDs
                if result.executedActions > 0 { actedThisTurn = true }
                let plannedDeferredCount = step.chunkPlan?.deferredToolUseIDs.count ?? 0
                let planBreakReason = step.chunkPlan?.breakReason
                if result.executedActions > 1 || plannedDeferredCount > 0 {
                    _ = try? await store.appendAudit(AuditEvent(
                        actor: "agent",
                        action: "action.chunk",
                        detail: Self.actionChunkAuditDetail(
                            length: result.executedActions,
                            groups: result.executedToolUseIDs.count,
                            kindTokens: result.kindTokens + (step.chunkPlan?.deferredKindTokens ?? []),
                            status: plannedDeferredCount > 0 ? "deferred" : result.status,
                            deferred: plannedDeferredCount,
                            breakReason: planBreakReason ?? result.breakReason
                        )
                    ))
                }
                if let reason = result.breakReason {
                    switch reason {
                    case .stop:
                        auditTiming(outcome: "stopped")
                        return .stopped
                    case .modal, .noEffect:
                        agent.deferUnexecutedToolResults(executedToolUseIDs: result.executedToolUseIDs, reason: reason)
                        nudge = [nudge, "A blocking \(reason == .modal ? "dialog" : "no-effect state") appeared; use the new screenshot before continuing."].compactMap { $0 }.joined(separator: " ")
                    default:
                        auditTiming(outcome: "failed-action")
                        return .failed
                    }
                }
            } else {
                for (actionIndex, action) in step.actions.enumerated() {
                    // Re-check between every action — a barge-in or newer turn must
                    // halt mid-batch, not after the batch finishes.
                    if assistGeneration != gen || driver.runState.isStopRequested {
                        auditTiming(outcome: "stopped")
                        return .stopped
                    }
                    if case .zoom(let nx, let ny, let nw, let nh) = action {
                        zoomRegion = CGRect(x: nx, y: ny, width: nw, height: nh)
                        // Zoom turns execute no screen action and change nothing visible —
                        // without this row a zoom LOOP is indistinguishable from a hang
                        // (the 2026-06-11 46s Keynote stall was unattributable).
                        Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.zoom", detail: String(format: "region %.2f,%.2f %.2f×%.2f", nx, ny, nw, nh))) }
                        continue
                    }
                    actedThisTurn = true
                    let actionStart = ContinuousClock.now
                    if !(await executeCU(action, on: screen)) {
                        auditTiming(outcome: "failed-action")
                        return .failed
                    }
                    actionTime += actionStart.duration(to: .now)
                    // The pace gap matters BETWEEN actions; after the last one the
                    // settle sleep below covers it — no double wait.
                    if actionIndex < step.actions.count - 1 {
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                }
            }

            if let groundLog = agent.lastGroundLog {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "agent.ground",
                    detail: Self.groundAuditDetail(groundLog)
                ))
            }
            if let missed = agent.lastGroundMiss {
                let controls = AXElementResolver.interactables(limit: 24)
                let summary = AXElementResolver.interactableSummary(controls)
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "agent.ground.miss",
                    detail: Self.groundMissAuditDetail(
                        turn: count + 1,
                        missedTarget: missed,
                        controlCount: controls.count,
                        labels: summary
                    )
                ))
                let missNote = "Couldn't locate “\(missed)” on screen. Describe the visible target more specifically, using a label, role, or nearby text from the current screen."
                nudge = [nudge, missNote].compactMap { $0 }.joined(separator: " ")
            }

            if let zoomRegion {
                // Native-resolution crop so the model can actually read small text.
                if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
                if let crop = await ScreenCaptureUtility.captureCursorScreenZoomJPEG(normalizedRect: zoomRegion) {
                    currentShot = crop
                    streamActed = false
                    streamActionTime = .zero
                    streamExpectedChange = false
                    pendingNarration = nil
                    let modelStart = ContinuousClock.now
                    step = await agent.proceed(screenshot: crop, note: await episodeNote(nudge), zoomResult: true)
                    modelTime += modelStart.duration(to: .now) - streamActionTime
                    count += 1
                    continue
                }
                // Crop failed — fall through to the regular re-observe.
            }
            // Let the UI settle, then re-observe and ask for the next step. Capturing
            // at the agent's resolution as JPEG skips the PNG round-trip and OCR.
            // A turn that did nothing changed nothing — skip the settle entirely.
            if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
            let size = agent.captureSize
            guard let nextShot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) else {
                auditTiming(outcome: "failed-capture")
                teachMessage = "I lost sight of the screen — try again."
                return .failed
            }
            // No-effect detection (hardened against false positives): an acting
            // turn whose every screen region is unchanged did nothing — don't let
            // the model re-click the dead spot. Two guards keep a SUCCESSFUL action
            // from being mislabeled "no effect": (1) `noEffectThreshold` is far
            // tighter than the recorder's blink dedup — a dead click is near
            // byte-identical, a real change shifts many bits; (2) a delayed
            // RE-CHECK — a theme still downloading, an app still launching, or an
            // animation can finish AFTER the 260ms settle, so on a suspected
            // no-effect we wait and re-capture once before concluding (and use that
            // fresher frame). The extra wait costs time only on the rare flail path.
            // Predicted-effect gate (VeriGUI): a turn whose only acting was a
            // clipboard copy or a wait legitimately changed nothing — exempt it so an
            // honest no-op doesn't accrue toward the no-effect stall.
            let expectsChange = streamExpectedChange || Self.turnExpectsVisibleChange(step.actions)
            var observedShot = nextShot
            var observedHashes = Self.gridHashes(ofJPEG: nextShot)
            if actedThisTurn, !observationOnly, expectsChange, let last = lastFrameHashes, let first = observedHashes,
               PerceptualHash.isDuplicateGrid(first, of: last, threshold: Self.noEffectThreshold) {
                try? await Task.sleep(for: .milliseconds(400))
                if let recheck = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) {
                    observedShot = recheck
                    observedHashes = Self.gridHashes(ofJPEG: recheck)
                }
	                if let confirmed = observedHashes,
	                   !PerceptualHash.isDuplicateGrid(confirmed, of: last, threshold: Self.noEffectThreshold) {
	                    // The effect just rendered late — the action DID work.
	                    noEffectTurns = 0
	                    recordGroundingVisibleEffect(from: agent)
	                    _ = try? await store.appendAudit(AuditEvent(
	                        actor: "agent", action: "assist.noeffect",
	                        detail: Self.assistNoEffectAuditDetail(turn: count + 1, status: "recheck-cleared", noEffectStreak: noEffectTurns)
	                    ))
			                } else {
                    noEffectTurns += 1
                    if actionChunkingEnabled {
                        agent.deferUnexecutedToolResults(
                            executedToolUseIDs: chunkExecutedToolUseIDs ?? Set(step.actionGroups.compactMap(\.toolUseID)),
                            reason: .noEffect
                        )
                    }
			                    recordGroundingNoEffect(from: agent)
		                    if noEffectTurns >= 2, !noEffectVerifierUsed {
		                        noEffectVerifierUsed = true
		                        if let verifierNudge = await runNoEffectVerifier(
		                            goal: goal,
		                            lastAction: Self.actionSummary(step.actions),
		                            screenshot: observedShot,
		                            turn: count + 1,
		                            engine: "opus"
		                        ) {
		                            nudge = [nudge, verifierNudge].compactMap { $0 }.joined(separator: " ")
		                        }
		                    }
		                    if noEffectTurns >= Self.recoveryAttemptLimit(for: AgentOrchestrator.AgentFailureKind.noEffect) {
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent", action: "assist.noeffect",
                            detail: Self.assistNoEffectAuditDetail(turn: count + 1, status: "stopping", noEffectStreak: noEffectTurns)
                        ))
                        auditTiming(outcome: "stalled-noeffect")
                        return .stalled("My actions aren't changing anything on screen, so I've stopped — please take over or tell me another way.")
                    }
                    nudge = "Your last action did NOT change the screen at all — it had no effect (the control isn't where you clicked, is disabled, or needs a different gesture). Do NOT repeat that same click."
                    // Flail-moment grounding push (Cascade's "push elements at a
                    // flail moment, never a pull tool" lesson + the literature's
                    // grounding>reasoning finding): hand the model the controls that
                    // ARE actually on screen so it re-grounds on real elements
                    // instead of re-guessing the same dead pixel.
                    let controls = AXElementResolver.interactables()
                    if structuralGrounding {
                        // Structural mode names targets — pushing coordinates would be
                        // useless (it can't emit them). Push the control LABELS and
                        // tell it to re-aim with click_target by name.
                        if let summary = AXElementResolver.interactableSummary(controls) {
                            nudge! += " The controls actually on screen right now are: \(summary). Name one of THESE with click_target (by its label or role) — if what you wanted isn't listed, it isn't a clickable control here, so open the right menu/panel or take another route."
                            _ = try? await store.appendAudit(AuditEvent(
                                actor: "agent", action: "assist.noeffect",
                                detail: Self.assistNoEffectAuditDetail(
                                    turn: count + 1,
                                    status: "pushed-labels-structural",
                                    noEffectStreak: noEffectTurns,
                                    controlCount: controls.count,
                                    labels: summary
                                )
                            ))
                        } else {
                            nudge! += " Choose a DIFFERENT control, menu, or approach — or, if this can't be done, say so and stop."
                            _ = try? await store.appendAudit(AuditEvent(
                                actor: "agent", action: "assist.noeffect",
                                detail: Self.assistNoEffectAuditDetail(
                                    turn: count + 1,
                                    status: "no-controls-structural",
                                    noEffectStreak: noEffectTurns,
                                    controlCount: controls.count
                                )
                            ))
                        }
                    } else if let located = Self.groundingControls(controls, display: Self.displayBounds(of: screen), resW: size.width, resH: size.height) {
                        // Coordinate-level grounding: the model is poor at producing
                        // click coordinates but fine choosing from given ones (the
                        // GUI-agent grounding>reasoning finding) — so hand it the
                        // exact x,y of each real control to click directly.
                        nudge! += " The controls actually on screen right now, with their click coordinates, are: \(located). Click one of THESE coordinates directly instead of guessing — if what you wanted isn't listed, it isn't a clickable control here, so open the right menu/panel or take another route."
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent", action: "assist.noeffect",
                            detail: Self.assistNoEffectAuditDetail(
                                turn: count + 1,
                                status: "pushed-coords",
                                noEffectStreak: noEffectTurns,
                                controlCount: controls.count,
                                coords: located
                            )
                        ))
                    } else if let summary = AXElementResolver.interactableSummary(controls) {
                        nudge! += " The controls actually clickable on screen right now are: \(summary). Aim for one of these by sight — if what you wanted isn't in this list, it isn't clickable here, so open the right menu/panel or take another route."
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent", action: "assist.noeffect",
                            detail: Self.assistNoEffectAuditDetail(
                                turn: count + 1,
                                status: "pushed-labels",
                                noEffectStreak: noEffectTurns,
                                controlCount: controls.count,
                                labels: summary
                            )
                        ))
                    } else {
                        nudge! += " Choose a DIFFERENT control, menu, or approach — or, if this can't be done, say so and stop."
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent", action: "assist.noeffect",
                            detail: Self.assistNoEffectAuditDetail(
                                turn: count + 1,
                                status: "no-controls",
                                noEffectStreak: noEffectTurns,
                                controlCount: controls.count
                            )
                        ))
                    }
                    // Canvas perception parity with Scout: when AX is blind (Keynote
                    // slide canvas, Blender), OCR the frame and hand Opus the on-screen
                    // TEXT as nameable targets too — gated to sparse-AX NATIVE surfaces
                    // (browsers excluded) inside ocrSetOfMarks.
                    if let ocr = await ocrSetOfMarks(forFrame: observedShot, axControlCount: controls.count, turn: count + 1) {
                        nudge! += "\n" + ocr
	                    }
	                }
                if actedThisTurn, expectsChange, let risky = agent.lastRiskyVisualClick,
                   let verifierNudge = await runVisualStateVerifier(
                       goal: goal,
                       risky: risky,
                       screenshot: observedShot,
                       turn: count + 1,
                       engine: "opus"
                   ) {
                    nudge = [nudge, verifierNudge].compactMap { $0 }.joined(separator: " ")
                }
            } else if actedThisTurn, !observationOnly, expectsChange {
	                noEffectTurns = 0
	                recordGroundingVisibleEffect(from: agent)
                if let risky = agent.lastRiskyVisualClick,
                   let verifierNudge = await runVisualStateVerifier(
                       goal: goal,
                       risky: risky,
                       screenshot: observedShot,
                       turn: count + 1,
                       engine: "opus"
                   ) {
                    nudge = [nudge, verifierNudge].compactMap { $0 }.joined(separator: " ")
                }
            }
            // A copy-only/wait-only acting turn leaves noEffectTurns untouched.
            if let observedHashes { lastFrameHashes = observedHashes }
            streamActed = false
            streamActionTime = .zero
            streamExpectedChange = false
            pendingNarration = nil
            let modelStart = ContinuousClock.now
            currentShot = observedShot
            step = await agent.proceed(screenshot: observedShot, note: await episodeNote(nudge))
            modelTime += modelStart.duration(to: .now) - streamActionTime
            count += 1
        }
        auditTiming(outcome: "step-limit")
        return .stepLimit
    }

    /// Runs one recall tool call for the assist agent: STOP/supersession gate,
    /// an audit row with the safe descriptor, then the read-only
    /// lookup against the local record via the shared `RecordRecall`. No
    /// file/shell deny-list or one-lane gate applies — this only reads what the
    /// user already saw on screen, the same surface the Ask panel searches.
    private func performRecall(name: String, input: [String: Any], gen: Int) async -> String {
        guard assistGeneration == gen, !driver.runState.isStopRequested else {
            return "The user stopped this task. Do not continue — end now."
        }
        guard trustedAuditHistoryForSensitiveAction() else { return untrustedAuditHistoryMessage }
        guard capturePrivacyPolicy.recordRecallAvailable else {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "policy",
                action: "policy.enforced",
                detail: Self.policyDecisionAuditDetail(capability: "record_recall", decision: "blocked", reason: "record_recall_unavailable")
            ))
            return "Managed policy has disabled record recall for agents."
        }
        // Parse the Sendable call HERE (on the main actor) so the untyped
        // dictionary never crosses into RecordRecall's nonisolated executor.
        let call = RecordRecall.Call(name: name, input: input)
        dock.show(title: "Cascade is remembering", detail: call.auditDetail)
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.recall", detail: call.auditDetail))
        let result = await RecordRecall(store: store).perform(call)
        await auditObservationResultIfNeeded(tool: name, result: result)
        return result
    }

    /// Runs one harness tool call for the assist agent: STOP/supersession gate
    /// first, then an audit row with a safe descriptor, then the actual execution
    /// (which applies the power-tier gate and the destructive deny-list). The dock
    /// shows each call as it runs, so the user supervises scripts the same way they
    /// supervise clicks.
    private func performHarness(name: String, input: [String: Any], goal: String, gen: Int) async -> String {
        guard assistGeneration == gen, !driver.runState.isStopRequested else {
            return "The user stopped this task. Do not continue — end now."
        }
        guard trustedAuditHistoryForSensitiveAction() else { return untrustedAuditHistoryMessage }
        guard let call = HarnessCall(name: name, input: input) else {
            return "Unknown harness tool “\(name)”."
        }
        if let reason = deniedURLReason(inHarnessInput: input) {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "policy",
                action: "policy.enforced",
                detail: Self.policyDecisionAuditDetail(capability: "harness_url", decision: "blocked", reason: reason)
            ))
            return "Managed policy blocked this site."
        }
        // ONE-LANE enforcement, structural: scripting an app whose UI this task
        // has already been working on screen abandons work the user is watching
        // (the Keynote title-page incident, 2026-06-11 — prompt rules alone
        // didn't survive failure pressure). Script-FIRST bulk work in an app
        // the agent never touched on screen stays allowed, and the user's own
        // ask for a script overrides.
        if let watchedDenial = await watchedAppHarnessDenialMessageIfNeeded(toolName: name, input: input, goal: goal) {
            return watchedDenial
        }
        let displaySummary = call.displaySummary
        let auditDescriptor = call.auditDescriptor
        let triggerReasons = ComputerUseAgent.actionCriticTriggerReasons(harnessToolName: name)
        if !triggerReasons.isEmpty, let critique = await critiqueHarnessAction(
            name: name,
            displaySummary: displaySummary,
            goal: goal,
            triggerReasons: triggerReasons
        ) {
            switch critique.verdict {
            case .approve:
                break
            case .revise:
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "agent.action.revised",
                    detail: Self.actionCritiqueAuditDetail(toolName: name, verdict: critique.verdict, reason: critique.reason)
                ))
                return "Revise before running \(name): \(critique.saferInstruction ?? critique.reason)"
            case .refuse:
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "agent.action.refused",
                    detail: Self.actionCritiqueAuditDetail(toolName: name, verdict: critique.verdict, reason: critique.reason)
                ))
                return "Blocked by pre-action critic: \(critique.reason)"
            case .askUser:
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "agent.action.ask_user",
                    detail: Self.actionCritiqueAuditDetail(toolName: name, verdict: critique.verdict, reason: critique.reason)
                ))
                return "Pause and ask the user before running \(name): \(critique.reason)"
            }
        }
        if name == "run_applescript" {
            // First AppleScript touch of an app blocks on a macOS Automation
            // consent dialog — without this hint the agent just looks frozen.
            dock.show(title: "Cascade is doing it", detail: "\(name): \(displaySummary) · approve the permission prompt if macOS shows one.")
        } else {
            dock.show(title: "Cascade is doing it", detail: "\(name): \(displaySummary) · press STOP to take control.")
        }
        // Audit BEFORE executing (the audit-first invariant), then flag slow
        // calls in a second row — that's how a consent-dialog stall or a
        // crawling script shows up in the log instead of being invisible.
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "harness.\(name)", detail: auditDescriptor))
        let started = ContinuousClock.now
        let result = await AgentHarness.perform(call, powerEnabled: effectivePowerHarnessEnabled)
        await auditObservationResultIfNeeded(tool: name, result: result)
        let ms = Int(started.duration(to: .now) / .milliseconds(1))
        if ms >= 800 {
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "harness.slow", detail: "\(name) took \(ms)ms - \(auditDescriptor)"))
        }
        return result
    }

    private func critiqueHarnessAction(
        name: String,
        displaySummary: String,
        goal: String,
        triggerReasons: [String]
    ) async -> ActionCritique? {
        guard let critic = assistActionCritic() else { return nil }
        return await critic.critique(ActionCritiqueRequest(
            goal: goal,
            actionSummary: "harness \(name): \(displaySummary)",
            screenSummary: groundingNote() ?? "",
            triggerReasons: triggerReasons
        ))
    }

    private func auditObservationResultIfNeeded(tool: String, result: String) async {
        guard let info = InjectionGuard.envelopeAuditInfo(from: result), info.injectionScore > 0 else { return }
        let detail = Self.observationAuditDescriptor(tool: tool, info: info)
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "trust.untrusted_seen", detail: detail))
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "injection.suspected", detail: detail))
    }

    @discardableResult
    func watchedAppHarnessDenialMessageIfNeeded(
        toolName name: String,
        input: [String: Any],
        goal: String,
        watchedAppActionCounts: [String: Int]? = nil
    ) async -> String? {
        guard name == "run_applescript" || name == "run_command" else { return nil }
        let source = (input["script"] as? String) ?? (input["command"] as? String) ?? ""
        let isScripting = name == "run_applescript" || source.lowercased().contains("osascript")
        guard isScripting, !AppSkill.goalAsksForScript(goal) else { return nil }
        let appActions = watchedAppActionCounts ?? episodeAppActions
        let watched = AgentHarness.scriptedAppTargets(in: source).first { target in
            appActions.contains { app, count in
                count >= 3 && (app.lowercased().contains(target.lowercased())
                    || target.lowercased().contains(app.lowercased()))
            }
        }
        guard let watched else { return nil }
        dock.show(title: "Blocked a script", detail: "\(name) targeting \(watched) — the task stays on screen.")
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent", action: "harness.denied.watched-app", detail: Self.harnessDeniedWatchedAppAuditDetail(toolName: name, watchedApp: watched)
        ))
        return """
        Blocked: you have been doing this task in \(watched)'s own UI on screen, \
        and the user is watching that work — scripting the same app now abandons \
        it mid-flight (one lane per artifact). Finish on screen with clicks, \
        fields, and shortcuts; if an edit went wrong, fix it on screen too. A \
        script here is only allowed when the user's own words ask for one.
        """
    }

    private enum AgentContextSurface: String {
        case assist
        case scout
        case backgroundWeb = "background_web"
    }

    private enum AgentContextAffordanceMode {
        case assist
        case scout
        case none
    }

    /// The per-turn grounding note plus, when the stall guard fired, the firm
    /// "act now or stop" nudge appended so the model can't keep idling.
    private func episodeNote(_ nudge: String?) async -> String? {
        let rendered = await contextPack(goal: assistTaskGoal ?? "", surface: .assist, nudge: nudge, affordanceMode: .assist)
        return rendered.text.isEmpty ? nil : rendered.text
    }

    private func contextPack(
        goal: String,
        surface: AgentContextSurface,
        nudge: String? = nil,
        affordanceMode: AgentContextAffordanceMode
    ) async -> RenderedAgentContextPack {
        let snapshot = AppWindowObserver.snapshot()
        var sections: [AgentContextSection] = []
        func add(
            _ name: String,
            _ body: String?,
            freshness: AgentContextFreshness,
            order: Int,
            maxCharacters: Int? = nil
        ) {
            let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            sections.append(AgentContextSection(
                name: name,
                body: trimmed,
                freshness: freshness,
                order: order,
                maxCharacters: maxCharacters
            ))
        }

        add("conversation", assistMemory.contextMemo(), freshness: .recent, order: 5, maxCharacters: 900)
        switch affordanceMode {
        case .assist:
            add("screen", groundingNote(), freshness: .live, order: 10, maxCharacters: 700)
        case .scout:
            add("screen", scoutContextNote(), freshness: .live, order: 10, maxCharacters: 1_000)
        case .none:
            break
        }
        add("nudge", nudge, freshness: .current, order: 15, maxCharacters: 800)
        add("auto_recall", await autoRecallInitialNote(goal: goal, snapshot: snapshot), freshness: .recent, order: 30, maxCharacters: 1_200)
        add("planning_priors", await planningPriorNote(for: goal, frontmostApp: snapshot.appName), freshness: .historical, order: 40, maxCharacters: 1_000)
        add("trajectory_sketch", await trajectorySketchNote(for: goal, frontmostApp: snapshot.appName), freshness: .historical, order: 50, maxCharacters: 1_200)
        add("failure_reflections", await failureMemoryNote(for: goal, frontmostApp: snapshot.appName), freshness: .historical, order: 60, maxCharacters: 1_000)

        let rendered = AgentContextPack(
            sections: sections,
            budget: AgentContextBudget(totalCharacters: 6_000, perSectionCharacters: 1_200)
        ).render()
        await auditContextPack(rendered, surface: surface)
        return rendered
    }

    private func auditContextPack(_ rendered: RenderedAgentContextPack, surface: AgentContextSurface) async {
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "context_pack.inject",
            detail: "surface=\(Self.safeAuditToken(surface.rawValue)) \(rendered.auditDescriptor)"
        ))
    }

    nonisolated static func routeIntentHeuristic(_ goal: String) -> SourcePlan {
        let normalized = " " + goal.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "ابتثجحخدذرزسشصضطظعغفقكلمنهويءأإآةىؤئ")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        let screenMarkers = [
            " on screen ", " this screen ", " this page ", " visible ", " locate ", " show me ",
            " point ", " highlight ", " what does this say ", " summarize this ", " read this ",
        ]
        let recordMarkers = [
            " earlier ", " yesterday ", " last week ", " last time ", " this morning ",
            " history ", " recorded ", " remember ", " what did ", " what was i ", " did i ",
            " i saw ", " i was reading ", " recap ", " summarize my ",
        ]
        let localMarkers = [
            " file ", " files ", " folder ", " desktop ", " downloads ", " documents ",
            " finder ", " on my mac ", " pdf ", " docx ", " xlsx ", " csv ", " txt ", " md ",
        ]
        let webMarkers = [
            " latest ", " current ", " news ", " weather ", " stock ", " price ", " online ",
            " internet ", " website ", " web ", " google ", " who is ", " what is ", " when is ",
            " how much ", " how many ", " ما هو ", " كم ",
        ]
        let actionMarkers = [
            " click ", " type ", " open ", " create ", " send ", " delete ", " rename ", " move ",
            " update ", " change ", " schedule ", " book ", " fill ", " submit ",
        ]
        let explicitSearchMarkers = [
            " find ", " search ", " look up ", " lookup ", " where is ", " where are ",
            " locate ", " show me ", " ابحث ", " دور ", " وين ", " اين ", " أين ",
        ]
        let cleanQuery = SourceRouter.cleanSearchQuery(goal)
        var sources: [SourceID] = []
        if screenMarkers.contains(where: normalized.contains) { sources.append(.onScreen) }
        if recordMarkers.contains(where: normalized.contains) { sources.append(.recordedMemory) }
        if localMarkers.contains(where: normalized.contains) { sources.append(.localFiles) }
        if webMarkers.contains(where: normalized.contains), !recordMarkers.contains(where: normalized.contains) {
            sources.append(.web)
        }
        if sources.isEmpty, explicitSearchMarkers.contains(where: normalized.contains) {
            sources = [.onScreen, .recordedMemory, .localFiles]
        }
        if sources.isEmpty {
            if actionMarkers.contains(where: normalized.contains) {
                return SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: cleanQuery, reason: "heuristic_action", requiredSource: .action, escalationPolicy: .none)
            }
            return SourcePlan(routingIntent: .noSearch, candidateSources: [], cleanQuery: cleanQuery, reason: "heuristic_no_search", escalationPolicy: .none)
        }
        let intent: SourceIntent
        if sources.count > 1 {
            intent = .mixed
        } else {
            switch sources.first {
            case .onScreen: intent = .locateVisible
            case .recordedMemory: intent = .answerRecord
            case .localFiles: intent = .findFile
            case .web: intent = .webFact
            case .action: intent = .action
            case nil: intent = .noSearch
            }
        }
        return SourcePlan(
            routingIntent: intent,
            candidateSources: sources,
            cleanQuery: cleanQuery,
            reason: "heuristic",
            requiredSource: sources.count == 1 ? sources.first : nil,
            escalationPolicy: sources.contains(.web) ? .ordered : .webIfUnsupported,
            stopPolicy: .firstSupported
        )
    }

    nonisolated static func routeNeedsSourceEvidence(_ plan: SourcePlan) -> Bool {
        switch plan.routingIntent {
        case .answerRecord, .findFile, .webFact, .instructionalWithRecordDependency, .mixed, .ambiguous:
            return plan.candidateSources.contains { $0 == .recordedMemory || $0 == .localFiles || $0 == .web }
        case .locateVisible:
            return false
        case .action, .noSearch:
            return false
        }
    }

    nonisolated static func routeCanAnswerWithoutCU(_ plan: SourcePlan) -> Bool {
        routeNeedsSourceEvidence(plan) && !plan.candidateSources.contains(.onScreen)
    }

    nonisolated static func sourceRouteAuditDetail(goal: String, plan: SourcePlan, status: String = "planned") -> String {
        [
            "status=\(safeAuditToken(status))",
            textAuditDetail("goal", goal),
            textAuditDetail("cleanQuery", plan.cleanQuery),
            textAuditDetail("reason", plan.reason),
            "intent=\(safeAuditToken(plan.routingIntent.rawValue))",
            "sources=\(plan.candidateSources.map { safeAuditToken($0.rawValue) }.joined(separator: ","))",
            "required=\(safeAuditToken(plan.requiredSource?.rawValue ?? "none"))",
            "escalation=\(safeAuditToken(plan.escalationPolicy.rawValue))",
            "stop=\(safeAuditToken(plan.stopPolicy.rawValue))",
        ].joined(separator: " ")
    }

    nonisolated static func sourceEvidenceAuditDetail(_ bundle: SourceEvidenceBundle) -> String {
        let evidence = bundle.sourcePlan.candidateSources.compactMap { bundle.evidenceBySource[$0] }
        let states = evidence.map { "\($0.source.rawValue):\($0.state.rawValue):\($0.resultCount):\($0.citationIDs.count):\($0.contentHash)" }
            .joined(separator: "|")
        return [
            textAuditDetail("cleanQuery", bundle.query),
            "sourceCount=\(bundle.sourcePlan.candidateSources.count)",
            "checkedCount=\(evidence.filter { $0.state != .notChecked }.count)",
            "supportedCount=\(evidence.filter { $0.state == .checkedSupported }.count)",
            "stateHash=\(auditHash(states))",
            evidence.map(\.auditDescriptor).joined(separator: " | "),
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated static func searchSufficiencyNudge(routeHint: SearchRouteHint?) -> String {
        var lines = [
            "You tried to finish a search-shaped task without searching any source. Pick the cheapest matching resource and actually search before finishing.",
            "Resource catalog:",
            ComputerUseAgent.resourceCatalogNote(harnessTier: .readOnly, recallEnabled: true),
        ]
        if let routeHint {
            lines.append("Route hint: intent=\(routeHint.routingIntent.rawValue), sources=\(routeHint.candidateSources.map(\.rawValue).joined(separator: ",")), cleanQuery=\(routeHint.cleanQuery)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func assistSearchUngatedAuditDetail(
        goal: String,
        routeHint: SearchRouteHint?,
        status: String
    ) -> String {
        var parts = [
            "status=\(safeAuditToken(status))",
            textAuditDetail("goal", goal),
        ]
        if let routeHint {
            parts.append("intent=\(safeAuditToken(routeHint.routingIntent.rawValue))")
            parts.append("sources=\(routeHint.candidateSources.map { safeAuditToken($0.rawValue) }.joined(separator: ","))")
            parts.append(textAuditDetail("cleanQuery", routeHint.cleanQuery))
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func classifyAssistBackgroundWebUpdate(
        task: String,
        update: BackgroundWebAgent.Update
    ) -> AssistBackgroundWebResult {
        if update.completed, let result = update.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .finding(AgentTaskFinding(task: task, result: result))
        }
        if update.needsLogin {
            return .pause(update.result ?? update.status)
        }
        if update.done {
            return .pause((update.result?.isEmpty == false ? update.result : nil) ?? update.status)
        }
        return .unavailable
    }

    func initialAssistNote(goal: String) async -> String? {
        let rendered = await contextPack(goal: goal, surface: .assist, affordanceMode: .assist)
        return rendered.text.isEmpty ? nil : rendered.text
    }

    private func autoRecallInitialNote(goal: String, snapshot: AppWindowSnapshot) async -> String? {
        guard Self.experimentalAutoRecallEnabled(defaults: defaultsStore) else { return nil }
        let baseContext = AutoRecallQueryContext(
            goal: goal,
            frontmostAppName: snapshot.appName,
            frontmostBundleIdentifier: snapshot.bundleIdentifier,
            currentWindowTitle: snapshot.windowTitle
        )
        guard capturePrivacyPolicy.recordRecallAvailable else {
            let result = AutoRecallResult.blocked(context: baseContext, status: "record_recall_unavailable")
            await auditAutoRecall(result)
            return nil
        }
        let queryContext = AutoRecallQueryContext(
            goal: goal,
            frontmostAppName: snapshot.appName,
            frontmostBundleIdentifier: snapshot.bundleIdentifier,
            currentWindowTitle: snapshot.windowTitle,
            recentWindowTitles: await autoRecallRecentWindowTitles()
        )
        let result = await AutoRecallContextBuilder(
            store: store,
            privacyPolicy: capturePrivacyPolicy
        ).build(context: queryContext)
        await auditAutoRecall(result)
        return result.block
    }

    private func autoRecallRecentWindowTitles(limit: Int = 20) async -> [String] {
        let rows = (try? await store.recentContexts(limit: limit)) ?? []
        var titles: [String] = []
        var seen: Set<String> = []
        for row in rows {
            guard row.safeToShow, row.safeToSummarize else { continue }
            guard !PrivacyRules.isSensitive(row) else { continue }
            guard capturePrivacyPolicy.decision(
                appName: row.appName,
                bundleIdentifier: row.bundleIdentifier,
                windowTitle: row.windowTitle,
                text: row.ocrText
            ).allowed else { continue }
            guard let title = row.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            titles.append(title)
            if titles.count >= 8 { break }
        }
        return titles
    }

    private func auditAutoRecall(_ result: AutoRecallResult) async {
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "recall.inject",
            detail: Self.autoRecallAuditDetail(result)
        ))
    }

    private func initialScoutNote(goal: String) async -> String? {
        let rendered = await contextPack(goal: goal, surface: .scout, affordanceMode: .scout)
        return rendered.text.isEmpty ? nil : rendered.text
    }

    private func planningPriorNote(for goal: String, frontmostApp: String?) async -> String? {
        guard defaultsStore.bool(forKey: Self.experimentalWorkGraphIndexKey) else { return nil }
        for skill in appSkills.skills.prefix(80) {
            _ = try? await skill.indexPlanningMetadata(in: store)
        }
        let priors = (try? await store.planningPriors(goal: goal, appName: frontmostApp, limit: 5)) ?? []
        guard !priors.isEmpty else { return nil }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "agent.work_graph.priors",
            detail: "count=\(priors.count) priorHash=\(Self.auditHash(priors.map { "\($0.kind.rawValue):\($0.canonicalValue):\($0.relation)" }.joined(separator: "|")))"
        ))
        let lines = priors.map { prior -> String in
            let direction = prior.weight < 0 ? "avoid" : "prefer"
            return "- \(direction) \(prior.kind.rawValue) \(prior.displayName) via \(prior.relation)"
        }
        return """
        WORK GRAPH PLANNING PRIORS
        Use these as hints only; live screen evidence wins.
        \(lines.joined(separator: "\n"))
        """
    }

    private func trajectorySketchNote(for goal: String, frontmostApp: String?) async -> String? {
        guard defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey) else { return nil }
        let successes = (try? await store.agentExperienceCases(
            matching: AgentExperienceQuery(outcome: .success),
            limit: 80
        )) ?? []
        let agents = (try? await store.agents()) ?? []
        guard !agents.isEmpty else { return nil }

        let builder = TrajectorySketchBuilder(maxActions: 6, maxAnchors: 4, maxChecks: 3, maxCorrections: 2)
        let agentsBySignature = Dictionary(grouping: agents, by: \.signature)
        let sketches = successes.compactMap { experience -> TrajectorySketch? in
            guard !PrivacyRules.isSensitiveText(experience.goalPattern),
                  let agent = agentsBySignature[experience.recipeSignature]?.first,
                  !PrivacyRules.isSensitiveText(agent.name),
                  agent.goal.map(PrivacyRules.isSensitiveText) != true else {
                return nil
            }
            return builder.build(
                goal: Self.experienceGoalPattern(for: agent, fallback: experience.goalPattern),
                recipe: agent.recipe,
                experiences: [experience]
            )
        }
        var candidates: [(id: String, appName: String, promptText: String, actionCount: Int, anchorCount: Int, checkCount: Int, score: Double)] = []
        for sketch in builder.rank(sketches, appName: frontmostApp, goal: goal) {
            candidates.append((
                id: sketch.id,
                appName: sketch.appName,
                promptText: sketch.promptText,
                actionCount: sketch.firstActions.count,
                anchorCount: sketch.safeAnchors.count,
                checkCount: sketch.expectedChecks.count,
                score: sketch.relevanceScore(appName: frontmostApp, goal: goal)
            ))
        }
        let queryTokens = Set(TrajectorySketch.normalizedGoalTokens(from: goal))
        for agent in agents where !PrivacyRules.isSensitiveText(agent.name) && agent.goal.map(PrivacyRules.isSensitiveText) != true {
            for demo in agent.demoSketches {
                candidates.append((
                    id: demo.id,
                    appName: demo.appName,
                    promptText: demo.promptText,
                    actionCount: demo.actionCount,
                    anchorCount: demo.anchorCount,
                    checkCount: demo.checkCount,
                    score: demo.relevanceScore(appName: frontmostApp, goalTokens: queryTokens)
                ))
            }
        }
        guard let selected = candidates
            .filter({ $0.score > 0.05 })
            .sorted(by: { lhs, rhs in
                if lhs.score == rhs.score { return lhs.id < rhs.id }
                return lhs.score > rhs.score
            })
            .first
        else { return nil }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "agent.trajectory_sketch",
            detail: Self.trajectorySketchAuditDetail(
                sketchID: selected.id,
                appName: selected.appName,
                actionCount: selected.actionCount,
                anchorCount: selected.anchorCount,
                checkCount: selected.checkCount,
                score: selected.score
            )
        ))
        return """
        PRIOR SUCCESSFUL LOCAL DEMO
        Use this compact replay sketch as a hint, not as proof. Re-ground each target on the live screen before acting.
        \(String(selected.promptText.prefix(1200)))
        """
    }

    private func failureMemoryNote(for goal: String, frontmostApp: String?) async -> String? {
        guard defaultsStore.bool(forKey: Self.experimentalExperienceLedgerKey) else { return nil }
        let appName = Self.normalizedFrontmostApp(frontmostApp)
        let memories = (try? await store.agentFailureMemories(
            matching: AgentFailureMemoryQuery(appName: appName),
            limit: 40
        )) ?? []
        guard !memories.isEmpty else { return nil }
        let queryTokens = Set(TrajectorySketch.normalizedGoalTokens(from: goal))
        let ranked = memories
            .map { memory in (memory: memory, score: Self.failureMemoryScore(memory, queryTokens: queryTokens, frontmostApp: appName)) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score == $1.score { return $0.memory.createdAt > $1.memory.createdAt }
                return $0.score > $1.score
            }
            .prefix(2)
        guard !ranked.isEmpty else { return nil }
	        let selected = ranked.map(\.memory)
	        _ = try? await store.markAgentFailureMemoriesUsed(ids: selected.map(\.id))
	        _ = try? await store.appendAudit(AuditEvent(
	            actor: "agent",
	            action: "agent.failure_memory.used",
            detail: Self.failureMemoryUsedAuditDetail(selected)
        ))
        var lines = ["FAILURE REFLECTIONS"]
        for memory in selected {
            let action = memory.firstBadAction.map { " after \($0)" } ?? ""
            let state = memory.stateSummary.map { " state: \($0)." } ?? ""
            lines.append("- prior \(memory.failureKind.rawValue)\(action): \(Self.failureSpecificMemoryNote(for: memory.failureKind)) \(memory.repairHint)\(state)")
        }
        return lines.joined(separator: "\n")
    }

    /// Validator stage (Phase 1) — a fresh-evidence second opinion on the model's
    /// "done", ported from the background agent's `verifyCompletion`. The model's
    /// claim is NOT trusted on its own (the audited "declared done but didn't"
    /// case); a fresh screenshot is OCR'd and a cheap verifier judges ONLY that
    /// evidence — never the agent's narration (narration-judges over-report). On a
    /// CLEAR mismatch the run is downgraded to `.stalled` and the user is told what's
    /// missing; doubt leans accept so genuine wins still pass.
    ///
    /// Gated OFF by default (`cascade.assistValidator`): it adds a capture + OCR +
    /// model round trip to the END of a finished run, which is latency on the
    /// watched success path Opus rarely needs. It is the reliability net for a
    /// downgraded thinker (Phase 3), which false-completes far more — build it now,
    /// switch it on then. See [[cascade-cu-downgrade-research]].
    private func validateAssistCompletion(goal: String, claimed: String, screen: NSScreen, force: Bool = false) async -> String? {
        guard (force || UserDefaults.standard.bool(forKey: "cascade.assistValidator")), hasAnthropicKey else { return nil }
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else { return nil }
        let onScreen = await ScreenTextRecognizer.recognize(inPNG: shot)
        // Can't judge a screen we couldn't read (sparse OCR / canvas app) → accept
        // rather than false-fail a real win.
        if onScreen.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 { return nil }
        let user = """
        An on-screen assistant was asked to: \(goal)
        When it claimed DONE it said: \(claimed)
        The text now visible on the user's screen:
        \(onScreen.prefix(2800))

        Judging ONLY by what's on screen, did it ACTUALLY accomplish the task — is the \
        result the task wanted genuinely there (the slide built and filled, the message \
        sent, the value entered, the file shown)? If yes, or if you're not sure, reply \
        exactly: VERIFIED. Only if the screen CLEARLY shows it is not done reply: \
        INCOMPLETE: <one short line on what's missing>
        """
        // Downgraded helper task: Groq llama-3.3-70b when a key is set, else
        // Anthropic haiku. The validator judges OCR TEXT, so no vision is needed.
        let h = TextHelperModel.resolve()
        guard let reply = try? await h.client.complete(
            system: "You verify whether an on-screen assistant truly finished its task, judging only by what is visible on screen now. Lean VERIFIED unless it's clearly not done.",
            user: user, model: h.model, maxTokens: 120
        ) else { return nil }  // verifier unavailable → never block a completion
        return Self.parseAssistVerdict(reply)
    }

    private func collectEvidence(for sourcePlan: SourcePlan) async -> SourceEvidenceBundle {
        var bundle = SourceEvidenceBundle(query: sourcePlan.cleanQuery, sourcePlan: sourcePlan)
        if sourcePlan.candidateSources.contains(.recordedMemory) {
            if capturePrivacyPolicy.recordRecallAvailable {
                let result = await RecordRecall(store: store).perform(.search(query: sourcePlan.cleanQuery))
                bundle.set(
                    SourceEvidence.fromToolResult(result, source: .recordedMemory, defaultTool: "search_record"),
                    text: result
                )
            } else {
                bundle.set(.unavailable(source: .recordedMemory, tool: "search_record", statusKind: "record_recall_unavailable"))
            }
        }
        if sourcePlan.candidateSources.contains(.localFiles) {
            let search = await AgentHarness.perform(
                .searchFiles(query: sourcePlan.cleanQuery, folder: nil),
                powerEnabled: false
            )
            var fileText = search
            var fileEvidence = SourceEvidence.fromToolResult(search, source: .localFiles, defaultTool: "search_files")
            if fileEvidence.state == .checkedSupported, let path = Self.firstConcreteLocalPath(from: search) {
                let read = await AgentHarness.perform(.readFile(path: path), powerEnabled: false)
                fileText += "\n\n" + read
                let readEvidence = SourceEvidence.fromToolResult(read, source: .localFiles, defaultTool: "read_file")
                if readEvidence.state == .checkedSupported || fileEvidence.state != .checkedSupported {
                    fileEvidence = readEvidence
                }
            }
            bundle.set(fileEvidence, text: fileText)
        }
        if sourcePlan.candidateSources.contains(.web), !capturePrivacyPolicy.backgroundWebRunsAvailable {
            bundle.set(.unavailable(source: .web, tool: "browser", statusKind: "background_web_unavailable"))
        }
        return bundle
    }

    private func reviewEvidence(plan: SourcePlan, evidence bundle: SourceEvidenceBundle) async -> SearchEvidenceVerdict {
        let requiredSupported = plan.requiredSource.flatMap { bundle.evidenceBySource[$0]?.state == .checkedSupported } ?? false
        if plan.stopPolicy == .requireRequiredSource, requiredSupported {
            return .sufficient
        }
        guard bundle.hasEvidence else {
            if bundle.evidenceBySource.values.contains(where: { $0.state == .checkedNoEvidence || $0.state == .unavailable || $0.state == .refused }) {
                return .insufficient
            }
            return .abstain
        }
        guard hasAnthropicKey else { return .sufficient }
        let user = """
        Query:
        \(bundle.query)

        Candidate evidence:
        \(bundle.combinedText.prefix(3600))

        Does the evidence directly answer the query enough to avoid a web search?
        Reply with exactly one token: SUFFICIENT, INSUFFICIENT, or ABSTAIN.
        """
        let h = TextHelperModel.resolve()
        let options = AnthropicCompletionOptions.deterministic(
            promptVersion: "assist-search-evidence.prompt.v1",
            schemaVersion: "assist-search-evidence.schema.v1",
            callsite: "CascadeAppModel.searchEvidenceJudge"
        )
        guard let reply = try? await h.client.complete(
            system: "Judge whether local search evidence is enough. Do not answer the user's query; only classify evidence sufficiency.",
            user: user,
            model: h.model,
            maxTokens: 20,
            options: options
        ) else { return .abstain }
        return SearchEvidenceVerdict.parse(reply)
    }

    nonisolated static func shouldEscalateSearchToWeb(routeHint: SearchRouteHint, verdict: SearchEvidenceVerdict) -> Bool {
        routeHint.allowsWeb && verdict != .sufficient
    }

    nonisolated static func shouldPreferBackgroundWeb(routeHint: SearchRouteHint) -> Bool {
        routeHint.candidateSources.first == .web || routeHint.routingIntent == .web
    }

    nonisolated static func webRequired(_ routeHint: SearchRouteHint) -> Bool {
        routeHint.requiredSource == .web
            || routeHint.routingIntent == .webFact
            || (routeHint.candidateSources.first == .web && routeHint.stopPolicy == .requireRequiredSource)
    }

    private func runAssistBackgroundWebSearch(
        subtask: AgentSubtask,
        routeHint: SearchRouteHint
    ) async -> AssistBackgroundWebResult {
        guard Self.shouldPreferBackgroundWeb(routeHint: routeHint) || routeHint.allowsWeb else { return .unavailable }
        guard capturePrivacyPolicy.backgroundWebRunsAvailable else { return .unavailable }
        if let reason = capturePrivacyPolicy.deniedURLReason(in: subtask.task) {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "policy",
                action: "policy.enforced",
                detail: Self.policyDecisionAuditDetail(capability: "background_web_run", decision: "blocked", reason: reason)
            ))
            return .unavailable
        }
        guard hasAnthropicKey, trustedAuditHistoryForSensitiveAction(),
              sandboxRuntimes.count < Self.maxConcurrentSandboxAgents else {
            return .unavailable
        }
        let id = UUID()
        let runtime = configuredBackgroundWebAgent(id: id, attachCursor: false)
        sandboxRuntimes[id] = runtime
        defer { sandboxRuntimes[id] = nil }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "assist.search.web",
            detail: Self.assistSearchUngatedAuditDetail(goal: subtask.task, routeHint: routeHint, status: "background_start")
        ))
        var terminal: BackgroundWebAgent.Update?
        await runtime.run(task: subtask.task) { update in
            if update.done { terminal = update }
        }
        guard let terminal else { return .unavailable }
        var evidence = SourceEvidenceBundle(query: routeHint.cleanQuery, sourcePlan: routeHint)
        let terminalText = (terminal.result?.isEmpty == false ? terminal.result : nil) ?? terminal.status
        if terminal.completed, !terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidence.set(SourceEvidence.fromToolResult(terminalText, source: .web, defaultTool: "browser"))
        } else {
            evidence.set(SourceEvidence(source: .web, state: .checkedInsufficient, tool: "browser", statusKind: terminal.needsLogin ? "needs_login" : "not_completed", contentHash: Self.auditHash(terminalText), contentCharCount: terminalText.count))
        }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "source.evidence",
            detail: Self.sourceEvidenceAuditDetail(evidence)
        ))
        return Self.classifyAssistBackgroundWebUpdate(task: subtask.task, update: terminal)
    }

    nonisolated static func firstConcreteLocalPath(from searchResult: String) -> String? {
        for rawLine in searchResult.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("status="), !line.hasPrefix("No files matched") else { continue }
            if line.hasPrefix("/") || line.hasPrefix("~") {
                let path = line.replacingOccurrences(of: "…", with: "")
                guard path.range(of: #"\s+\d+ more\.?$"#, options: .regularExpression) == nil else { continue }
                return path
            }
        }
        return nil
    }

    private func runNoEffectVerifier(
        goal: String,
        lastAction: String,
        screenshot: Data,
        turn: Int,
        engine: String
    ) async -> String? {
        guard hasAnthropicKey else { return nil }
        let context = [scoutGroundingNote(), groundingNote()].compactMap { $0 }.joined(separator: "\n")
        guard let result = try? await NoEffectVerifier().verify(
            goal: goal,
            lastAction: lastAction,
            currentScreenshotJPEG: screenshot,
            visibleContext: context.isEmpty ? nil : context
        ) else { return nil }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "assist.noeffect.verifier",
            detail: Self.noEffectVerifierAuditDetail(turn: turn, engine: engine, result: result)
        ))
        let appName = AppWindowObserver.snapshot().appName
        await recordReflectionFailureMemory(
            appName: appName,
            goal: goal,
            failureKind: .noEffect,
            firstBadAction: lastAction,
            stateSummary: result.state,
            repairHint: "\(result.nextStrategy) Avoid: \(result.avoid)",
            recoveryEvidenceSeed: "noEffect|\(engine)|\(result.state)|\(result.nextStrategy)"
        )
        return "Verifier state: \(result.state). Next: \(result.nextStrategy). Avoid: \(result.avoid)."
    }

    private func runVisualStateVerifier(
        goal: String,
        risky: RiskyVisualGroundingClick,
        screenshot: Data,
        turn: Int,
        engine: String
    ) async -> String? {
        guard hasAnthropicKey else {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "assist.verify_state",
                detail: Self.visualStateVerifierUnavailableAuditDetail(turn: turn, engine: engine, risky: risky)
            ))
            return nil
        }
        let context = [scoutGroundingNote(), groundingNote()].compactMap { $0 }.joined(separator: "\n")
        guard let result = try? await VisualStateVerifier().verify(
            goal: goal,
            clickTarget: risky.target,
            expectedState: Self.expectedVisualState(for: risky),
            currentScreenshotJPEG: screenshot,
            visibleContext: context.isEmpty ? nil : context
        ) else {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "assist.verify_state",
                detail: Self.visualStateVerifierUnavailableAuditDetail(turn: turn, engine: engine, risky: risky)
            ))
            return nil
        }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "assist.verify_state",
            detail: Self.visualStateVerifierAuditDetail(turn: turn, engine: engine, risky: risky, result: result)
        ))
        guard result.verdict == .negative else { return nil }
        let appName = AppWindowObserver.snapshot().appName
        await recordReflectionFailureMemory(
            appName: appName,
            goal: goal,
            failureKind: .groundingMiss,
            firstBadAction: "visual click",
            targetHash: Self.auditHash(risky.target),
            stateSummary: result.state,
            repairHint: result.nextStrategy,
            recoveryEvidenceSeed: "visualState|\(engine)|\(Self.auditHash(risky.target))|\(result.state)"
        )
        return "Visual check: \(result.state). Try: \(result.nextStrategy)."
    }

    private static func expectedVisualState(for risky: RiskyVisualGroundingClick) -> String {
        switch risky.risk {
        case .destructive:
            return "A confirmation, submitted state, sent item, navigation, or visible destructive-action result should appear."
        case .high:
            return "The intended menu, edit mode, context menu, or opened item should appear."
        case .visual, .normal:
            return "The clicked control should visibly focus, open, navigate, or change state."
        }
    }

    nonisolated static func actionSummary(_ actions: [CUAction]) -> String {
        let labels = actions.prefix(4).map { action -> String in
            switch action {
            case .move(let x, let y): return "move \(Int(x)),\(Int(y))"
            case .click(let x, let y): return "click \(Int(x)),\(Int(y))"
            case .doubleClick(let x, let y): return "double_click \(Int(x)),\(Int(y))"
            case .tripleClick(let x, let y): return "triple_click \(Int(x)),\(Int(y))"
            case .rightClick(let x, let y): return "right_click \(Int(x)),\(Int(y))"
            case .drag: return "drag"
            case .type(let text): return "type \(text.prefix(24))"
            case .key(let key): return "key \(key)"
            case .scroll(_, _, let direction, let amount): return "scroll \(direction) \(amount)"
            case .wait: return "wait"
            case .screenshot: return "screenshot"
            case .openApp(let name): return "open_app \(name)"
            case .openURL(let url): return "open_url \(url.prefix(48))"
            case .zoom: return "zoom"
            case .highlight(_, _, _, _, let label): return "highlight \(label)"
            }
        }
        return labels.isEmpty ? "no executable action" : labels.joined(separator: "; ")
    }

    /// Parses the validator's reply: an INCOMPLETE reason, or nil to accept
    /// (VERIFIED / unclear / empty all accept). Pure + pinned. Mirrors the
    /// background agent's verdict parse.
    nonisolated static func parseAssistVerdict(_ reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("INCOMPLETE") else { return nil }
        let reason = trimmed.dropFirst("INCOMPLETE".count)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
        return reason.isEmpty ? "the screen doesn't show the task was completed" : reason
    }

    /// One line of text grounding sent with every frame: which app and window are
    /// frontmost. ~15 tokens that prevent which-app-am-I-in mistakes. When a skill
    /// covers the frontmost app, a one-line nudge points at it — the content itself
    /// is pulled by the agent through use_skill, never pushed.
    private func groundingNote() -> String? {
        let snapshot = AppWindowObserver.snapshot()
        guard snapshot.appName != "Unknown app" else { return nil }
        var note: String
        if let title = snapshot.windowTitle, !title.isEmpty {
            note = "Frontmost app: \(snapshot.appName) — “\(title)”"
        } else {
            note = "Frontmost app: \(snapshot.appName)"
        }
        if let skill = appSkills.skill(appName: snapshot.appName, bundleIdentifier: snapshot.bundleIdentifier) {
            note += "\nSkill “\(skill.name)” covers this app — pull it with use_skill before acting here, if you haven't already."
        }
        return note
    }

    /// Frontmost app + window line for the Scout path. Unlike `groundingNote()` it
    /// omits the use_skill nudge — Scout has no use_skill tool (its matched skill is
    /// PUSHED into the prompt), and dangling "use_skill" text would waste a turn.
    private func scoutGroundingNote() -> String? {
        let snapshot = AppWindowObserver.snapshot()
        guard snapshot.appName != "Unknown app" else { return nil }
        if let title = snapshot.windowTitle, !title.isEmpty {
            return "Frontmost app: \(snapshot.appName) — “\(title)”"
        }
        return "Frontmost app: \(snapshot.appName)"
    }

    /// Formats the proactive Set-of-Marks controls push from a harvested summary.
    /// nil when there's nothing on screen (canvas/Electron). Shared by the first
    /// turn (`scoutContextNote`) and each subsequent turn so the listing is identical.
    private func scoutControlsLine(_ summary: String?) -> String? {
        summary.map { "Controls on screen now (name one of these to click or fill, or open a menu/panel to reveal others): \($0)" }
    }

    /// The first turn's pushed context for Scout: frontmost app/window + the controls
    /// actually on screen. Subsequent turns rebuild the same shape inline (reusing a
    /// single AX harvest alongside the no-effect/miss feedback).
    private func scoutContextNote() -> String? {
        let controlSummary = AXElementResolver.interactableSummary(AXElementResolver.interactables(limit: 24))
        let parts = [scoutGroundingNote(), scoutControlsLine(controlSummary)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// OCR Set-of-Marks for the planner on canvas / sparse-AX surfaces. When the AX
    /// walk found few controls (Keynote slide canvas, Blender, design tools), OCR the
    /// current frame OFF-MAIN and hand Scout the on-screen TEXT as nameable targets —
    /// the structural fix for "the planner assumes what's on the page". ON by default
    /// (it fires only where AX is blind, so it's purely additive there); disable with
    /// `cascade.ocrSetOfMarks = false`. Audited as `scout.ocr.marks`.
    private func ocrSetOfMarks(forFrame frame: Data, axControlCount: Int, turn: Int) async -> String? {
        // Browsers are text-heavy and DOM-native (the background agent owns the web),
        // so OCR there dumps page text as noise. Fire only on canvas / non-AX NATIVE
        // surfaces (Keynote slide canvas, Blender) where the planner is truly blind.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        let isBrowser = front.map { Self.runsInBackground(apps: [$0]) } ?? false
        guard (UserDefaults.standard.object(forKey: "cascade.ocrSetOfMarks") as? Bool) ?? true,
              Self.shouldOcrSetOfMarks(axControlCount: axControlCount, isBrowser: isBrowser) else { return nil }
        let boxes = await Task.detached { ScreenTextRecognizer.recognizeBoxes(inImageData: frame) }.value
        guard let marks = ScreenTextRecognizer.setOfMarks(boxes) else { return nil }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent", action: "scout.ocr.marks",
            detail: Self.ocrMarksAuditDetail(
                turn: turn,
                axControlCount: axControlCount,
                ocrLineCount: boxes.count,
                marks: marks
            )
        ))
        return marks
    }

    nonisolated static func assistNoEffectAuditDetail(
        turn: Int,
        status: String,
        noEffectStreak: Int,
        recoveryAction: RecoveryAction? = nil,
        controlCount: Int? = nil,
        labels: String? = nil,
        coords: String? = nil,
        ocrLineCount: Int = 0,
        ocrMarks: String? = nil
    ) -> String {
        [
            "turn=\(turn)",
            "status=\(safeAuditToken(status))",
            "noEffectStreak=\(noEffectStreak)",
            "recoveryAction=\(safeAuditToken((recoveryAction ?? Self.recoveryAction(for: AgentOrchestrator.AgentFailureKind.noEffect, attempt: noEffectStreak)).rawValue))",
            "controlCount=\(controlCount.map(String.init) ?? "not-collected")",
            "labelsHash=\(auditHash(labels))",
            "coordsHash=\(auditHash(coords))",
            "ocrLineCount=\(ocrLineCount)",
            "ocrMarksHash=\(auditHash(ocrMarks))",
        ].joined(separator: " ")
    }

    nonisolated static func noEffectVerifierAuditDetail(
        turn: Int,
        engine: String,
        result: NoEffectVerifierResult
    ) -> String {
        [
            "turn=\(turn)",
            "engine=\(safeAuditToken(engine))",
            textAuditDetail("state", result.state),
            textAuditDetail("nextStrategy", result.nextStrategy),
            textAuditDetail("avoid", result.avoid),
        ].joined(separator: " ")
    }

    nonisolated static func visualStateVerifierAuditDetail(
        turn: Int,
        engine: String,
        risky: RiskyVisualGroundingClick,
        result: VisualStateVerifierResult
    ) -> String {
        [
            "turn=\(turn)",
            "engine=\(safeAuditToken(engine))",
            "verdict=\(safeAuditToken(result.verdict.rawValue))",
            "source=\(safeAuditToken(risky.source.rawValue))",
            "risk=\(safeAuditToken(risky.risk.rawValue))",
            "confidence=\(String(format: "%.2f", risky.confidence))",
            "dispersion=\(risky.dispersion.map { String(format: "%.1f", $0) } ?? "none")",
            "targetHash=\(auditHash(risky.target))",
            textAuditDetail("state", result.state),
            textAuditDetail("nextStrategy", result.nextStrategy),
        ].joined(separator: " ")
    }

    nonisolated static func visualStateVerifierUnavailableAuditDetail(
        turn: Int,
        engine: String,
        risky: RiskyVisualGroundingClick
    ) -> String {
        [
            "turn=\(turn)",
            "engine=\(safeAuditToken(engine))",
            "verdict=unavailable",
            "source=\(safeAuditToken(risky.source.rawValue))",
            "risk=\(safeAuditToken(risky.risk.rawValue))",
            "confidence=\(String(format: "%.2f", risky.confidence))",
            "targetHash=\(auditHash(risky.target))",
        ].joined(separator: " ")
    }

    nonisolated static func groundMissAuditDetail(
        turn: Int,
        missedTarget: String,
        controlCount: Int,
        labels: String?
    ) -> String {
        [
            "turn=\(turn)",
            "missedTargetHash=\(auditHash(missedTarget))",
            "controlCount=\(controlCount)",
            "labelsHash=\(auditHash(labels))",
        ].joined(separator: " ")
    }

    nonisolated static func actionCritiqueAuditDetail(
        toolName: String,
        verdict: ActionCritique.Verdict,
        reason: String,
        failureKind: CascadeMemory.AgentFailureKind? = .unsafeAction
    ) -> String {
        var parts = [
            "tool=\(safeAuditToken(toolName))",
            "verdict=\(safeAuditToken(verdict.rawValue))",
            "failureKind=\(safeAuditToken(failureKind?.rawValue ?? "unsafe_action"))",
            "recoveryAction=\(safeAuditToken(AgentRecoveryPolicy.plan(for: .unsafeActionRefused).terminal.rawValue))",
            textAuditDetail("reason", reason),
        ]
        return parts.joined(separator: " ")
    }

    nonisolated static func assistPlanAuditDetail(_ plan: AgentTaskPlan) -> String {
        [
            "planID=\(safeAuditToken(plan.id))",
            "subgoalCount=\(plan.subtasks.count)",
            "taskHash=\(auditHash(plan.originalTask))",
            "risk=\(plan.subtasks.map { safeAuditToken($0.risk.rawValue) }.joined(separator: ","))",
            "effectsHash=\(auditHash(plan.subtasks.flatMap { $0.expectedEffects.map(\.auditLabel) }.joined(separator: "|")))",
        ].joined(separator: " ")
    }

    nonisolated static func assistSubgoalAuditDetail(
        index: Int,
        total: Int,
        subtask: AgentSubtask,
        status: String,
        failureKind: AgentOrchestrator.AgentFailureKind? = nil,
        reason: String? = nil
    ) -> String {
        var parts = [
            "index=\(index + 1)",
            "total=\(total)",
            "status=\(safeAuditToken(status))",
            "taskHash=\(auditHash(subtask.task))",
            "risk=\(safeAuditToken(subtask.risk.rawValue))",
            "effectsHash=\(auditHash(subtask.expectedEffects.map(\.auditLabel).joined(separator: "|")))",
        ]
        if let failureKind {
            parts.append("failureKind=\(safeAuditToken(failureKind.rawValue))")
        }
        if let reason {
            parts.append(textAuditDetail("reason", reason))
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func ocrMarksAuditDetail(
        turn: Int,
        axControlCount: Int,
        ocrLineCount: Int,
        marks: String
    ) -> String {
        [
            "turn=\(turn)",
            "controlCount=\(axControlCount)",
            "ocrLineCount=\(ocrLineCount)",
            "ocrMarksHash=\(auditHash(marks))",
        ].joined(separator: " ")
    }

    nonisolated static func trajectorySketchAuditDetail(sketch: TrajectorySketch, score: Double) -> String {
        trajectorySketchAuditDetail(
            sketchID: sketch.id,
            appName: sketch.appName,
            actionCount: sketch.firstActions.count,
            anchorCount: sketch.safeAnchors.count,
            checkCount: sketch.expectedChecks.count,
            score: score
        )
    }

    nonisolated static func trajectorySketchAuditDetail(
        sketchID: String,
        appName: String,
        actionCount: Int,
        anchorCount: Int,
        checkCount: Int,
        score: Double
    ) -> String {
        [
            "score=\(String(format: "%.2f", score))",
            "sketchHash=\(auditHash(sketchID))",
            "appHash=\(auditHash(appName))",
            "actionCount=\(actionCount)",
            "anchorCount=\(anchorCount)",
            "checkCount=\(checkCount)",
        ].joined(separator: " ")
    }

    nonisolated static func failureMemoryUsedAuditDetail(_ memories: [AgentFailureMemory]) -> String {
        [
            "count=\(memories.count)",
            "ids=\(memories.map { String($0.id) }.joined(separator: ","))",
            "failureKinds=\(memories.map { safeAuditToken($0.failureKind.rawValue) }.joined(separator: ","))",
            "memoryHash=\(auditHash(memories.map { "\($0.id):\($0.failureKind.rawValue)" }.joined(separator: "|")))",
        ].joined(separator: " ")
    }

    nonisolated static func failureMemoryCounterexampleAuditDetail(_ memory: AgentFailureMemory) -> String {
        [
            "id=\(memory.id)",
            "failureKind=\(safeAuditToken(memory.failureKind.rawValue))",
            "remainingCounterexamples=\(memory.remainingCounterexamples)",
            "expired=\(memory.expiredAt != nil)",
        ].joined(separator: " ")
    }

    nonisolated static func normalizedFrontmostApp(_ appName: String?) -> String? {
        guard let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty,
              appName != "Unknown app" else {
            return nil
        }
        return appName
    }

    nonisolated static func failureMemoryScore(
        _ memory: AgentFailureMemory,
        queryTokens: Set<String>,
        frontmostApp: String?,
        expectedFailureKind: CascadeMemory.AgentFailureKind? = nil
    ) -> Double {
        var score = 0.0
        if let frontmostApp {
            let lhs = memory.appName.lowercased()
            let rhs = frontmostApp.lowercased()
            if lhs == rhs {
                score += 2.0
            } else if lhs.contains(rhs) || rhs.contains(lhs) {
                score += 1.0
            }
        }
        if !queryTokens.isEmpty {
            let tokens = Set(memory.normalizedGoalTokens)
            let overlap = tokens.intersection(queryTokens).count
            if overlap > 0 {
                score += Double(overlap) / Double(max(queryTokens.count, tokens.count))
                score += Double(overlap) * 0.05
            }
        }
        if let expectedFailureKind {
            if memory.failureKind == expectedFailureKind {
                score += 1.25
            } else if Self.failureMemoryCategory(memory.failureKind) == Self.failureMemoryCategory(expectedFailureKind) {
                score += 0.35
            }
        }
        if memory.retainedScore < 0 { score += min(0.4, abs(memory.retainedScore) * 0.25) }
        return score
    }

    nonisolated static func failureSpecificMemoryNote(for failureKind: CascadeMemory.AgentFailureKind) -> String {
        switch failureKind {
        case .noEffect:
            return "Treat another identical action as a known no-effect branch; recapture once, then choose an alternate target or route."
        case .groundingMiss, .targetNotFound:
            return "Treat this as a known grounding branch; re-harvest visible controls and re-describe the target before acting."
        case .verifierRejected, .verificationUnavailable:
            return "Treat this as a known verifier branch; gather visible completion evidence before saying done."
	        case .modalBlocked, .wrongStartState:
	            return "Treat this as a known replay-pause branch; verify the current app/window or blocking dialog before continuing."
	        case .permissionDenied, .secureInput, .unsafeAction:
	            return "Treat this as a safety or environment boundary; do not bypass it, and ask for user action or choose a safer alternative."
	        default:
	            return "Treat this as a prior externally observed failure, not as proof the current run will fail."
	        }
    }

    nonisolated static func failureMemoryCategory(_ failureKind: CascadeMemory.AgentFailureKind) -> String {
        switch failureKind {
        case .targetNotFound, .groundingMiss:
            return "grounding"
        case .noEffect, .staleFrameBatch:
            return "effect"
        case .verifierRejected, .verificationUnavailable:
            return "verification"
        case .modalBlocked, .wrongStartState:
            return "replay_pause"
        case .permissionDenied, .secureInput, .loginRequired:
            return "environment"
        case .unsafeAction:
            return "safety"
        case .toolError, .timeout, .stepLimit:
            return "runtime"
        case .parameterNeedsLiveValue, .artifactWrongLane:
            return "policy"
        case .userStop:
            return "user"
        case .unknown:
            return "unknown"
        }
    }

    nonisolated static func recoveryAction(
        for failureKind: AgentOrchestrator.AgentFailureKind,
        attempt: Int
    ) -> RecoveryAction {
        let plan = AgentRecoveryPolicy.plan(for: failureKind)
        let rungs = plan.retryRungs
        let index = max(0, attempt - 1)
        guard rungs.indices.contains(index) else { return plan.terminal }
        return rungs[index]
    }

    nonisolated static func recoveryAttemptLimit(
        for failureKind: AgentOrchestrator.AgentFailureKind
    ) -> Int {
        AgentRecoveryPolicy.plan(for: failureKind).retryRungs.count + 1
    }

    nonisolated static func auditHash(_ value: String?) -> String {
        AuditIdentity.hash(value)
    }

    private nonisolated static func safeAuditToken(_ value: String) -> String {
        AuditIdentity.safeToken(value)
    }

    nonisolated static func textAuditDetail(_ field: String, _ value: String?) -> String {
        AuditIdentity.descriptor(field, value)
    }

    nonisolated static func parameterizedMiningAuditDetail(_ candidates: [DetectedWaste]) -> String {
        let report = WasteDetectionReport(
            rawCount: 0,
            episodeCount: 0,
            literalCount: candidates.count,
            parameterizedCount: candidates.count,
            minedCount: candidates.count,
            finalCount: candidates.count,
            results: candidates
        )
        return parameterizedMiningAuditDetail(
            report,
            reviewableCount: candidates.count,
            curatedCount: candidates.count,
            managerPendingCount: candidates.count
        )
    }

    nonisolated static func parameterizedMiningAuditDetail(
        _ report: WasteDetectionReport,
        reviewableCount: Int,
        curatedCount: Int,
        managerPendingCount: Int
    ) -> String {
        let candidates = report.results
        let parameterSteps = candidates.flatMap { candidate in
            candidate.recipe.steps.filter(\.isParameter)
        }
        let slotKinds = parameterSteps
            .compactMap { $0.parameterKind?.rawValue }
            .sorted()
            .joined(separator: "|")
        let signatures = candidates
            .map(\.signature)
            .sorted()
            .joined(separator: "|")
        return [
            "enabled=true",
            "rawCount=\(report.rawCount)",
            "episodeCount=\(report.episodeCount)",
            "literalCount=\(report.literalCount)",
            "parameterizedCount=\(report.parameterizedCount)",
            "minedCount=\(report.minedCount)",
            "finalCount=\(report.finalCount)",
            "reviewableCount=\(reviewableCount)",
            "curatedCount=\(curatedCount)",
            "managerPendingCount=\(managerPendingCount)",
            "candidateCount=\(report.finalCount)",
            "clusterCount=\(report.minedCount)",
            "slotCount=\(parameterSteps.count)",
            "slotKindsHash=\(auditHash(slotKinds))",
            "signatureHash=\(auditHash(signatures))"
        ].joined(separator: " ")
    }

    nonisolated static func policyDecisionAuditDetail(capability: String, decision: String, reason: String) -> String {
        [
            "capability=\(safeAuditToken(capability))",
            "decision=\(safeAuditToken(decision))",
            textAuditDetail("reason", reason)
        ].joined(separator: " ")
    }

    nonisolated static func observationAuditDescriptor(tool: String, info: InjectionGuard.EnvelopeAuditInfo) -> String {
        var parts = [
            "tool=\(safeAuditToken(tool))",
            "trust=\(safeAuditToken(info.trust.rawValue))",
            "sourceHash=\(auditHash(info.source))",
            "payloadHash=\(safeAuditToken(info.payloadHash))",
            "score=\(info.injectionScore)",
        ]
        if !info.injectionReasons.isEmpty {
            parts.append("reasons=\(info.injectionReasons.map(safeAuditToken).joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func autoRecallAuditDetail(_ result: AutoRecallResult) -> String {
        [
            "enabled=true",
            "status=\(safeAuditToken(result.status))",
            "count=\(result.selectedContextIDs.count)",
            "dropped=\(result.droppedCount)",
            "chars=\(result.renderedCharacters)",
            "candidateCount=\(result.candidateCount)",
            "eligibleCount=\(result.eligibleCount)",
            "queryHash=\(safeAuditToken(result.queryHash))",
            "selectedContextHash=\(safeAuditToken(result.selectedContextHash))"
        ].joined(separator: " ")
    }

    private func deniedURLReason(inHarnessInput input: [String: Any]) -> String? {
        if let url = input["url"] as? String, let reason = capturePrivacyPolicy.deniedURLReason(in: url) {
            return reason
        }
        let flattened = input
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return capturePrivacyPolicy.deniedURLReason(in: flattened)
    }

    nonisolated static func assistValidationAuditDetail(_ missing: String) -> String {
        "status=incomplete recoveryAction=\(RecoveryAction.diagnosticProbe.rawValue) \(textAuditDetail("missing", missing))"
    }

    nonisolated static func assistVerifyAuditDetail(
        status: String,
        actionKind: String,
        failureKind: CascadeMemory.AgentFailureKind?,
        evidenceName: String,
        evidence: String,
        skill: AppSkill?,
        postEffect: String? = nil,
        expectedEffect: String? = nil
    ) -> String {
        var parts = [
            "status=\(safeAuditToken(status))",
            "actionKind=\(safeAuditToken(actionKind))",
            "postEffect=\(safeAuditToken(postEffect ?? status))",
            "expectedEffect=\(safeAuditToken(expectedEffect ?? actionKind))",
            "\(safeAuditToken(evidenceName))Chars=\(evidence.count)",
            "\(safeAuditToken(evidenceName))Hash=\(auditHash(evidence))",
            "failureKind=\(safeAuditToken(failureKind?.rawValue ?? "none"))",
        ]
        if let skill {
            parts.append(textAuditDetail("skill", skill.name))
            parts.append("skillHints=\(skill.hints.inputPolicies.count)")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func assistCaptureAuditDetail(_ usage: ComputerUseUsageSnapshot) -> String {
        [
            "imageTurns=\(usage.imageTurns)",
            "prunedImages=\(usage.prunedImages)",
            "toolDefinitions=\(usage.toolDefinitions)",
            "inputTokens=\(usage.inputTokens)",
            "outputTokens=\(usage.outputTokens)",
            "cacheReadTokens=\(usage.cacheReadTokens)",
            "cacheWriteTokens=\(usage.cacheWriteTokens)",
            "verifierCalls=\(usage.verifierCalls)",
            "preflightInputTokens=\(usage.preflightInputTokens)",
            "estimatedCostUSD=\(String(format: "%.6f", usage.estimatedCostUSD))",
            "actualCostUSD=\(String(format: "%.6f", usage.actualCostUSD))",
            "cacheHitRatio=\(String(format: "%.3f", usage.cacheHitRatio))",
            "compactedToolResults=\(usage.compactedToolResults)",
            "actionCount=\(usage.actionCount)",
            "noEffectCount=\(usage.noEffectCount)",
        ].joined(separator: " ")
    }

    nonisolated static func historyCompactedAuditDetail(_ audit: ComputerUseAgent.HistoryCompactionAudit) -> String {
        [
            "turns=\(audit.turns)",
            "count=\(audit.count)",
            "bytesBefore=\(audit.bytesBefore)",
            "bytesAfter=\(audit.bytesAfter)",
            "window=\(audit.window)",
            "imageKeep=\(audit.imageKeep)",
        ].joined(separator: " ")
    }

    nonisolated static func actionChunkAuditDetail(
        length: Int,
        groups: Int,
        kindTokens: [String],
        status: String,
        deferred: Int = 0,
        breakReason: CUActionChunkBreakReason? = nil
    ) -> String {
        var parts = [
            "length=\(length)",
            "groups=\(groups)",
            "kindsHash=\(auditHash(kindTokens.joined(separator: "|")))",
            "status=\(safeAuditToken(status))",
            "deferred=\(deferred)",
        ]
        if let breakReason {
            parts.append("breakReason=\(safeAuditToken(breakReason.rawValue))")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func assistStalledAuditDetail(engine: String? = nil, text: String) -> String {
        var parts = ["status=stalled", textAuditDetail("text", text)]
        if let engine { parts.insert("engine=\(safeAuditToken(engine))", at: 1) }
        return parts.joined(separator: " ")
    }

    nonisolated static func assistPlannerFailedTimingReason(_ text: String) -> String {
        "status=planner-failed \(textAuditDetail("text", text))"
    }

    nonisolated static func groundAuditDetail(_ detail: String) -> String {
        textAuditDetail("ground", detail)
    }

    nonisolated static func groundingVerifierAuditDetail(_ outcome: MixtureGrounder.VerifierOutcome) -> String {
        let failure = outcome.verifierResult.failureKind?.rawValue ?? "none"
        var parts = [
            "verdict=\(safeAuditToken(outcome.verifierResult.verdict.rawValue))",
            "outcome=\(safeAuditToken(outcome.auditOutcome))",
            "failure=\(safeAuditToken(failure))",
            "confidence=\(String(format: "%.2f", outcome.verifierResult.confidence))",
            "candidates=\(outcome.candidateCount)",
            textAuditDetail("target", outcome.target)
        ]
        if let selectedSource = outcome.selectedSource {
            parts.append("selectedSource=\(safeAuditToken(selectedSource.rawValue))")
        }
        if let selectedCandidateHash = outcome.selectedCandidateHash {
            parts.append("selectedCandidateHash=\(safeAuditToken(selectedCandidateHash))")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func harnessDeniedWatchedAppAuditDetail(toolName: String, watchedApp: String) -> String {
        "tool=\(safeAuditToken(toolName)) \(textAuditDetail("app", watchedApp))"
    }

    nonisolated static func safeFlightDelayMilliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        guard seconds > 0 else { return 0 }
        if seconds >= 5 { return 5_000 }
        let milliseconds = (seconds * 1000).rounded()
        return Int(milliseconds)
    }

    nonisolated static func teachPointedAuditDetail(utterance: String, label: String) -> String {
        [
            textAuditDetail("utterance", utterance),
            textAuditDetail("pointedLabel", label),
        ].joined(separator: " ")
    }

    nonisolated static func sandboxSteerAuditDetail(runID: UUID, message: String) -> String {
        [
            "runID=\(runID.uuidString.prefix(8))",
            textAuditDetail("message", message),
        ].joined(separator: " ")
    }

    nonisolated static func sandboxTaskAuditDetail(task: String, outcome: String, agentID: Int64?) -> String {
        var parts = [
            "outcome=\(safeAuditToken(outcome))",
            textAuditDetail("task", task),
        ]
        if let agentID { parts.insert("agentID=\(agentID)", at: 0) }
        return parts.joined(separator: " ")
    }

    nonisolated static func completedRunAuditDetail(agentID: Int64, label: String) -> String {
        [
            "agentID=\(agentID)",
            textAuditDetail("label", label),
        ].joined(separator: " ")
    }

    nonisolated static func recipeRunAuditDetail(agent: CascadeAgent, status: String? = nil) -> String {
        var parts = [
            "agentID=\(agent.id)",
            "steps=\(agent.recipe.steps.count)",
            textAuditDetail("name", agent.name),
        ]
        if let status { parts.insert("status=\(safeAuditToken(status))", at: 0) }
        return parts.joined(separator: " ")
    }

    nonisolated static func curatedAgentAuditDetail(_ curated: CuratedAgent, agentID: Int64? = nil) -> String {
        var parts = [
            textAuditDetail("name", curated.name),
            textAuditDetail("goal", curated.goal),
            textAuditDetail("signature", curated.signature),
        ]
        if let agentID { parts.insert("agentID=\(agentID)", at: 0) }
        return parts.joined(separator: " ")
    }

    nonisolated static func recipeAuditDetail(_ step: RecipeStep, tier: String? = nil) -> String {
        var parts = [
            "step=\(step.order)",
            "kind=\(step.kind.rawValue)",
            textAuditDetail("app", step.appName),
            "hasPoint=\(step.x != nil && step.y != nil)",
            "isParameter=\(step.isParameter)",
            "actionKeyHash=\(step.idempotentActionKeyHash)",
        ]
        if let tier { parts.append("tier=\(safeAuditToken(tier))") }
        if let bundleIdentifier = step.bundleIdentifier { parts.append(textAuditDetail("bundle", bundleIdentifier)) }
        if let windowTitleHint = step.windowTitleHint { parts.append(textAuditDetail("window", windowTitleHint)) }
        return parts.joined(separator: " ")
    }

    nonisolated static func recipeTargetCacheAuditDetail(
        step: RecipeStep,
        tier: RecipeTargetCacheTier? = nil,
        reason: String? = nil,
        confidence: Double? = nil,
        deltaReason: String? = nil,
        source: AnchorDriftScorer.AnchorSource? = nil,
        score: Double? = nil,
        candidateCount: Int? = nil,
        anchorHash: String? = nil
    ) -> String {
        var parts = [
            "step=\(step.order)",
            "kind=\(safeAuditToken(step.kind.rawValue))",
            "actionKeyHash=\(step.idempotentActionKeyHash)",
        ]
        if let tier { parts.append("tier=\(safeAuditToken(tier.rawValue))") }
        if let reason { parts.append("reason=\(safeAuditToken(reason))") }
        if let confidence { parts.append("confidence=\(String(format: "%.2f", confidence))") }
        if let deltaReason { parts.append("delta=\(safeAuditToken(deltaReason))") }
        if let source { parts.append("source=\(safeAuditToken(source.rawValue))") }
        if let score { parts.append("score=\(String(format: "%.2f", score))") }
        if let candidateCount { parts.append("candidates=\(candidateCount)") }
        if let anchorHash { parts.append("anchorHash=\(safeAuditToken(anchorHash))") }
        return parts.joined(separator: " ")
    }

    nonisolated static func recipeTargetAuditDetail(
        step: RecipeStep,
        tier: String,
        confidence: Double? = nil,
        source: AnchorDriftScorer.AnchorSource? = nil,
        score: Double? = nil,
        candidateCount: Int? = nil,
        drift: AnchorDriftScorer.Outcome? = nil
    ) -> String {
        var detail = recipeAuditDetail(step, tier: tier)
        if let confidence { detail += " confidence=\(String(format: "%.2f", confidence))" }
        if let source { detail += " source=\(safeAuditToken(source.rawValue))" }
        if let score { detail += " score=\(String(format: "%.2f", score))" }
        if let candidateCount { detail += " candidates=\(candidateCount)" }
        if let drift { detail += " drift=\(safeAuditToken(String(describing: drift)))" }
        return detail
    }

    nonisolated static func recipeDriftAuditDetail(
        step: RecipeStep,
        outcome: AnchorDriftScorer.Outcome,
        reasons: Set<AnchorDriftScorer.Reason>,
        previousScore: Double?,
        selectedScore: Double?,
        candidateCount: Int
    ) -> String {
        var parts = [
            "step=\(step.order)",
            "kind=\(safeAuditToken(step.kind.rawValue))",
            "outcome=\(safeAuditToken(String(describing: outcome)))",
            "reasons=\(safeAuditToken(reasons.map { String(describing: $0) }.sorted().joined(separator: ",")))",
            "candidates=\(candidateCount)",
        ]
        if let previousScore { parts.append("previous=\(String(format: "%.2f", previousScore))") }
        if let selectedScore { parts.append("selected=\(String(format: "%.2f", selectedScore))") }
        return parts.joined(separator: " ")
    }

    nonisolated static func recipeEscalationAuditDetail(
        agent: CascadeAgent,
        reason: String,
        failureKind: AgentOrchestrator.AgentFailureKind? = nil,
        recoveryAction: RecoveryAction? = nil
    ) -> String {
        var parts = [
            "agentID=\(agent.id)",
            textAuditDetail("name", agent.name),
            textAuditDetail("reason", reason),
        ]
        if let failureKind { parts.append("failureKind=\(safeAuditToken(failureKind.rawValue))") }
        if let recoveryAction { parts.append("recoveryAction=\(safeAuditToken(recoveryAction.rawValue))") }
        return parts.joined(separator: " ")
    }

    nonisolated static func learnedSkillDraftAuditDetail(app: String, goal: String, actionCount: Int) -> String {
        [
            textAuditDetail("app", app),
            textAuditDetail("goal", goal),
            "actionCount=\(actionCount)",
        ].joined(separator: " ")
    }

    nonisolated static func scheduleAuditDetail(agent: CascadeAgent, schedule: String?, status: String) -> String {
        [
            "agentID=\(agent.id)",
            "status=\(safeAuditToken(status))",
            textAuditDetail("name", agent.name),
            "schedule=\(safeAuditToken(schedule ?? "off"))",
        ].joined(separator: " ")
    }

    /// AX is "sparse" — a canvas / non-AX surface where the accessibility tree
    /// exposed almost nothing to name, so the planner needs OCR text marks instead
    /// of assuming. Pure + pinned.
    nonisolated static func axIsSparse(controlCount: Int, threshold: Int = 8) -> Bool {
        controlCount < threshold
    }

    /// Whether to supplement the planner with OCR text marks this turn: AX is sparse
    /// (canvas / non-AX surface) AND the frontmost app is NOT a browser. Browsers are
    /// text-heavy and DOM-native (the background agent owns the web), so OCR there is
    /// page-text noise, not nameable targets. Pure + pinned.
    nonisolated static func shouldOcrSetOfMarks(axControlCount: Int, isBrowser: Bool) -> Bool {
        axIsSparse(controlCount: axControlCount) && !isBrowser
    }

    /// Performs one Computer Use action, flying the companion cursor to pointer
    /// targets first. Returns `false` (and surfaces why) if the actuator is blocked
    /// — e.g. Accessibility / Input Monitoring not granted — so the loop can stop.
    @discardableResult
    /// Grid perceptual hash of a JPEG frame — the recorder's change-aware
    /// fingerprint, reused to tell whether an acting turn changed the screen.
    /// nil if the frame can't be decoded (then no-effect detection is skipped).
    nonisolated static func gridHashes(ofJPEG data: Data) -> [UInt64]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PerceptualHash.gridHashes(image)
    }

    /// Whether an action is EXPECTED to change what's visible on screen — the
    /// predicted-effect signal (VeriGUI's Thinking-Verification-Action-Expectation
    /// cycle). No-effect detection rests on "an action that changed nothing failed",
    /// but a few actions legitimately leave the screen unchanged: a clipboard copy
    /// (cmd+c / cmd+x), an explicit wait, or a pure observation. A turn made ONLY of
    /// those must NOT be charged as a no-effect failure, or the agent stalls on
    /// honest no-ops. Made STRUCTURAL (the runtime classifies by action kind) rather
    /// than model-reported on purpose — a self-declared "no change expected" would
    /// let a weak planner switch OFF its own safety net by mislabelling a dead click.
    nonisolated static func expectsVisibleChange(_ action: CUAction) -> Bool {
        switch action {
        case .wait, .screenshot, .zoom: return false
        case .key(let combo): return !ComputerUseAgent.isCopyCombo(combo)
        default: return true
        }
    }

    /// A turn is expected to change the screen if ANY of its acting actions is — so a
    /// mixed turn (copy THEN click) still expects change, but a copy-only or
    /// wait-only turn is exempt from no-effect counting.
    nonisolated static func turnExpectsVisibleChange(_ actions: [CUAction]) -> Bool {
        actions.contains(where: expectsVisibleChange)
    }

    struct ActionChunkExecutionResult: Sendable, Equatable {
        let executedActions: Int
        let executedToolUseIDs: Set<String>
        let kindTokens: [String]
        let status: String
        let breakReason: CUActionChunkBreakReason?

        var completed: Bool { breakReason == nil }
    }

    static func executeActionChunkGroups(
        _ groups: [CUActionGroup],
        shouldStop: @MainActor () -> Bool,
        execute: @MainActor (CUAction) async -> Bool,
        modalTitle: @MainActor () async -> String?,
        noEffectAfterGroup: @MainActor ([CUActionGroup]) async -> Bool = { _ in false },
        pace: @MainActor (_ hasMoreActions: Bool) async -> Void = { _ in }
    ) async -> ActionChunkExecutionResult {
        var executedActions = 0
        var executedIDs = Set<String>()
        var completedGroups: [CUActionGroup] = []
        let kindTokens = groups.map(\.kindToken)
        for (groupIndex, group) in groups.enumerated() {
            for (actionIndex, action) in group.actions.enumerated() {
                guard !shouldStop() else {
                    return ActionChunkExecutionResult(
                        executedActions: executedActions,
                        executedToolUseIDs: executedIDs,
                        kindTokens: kindTokens,
                        status: "stop",
                        breakReason: .stop
                    )
                }
                guard await execute(action) else {
                    return ActionChunkExecutionResult(
                        executedActions: executedActions,
                        executedToolUseIDs: executedIDs,
                        kindTokens: kindTokens,
                        status: "failed",
                        breakReason: .malformed
                    )
                }
                executedActions += 1
                if let id = group.toolUseID { executedIDs.insert(id) }
                if await modalTitle() != nil {
                    return ActionChunkExecutionResult(
                        executedActions: executedActions,
                        executedToolUseIDs: executedIDs,
                        kindTokens: kindTokens,
                        status: "modal",
                        breakReason: .modal
                    )
                }
                let hasMoreActions = actionIndex < group.actions.count - 1 || groupIndex < groups.count - 1
                await pace(hasMoreActions)
            }
            completedGroups.append(group)
            if await noEffectAfterGroup(completedGroups) {
                return ActionChunkExecutionResult(
                    executedActions: executedActions,
                    executedToolUseIDs: executedIDs,
                    kindTokens: kindTokens,
                    status: "no_effect",
                    breakReason: .noEffect
                )
            }
        }
        return ActionChunkExecutionResult(
            executedActions: executedActions,
            executedToolUseIDs: executedIDs,
            kindTokens: kindTokens,
            status: "complete",
            breakReason: nil
        )
    }

    /// Maps an element's CG-global center (top-left origin, from AX) into the
    /// model's screenshot-pixel space (resW×resH, top-left). AX positions and
    /// `CGDisplayBounds` share the same CG-global coordinate system, so this is a
    /// plain subtract-and-scale — no AppKit Y-flip. Returns nil when the element
    /// is off the captured display (so we never push a coordinate the model's
    /// screenshot doesn't actually contain). Pure + unit-tested: a wrong number
    /// here would send the agent clicking into empty space.
    nonisolated static func modelPixel(forCGGlobal point: CGPoint, in display: CGRect, resW: Int, resH: Int) -> CGPoint? {
        let mapper = DisplayCoordinateMapper(
            displayID: CGMainDisplayID(),
            appKitFrame: CGRect(x: 0, y: 0, width: display.width, height: display.height),
            cgBounds: display,
            backingScaleFactor: 1
        )
        return mapper.capturedImagePixel(fromCGGlobal: point, imageSize: CGSize(width: resW, height: resH))
    }

    /// The flail-moment grounding push WITH coordinates: each on-screen control
    /// rendered as `"label" (role) at x,y` in the model's pixel space, so it can
    /// click the exact spot instead of guessing. Drops controls off the captured
    /// display. nil when nothing maps (caller falls back to labels-only, then a
    /// plain nudge). Pure given the harvested matches + display geometry.
    nonisolated static func groundingControls(
        _ matches: [AXElementResolver.Match], display: CGRect, resW: Int, resH: Int, limit: Int = 40
    ) -> String? {
        let entries = matches.prefix(limit).compactMap { match -> String? in
            guard let pixel = modelPixel(forCGGlobal: match.center, in: display, resW: resW, resH: resH) else { return nil }
            let role = match.role.hasPrefix("AX") ? String(match.role.dropFirst(2)).lowercased() : match.role.lowercased()
            return "“\(match.title)” (\(role)) at \(Int(pixel.x.rounded())),\(Int(pixel.y.rounded()))"
        }
        return entries.isEmpty ? nil : entries.joined(separator: "; ")
    }

    /// CG-global bounds (top-left origin) of the display a screen represents —
    /// the coordinate system AX element positions live in.
    nonisolated static func displayBounds(of screen: NSScreen) -> CGRect {
        DisplayCoordinateMapper(screen: screen)?.cgBounds ?? CGDisplayBounds(CGMainDisplayID())
    }

    private func executeCU(_ action: CUAction, on screen: NSScreen) async -> Bool {
        // An action means the thinking freeze is over — drop the sonar pulse so the
        // cursor's flight/press reads cleanly (the next turn re-arms it).
        guidanceOverlay.setThinking(false)
        let mapper = DisplayCoordinateMapper(screen: screen)
        func globalAppKit(_ x: Double, _ y: Double) -> CGPoint {
            mapper?.appKitGlobal(fromScreenLocal: CGPoint(x: x, y: y))
                ?? CGPoint(x: screen.frame.minX + x, y: screen.frame.minY + y)
        }
        func cg(_ x: Double, _ y: Double) -> CGPoint {
            let local = CGPoint(x: x, y: y)
            return mapper?.cgGlobal(fromScreenLocal: local) ?? Self.toCGGlobal(globalAppKit(x, y))
        }
        // Skill auto-learning: tally which app this run actually worked in.
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName,
           app.caseInsensitiveCompare("Cascade") != .orderedSame {
            episodeAppActions[app, default: 0] += 1
        }
        // Pointer-routed apps (Blender): hotkeys act on the editor under the
        // physical pointer, so the pointer must STAY where the agent clicks
        // instead of being restored to the user's parked position.
        let skill = frontmostSkill()
        let keepPointer = skill?.keysFollowPointer == true
        do {
            switch action {
            case .move(let x, let y):
                // Blue companion only — the user's real pointer never STAYS moved.
                // Pointer-routed apps need a real move EVENT (they track the
                // pointer from events; a warp is invisible to them), but the
                // restore is a warp for exactly that reason: the app keeps acting
                // at the hovered point while the user's cursor returns home.
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                if keepPointer {
                    let p = cg(x, y)
                    lastPointerRoutedPoint = p
                    try await clickRestoringCursor(settleMs: 30) { try await driver.act(.computerUse(.move(x: p.x, y: p.y))) }
                }
            case .click(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Self.safeFlightDelayMilliseconds(flight)))  // press only after the cursor ARRIVES
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))   // show the press dip
                let p = cg(x, y)
                if keepPointer {
                    // The press itself needs the real pointer (move event + click),
                    // but afterwards the cursor goes back to the user — the app's
                    // learned position stays at p because warps emit no events.
                    lastPointerRoutedPoint = p
                    try await clickRestoringCursor(settleMs: 30) { try await driver.act(.computerUse(.click(x: p.x, y: p.y))) }
                } else if skill?.axUnreliable == true || !Self.axActivate(atCG: p) {
                    try await clickRestoringCursor { try await driver.act(.computerUse(.click(x: p.x, y: p.y))) }
                }
            case .doubleClick(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Self.safeFlightDelayMilliseconds(flight)))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if keepPointer { lastPointerRoutedPoint = p }
                try await clickRestoringCursor(settleMs: keepPointer ? 30 : 0) {
                    try await driver.act(.computerUse(.doubleClick(x: p.x, y: p.y)))
                }
            case .tripleClick(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Self.safeFlightDelayMilliseconds(flight)))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if keepPointer { lastPointerRoutedPoint = p }
                try await clickRestoringCursor(settleMs: keepPointer ? 30 : 0) {
                    try await driver.act(.computerUse(.tripleClick(x: p.x, y: p.y)))
                }
            case .drag(let fromX, let fromY, let toX, let toY):
                // The companion cursor traces the drag so the user sees the motion —
                // and like clicks, the press waits for it to actually ARRIVE.
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(fromX, fromY))
                try? await Task.sleep(for: .milliseconds(Self.safeFlightDelayMilliseconds(flight)))
                guidanceOverlay.press()
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(toX, toY))
                let from = cg(fromX, fromY)
                let to = cg(toX, toY)
                if keepPointer { lastPointerRoutedPoint = to }
                try await clickRestoringCursor(settleMs: keepPointer ? 30 : 0) {
                    try await driver.act(.computerUse(.drag(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)))
                }
            case .rightClick(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Self.safeFlightDelayMilliseconds(flight)))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if keepPointer {
                    lastPointerRoutedPoint = p
                    try await clickRestoringCursor(settleMs: 30) { try await driver.act(.computerUse(.rightClick(x: p.x, y: p.y))) }
                } else if skill?.axUnreliable == true || !Self.axActivate(atCG: p, showMenu: true) {
                    try await clickRestoringCursor { try await driver.act(.computerUse(.rightClick(x: p.x, y: p.y))) }
                }
            case .type(let text):
                // Tiered text entry (tiptour-macos ActionExecutor pattern): AX
                // selected-text insertion (instant, never dropped) → clipboard
                // paste with restore → paced synthetic keystrokes. Catalyst and
                // Electron apps (WhatsApp, Slack) drop fast synthetic typing, so
                // keystrokes are the LAST resort, not the default.
                if driver.runState.isStopRequested { throw ComputerUseError.stopped }
                // Audit the mechanism and size only — never the text itself (the
                // agent may type sensitive content the user dictated).
                if let skill, skill.shouldTypePhysicalKeys(text),
                   let keys = AppSkillRegistry.physicalKeySequence(for: text) {
                    // Modal numeric input (Blender): the app ignores AX insertion,
                    // paste, and unicode-string events — only real per-key events
                    // register. Paced so the modal operator sees each key.
                    if keepPointer { await establishPointerRoutedPosition() }
                    for key in keys {
                        try await driver.act(.computerUse(.key(key, modifiers: [])))
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    let result = TextInjectionResult.make(
                        method: .physicalKeys,
                        text: text,
                        succeeded: true,
                        bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        secureInputEnabled: SecureInputGuard.isActive(),
                        elapsedMs: 0
                    )
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type", detail: result.auditDetail + " \(Self.textAuditDetail("skill", skill.name))"))
                } else if skill?.axUnreliable != true {
                    // Skipped for axUnreliable apps: their AX tree can accept the
                    // write and report success while nothing visible changes.
                    let axResult = Self.axInsertText(text)
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type", detail: axResult.auditDetail))
                    if axResult.succeeded { break }
                    let pasteResult = try await pasteText(text, pointerRouted: keepPointer)
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type", detail: pasteResult.auditDetail))
                    if pasteResult.succeeded { break }
                    try await driver.act(.computerUse(.typeText(text)))
                    let unicodeResult = TextInjectionResult.make(
                        method: .unicodeEvent,
                        text: text,
                        succeeded: true,
                        bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        secureInputEnabled: SecureInputGuard.isActive(),
                        elapsedMs: 0
                    )
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type", detail: unicodeResult.auditDetail))
                } else {
                    let pasteResult = try await pasteText(text, pointerRouted: keepPointer)
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type", detail: pasteResult.auditDetail))
                    if pasteResult.succeeded { break }
                    try await driver.act(.computerUse(.typeText(text)))
                    let unicodeResult = TextInjectionResult.make(
                        method: .unicodeEvent,
                        text: text,
                        succeeded: true,
                        bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        secureInputEnabled: SecureInputGuard.isActive(),
                        elapsedMs: 0
                    )
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type", detail: unicodeResult.auditDetail))
                }
            case .key(let combo):
                // Pointer-routed apps act where they last saw the pointer —
                // re-teach them the agent's working point before the key.
                if keepPointer { await establishPointerRoutedPosition() }
                let (key, modifiers) = Self.parseKey(combo)
                try await driver.act(.computerUse(.key(key, modifiers: modifiers)))
            case .scroll(let x, let y, let direction, let amount):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                let p = cg(x, y)
                let (dx, dy) = Self.scrollDelta(direction: direction, amount: amount)
                let origin = Self.cursorCG()
                // A real move event (not a warp) so pointer-tracking apps
                // apply the scroll at the target; the restore stays a silent
                // warp to avoid hover side-effects at the user's parked spot.
                if keepPointer { lastPointerRoutedPoint = p }
                try await driver.act(.computerUse(.move(x: p.x, y: p.y)))
                do { try await driver.act(.computerUse(.scroll(deltaX: dx, deltaY: dy))) }
                catch { CGWarpMouseCursorPosition(origin); throw error }
                CGWarpMouseCursorPosition(origin)
            case .wait:
                try? await Task.sleep(for: .milliseconds(700))
            case .screenshot:
                break
            case .zoom:
                break  // handled inside the episode loop (needs the cropped frame back)
            case .highlight(let x, let y, let width, let height, let label):
                // The agent showing the user something — Cascade's own overlay.
                let g = CGRect(x: screen.frame.minX + x, y: screen.frame.minY + y, width: width, height: height)
                guidanceOverlay.highlight(globalRect: g)
                guidanceOverlay.present(atGlobalPoint: CGPoint(x: g.midX, y: g.midY), label: label)
                assistMemory.rememberPointed(label: label, globalPoint: CGPoint(x: g.midX, y: g.midY))
                agentDidHighlight = true
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.highlight", detail: Self.textAuditDetail("label", label)))
            case .openApp(let name):
                // Instant programmatic launch — no Dock hunting, no cursor. Heavy apps
                // (Word, Photoshop) take seconds to boot AND keep painting after they're
                // technically frontmost — a too-early screenshot made the model repeat
                // new-document actions ("4 untitled documents"). Wait until frontmost
                // (up to ~8s), then give a cold launch a beat to finish drawing.
                dock.show(title: "Opening \(name)", detail: "")
                let wasAlreadyRunning = NSWorkspace.shared.runningApplications
                    .contains { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
                if await Self.openApp(named: name) {
                    for _ in 0..<32 {
                        // Containment, not equality: the asked-for name and the
                        // app's display name routinely differ ("Keynote" vs
                        // "Keynote Creator Studio") — exact compare never matched
                        // and silently burned the full 8s poll every open.
                        if let front = NSWorkspace.shared.frontmostApplication?.localizedName,
                           front.localizedCaseInsensitiveContains(name)
                            || name.localizedCaseInsensitiveContains(front) { break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    if !wasAlreadyRunning {
                        try? await Task.sleep(for: .milliseconds(1200))
                    }
                }
                // On failure the next screenshot shows nothing changed and Claude
                // falls back to the visual path.
            case .openURL(let urlString):
                // http(s) only — the agent must not trigger arbitrary URL schemes.
                if let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" {
                    dock.show(title: "Opening \(url.host() ?? "page")", detail: "")
                    NSWorkspace.shared.open(url)
                    // Give the browser a beat to come forward and start loading.
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            await verifyPostAction(action)
            return true
        } catch ComputerUseError.stopped {
            return false
        } catch ComputerUseError.secureInput(let reason) {
            // Distinct from a permission failure: keystrokes are being dropped by
            // macOS Secure Input, not by missing Accessibility. Surface the real
            // reason and record it under its own audit action so the reliability
            // taxonomy can classify it as `.secureInput`.
            teachMessage = reason
            voice.speak("Secure input is on, so I can't type that. Enter it yourself and I'll continue.")
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.secure_input", detail: reason))
            return false
        } catch {
            teachMessage = "I need Accessibility + Input Monitoring to control the Mac."
            voice.speak("I need Accessibility and Input Monitoring permission to do that.")
            return false
        }
    }

    struct ActionEffectValidation: Sendable, Equatable {
        let postEffect: String
        let status: String
        let failureKind: CascadeMemory.AgentFailureKind?
        let expectedEffect: String
    }

    nonisolated static func validateActionEffect(
        goal: String,
        action: CUAction,
        before: [UInt64]?,
        after: [UInt64]?,
        expectedEffect: String
    ) -> ActionEffectValidation {
        if let before, let after,
           !PerceptualHash.isDuplicateGrid(after, of: before, threshold: 2) {
            return ActionEffectValidation(
                postEffect: "verified",
                status: "verified",
                failureKind: nil,
                expectedEffect: expectedEffect
            )
        }
        switch action {
        case .wait, .screenshot, .zoom:
            return ActionEffectValidation(
                postEffect: "unavailable",
                status: "unavailable",
                failureKind: .verificationUnavailable,
                expectedEffect: expectedEffect
            )
        default:
            return ActionEffectValidation(
                postEffect: before != nil && after != nil ? "mismatch" : "unavailable",
                status: before != nil && after != nil ? "failed" : "unavailable",
                failureKind: before != nil && after != nil ? .noEffect : .verificationUnavailable,
                expectedEffect: expectedEffect
            )
        }
    }

    private func verifyPostAction(_ action: CUAction) async {
        switch action {
        case .openApp(let name):
            let front = NSWorkspace.shared.frontmostApplication
            let passed = Self.appMatches(
                frontmostName: front?.localizedName,
                frontmostBundle: front?.bundleIdentifier,
                expectedName: name,
                expectedBundle: nil
            )
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "assist.verify.action",
                detail: Self.assistVerifyAuditDetail(
                    status: passed ? "verified" : "failed",
                    actionKind: "open_app",
                    failureKind: passed ? nil : .wrongStartState,
                    evidenceName: "target",
                    evidence: name,
                    skill: frontmostSkill(),
                    postEffect: passed ? "verified" : "mismatch",
                    expectedEffect: "frontmost_app"
                )
            ))
        case .type(let text):
            guard let contains = Self.focusedAXValueContains(text) else {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "assist.verify.unavailable",
                    detail: Self.assistVerifyAuditDetail(
                        status: "unavailable",
                        actionKind: "type",
                        failureKind: .verificationUnavailable,
                        evidenceName: "text",
                        evidence: text,
                        skill: frontmostSkill(),
                        postEffect: "unavailable",
                        expectedEffect: "focused_ax_value"
                    )
                ))
                return
            }
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "assist.verify.action",
                detail: Self.assistVerifyAuditDetail(
                    status: contains ? "verified" : "failed",
                    actionKind: "type",
                    failureKind: contains ? nil : .verifierRejected,
                    evidenceName: "text",
                    evidence: text,
                    skill: frontmostSkill(),
                    postEffect: contains ? "verified" : "mismatch",
                    expectedEffect: "focused_ax_value"
                )
            ))
        case .openURL(let url):
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "assist.verify.unavailable",
                detail: Self.assistVerifyAuditDetail(
                    status: "unavailable",
                    actionKind: "open_url",
                    failureKind: .verificationUnavailable,
                    evidenceName: "url",
                    evidence: url,
                    skill: frontmostSkill(),
                    postEffect: "unavailable",
                    expectedEffect: "browser_url_or_page_text"
                )
            ))
        default:
            break
        }
    }

    private static func focusedAXValueContains(_ text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXClient.setMessagingTimeout(system)
        guard case .success(let element) = AXClient.elementAttribute(system, kAXFocusedUIElementAttribute as String) else { return nil }
        for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
            if case .success(let value) = AXClient.attribute(element, attribute as String, as: String.self) {
                return value.contains(trimmed)
            }
        }
        return nil
    }

    private var lastNarrationAt = Date.distantPast
    private var lastNarratedLine = ""

    /// Keeps the agent talky while it works: the model's short progress lines
    /// ("writing the poem now") go to the dock and — on voice — are spoken.
    /// Throttled, and consecutive repeats are never spoken twice ("he repeats
    /// what he says"). Returns true when a line was actually spoken so the
    /// caller can give the speech a head start before the actions land.
    @discardableResult
    private func narrateProgress(_ text: String) -> Bool {
        let line = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        dock.show(title: "Cascade is working", detail: String(line.prefix(120)))
        guard line.count <= 120,
              line.caseInsensitiveCompare(lastNarratedLine) != .orderedSame,
              Date().timeIntervalSince(lastNarrationAt) >= 4 else { return false }
        lastNarrationAt = Date()
        lastNarratedLine = line
        voice.speak(line)
        return true
    }

    /// The app skill matching whatever app is frontmost right now, if any.
    private func frontmostSkill() -> AppSkill? {
        let front = NSWorkspace.shared.frontmostApplication
        return appSkills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier)
    }

    /// Compact frontmost skill summary for Scout. Full recipes stay pull-based via
    /// use_skill; this only tells Scout which skill family applies and what caveats
    /// matter before it decides which playbook to fetch.
    private func scoutSkillPush(goal: String) -> String? {
        guard let app = frontmostSkill() else { return nil }
        let asksScript = AppSkill.goalAsksForScript(goal)
        let related = appSkills.skills.filter { skill in
            (skill.name == app.name || skill.name.hasPrefix(app.name + "-"))
                && (!skill.explicitAskOnly || asksScript)
        }
        guard !related.isEmpty else { return nil }
        let lines = related.prefix(8).map { skill -> String in
            let caveats = Self.scoutSkillCaveats(skill)
            let caveatText = caveats.isEmpty ? "none" : caveats.joined(separator: ", ")
            return "- \(skill.name): \(skill.useWhen)\n  caveats: \(caveatText)"
        }
        return """
        Frontmost app skill summary. Pull full instructions with use_skill before following a recipe:
        \(lines.joined(separator: "\n"))
        """
    }

    nonisolated private static func scoutSkillCaveats(_ skill: AppSkill) -> [String] {
        var caveats: [String] = []
        if skill.explicitAskOnly { caveats.append("explicit user ask required") }
        if skill.axUnreliable { caveats.append("AX unreliable") }
        if skill.keysFollowPointer { caveats.append("keys follow pointer") }
        if !skill.hints.inputPolicies.isEmpty {
            caveats.append("input policies \(skill.hints.inputPolicies.count)")
        }
        if let source = skill.hints.preferredGroundingSource, !source.isEmpty {
            caveats.append("prefer \(source) grounding")
        }
        return caveats
    }

    /// Pointer-routed apps (Blender) send hotkeys to the editor at the position
    /// they last LEARNED from a mouse-move event — not at the visible cursor
    /// (warps are invisible to them). Before bare keys/typing/paste, re-teach
    /// the app the point the agent is working at (its last click/hover, else
    /// the frontmost window's centre) with a real move event, give the queue a
    /// beat to deliver it, then warp the user's cursor straight back: the app
    /// keeps acting at the agent's point while the user's cursor never stays
    /// hijacked. Always re-teach — the visible cursor says nothing about the
    /// app's learned position once restores are in play. Uses CGWindowList,
    /// not AX — these apps are the ones whose AX trees can't be trusted.
    private func establishPointerRoutedPosition() async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]] else { return }
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let origin = Self.cursorCG()
            let target: CGPoint
            if let last = lastPointerRoutedPoint, bounds.contains(last) {
                target = last
            } else {
                target = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            // Let the queued event deliver before warping back — processed
            // after the warp it would drag the visible cursor to the target.
            try? await Task.sleep(for: .milliseconds(40))
            CGWarpMouseCursorPosition(origin)
            return
        }
    }

    /// Where the agent last clicked/hovered in a pointer-routed app — the point
    /// its hotkeys should keep acting at after the cursor restore.
    private var lastPointerRoutedPoint: CGPoint?

    /// Runs a CGEvent click body, then snaps the real cursor back to exactly where
    /// it was — the fallback for targets Accessibility can't press. The actuator
    /// checks health/STOP *before* posting, so on throw the cursor hasn't moved and
    /// we just rethrow. `settleMs` waits before the restore so every queued event
    /// is delivered first (a move processed after the warp would drag the visible
    /// cursor back out to the click point).
    private func clickRestoringCursor(settleMs: Int = 0, _ body: () async throws -> Void) async throws {
        let origin = Self.cursorCG()
        try await body()
        if settleMs > 0 { try? await Task.sleep(for: .milliseconds(settleMs)) }
        CGWarpMouseCursorPosition(origin)
    }

    /// Presses the UI element at a global top-left point through the Accessibility
    /// API — a real activation with **zero cursor movement**. Focuses text inputs so
    /// a following `type` lands. Returns false if nothing actionable is there (the
    /// caller then falls back to a cursor-restoring CGEvent click).
    private static func axActivate(atCG point: CGPoint, showMenu: Bool = false) -> Bool {
        guard case .success(let element) = AXClient.elementAtPosition(point) else { return false }

        if !showMenu, let role = axString(element, kAXRoleAttribute), textRoles.contains(role) {
            // Multi-line editors are clicked to PLACE THE CARET at the click
            // point. AX focus lands the element but never moves the caret — the
            // click would "succeed" while typing lands at the old insertion
            // point. Only a real CGEvent click positions the caret.
            if role == "AXTextArea" { return false }
            if AXClient.setAttribute(element, kAXFocusedAttribute as String, value: kCFBooleanTrue) == .success {
                return true
            }
        }

        let names = AXClient.actionNames(element)
        let wanted = showMenu ? [kAXShowMenuAction] : [kAXPressAction, kAXConfirmAction, kAXPickAction]
        for action in wanted where names.contains(action) {
            if AXClient.performAction(element, action) == .success { return true }
        }
        return false
    }

    /// Pastes text via the clipboard (cmd+V), restoring the user's previous
    /// clipboard afterwards — tiptour-macos's fallback for apps whose fields
    /// don't take AX insertion. Returns false if the paste keystroke fails.
    /// Pointer-routed apps (Blender) need three deviations: the pointer must be
    /// inside the app's window (keys route to the editor under it), the chord is
    /// ctrl+V (the literal keymap binding — cmd is only an alias layer), and the
    /// clipboard must stay ours much longer: the app reads it when its main loop
    /// runs the paste operator, easily later than the keystroke itself.
    private func pasteText(_ text: String, pointerRouted: Bool = false) async throws -> TextInjectionResult {
        let start = Date()
        let secureInput = SecureInputGuard.isActive()
        if let reason = SecureInputGuard.refusalReason(secureInputActive: secureInput) {
            throw ComputerUseError.secureInput(reason)
        }
        let front = NSWorkspace.shared.frontmostApplication
        if pointerRouted { await establishPointerRoutedPosition() }
        let pasteboard = NSPasteboard.general
        // Snapshot what the user had so the agent never eats their clipboard.
        let previous = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
        }
        do {
            if pointerRouted {
                // Pointer-routed apps' only paste targets are FIELDS (hex colors,
                // names, search boxes) — and Blender fields keep their old text:
                // pasting without a selection APPENDS ("FFFFFFCFCBC3" hex soup,
                // per the audit log). Select-all first makes the paste REPLACE;
                // on an empty field it's a no-op. ctrl, not cmd: the literal
                // Blender binding for both chords.
                try await driver.act(.computerUse(.key("a", modifiers: ["control"])))
                try? await Task.sleep(for: .milliseconds(60))
            }
            try await driver.act(.computerUse(.key("v", modifiers: [pointerRouted ? "control" : "command"])))
            // Let the app consume the pasteboard before we restore it.
            try? await Task.sleep(for: .milliseconds(pointerRouted ? 900 : 180))
            let readback = Self.focusedAXValueContains(text)
            return TextInjectionResult.make(
                method: .paste,
                text: text,
                succeeded: true,
                bundleIdentifier: front?.bundleIdentifier,
                secureInputEnabled: secureInput,
                readbackStatus: Self.textReadbackStatus(readback),
                elapsedMs: Self.elapsedMilliseconds(since: start)
            )
        } catch ComputerUseError.secureInput(let reason) {
            throw ComputerUseError.secureInput(reason)
        } catch {
            return TextInjectionResult.make(
                method: .paste,
                text: text,
                succeeded: false,
                bundleIdentifier: front?.bundleIdentifier,
                secureInputEnabled: secureInput,
                readbackStatus: .notChecked,
                fallbackReason: "paste-key-failed",
                elapsedMs: Self.elapsedMilliseconds(since: start)
            )
        }
    }

    /// Inserts text at the caret of the frontmost app's focused element by setting
    /// `AXSelectedText` (the tiptour-macos `ActionExecutor` pattern — see
    /// docs/THIRD_PARTY_NOTICES.md). Returns false when there's no focused,
    /// settable text element — the caller falls back to synthetic keystrokes.
    private static func axInsertText(_ text: String) -> TextInjectionResult {
        let start = Date()
        let secureInput = SecureInputGuard.isActive()
        let front = NSWorkspace.shared.frontmostApplication
        func result(
            succeeded: Bool,
            element: AXUIElement? = nil,
            readback: TextInjectionResult.ReadbackStatus = .notChecked,
            reason: String? = nil
        ) -> TextInjectionResult {
            TextInjectionResult.make(
                method: .ax,
                text: text,
                succeeded: succeeded,
                focusedRole: element.flatMap { axString($0, kAXRoleAttribute) },
                focusedSubrole: element.flatMap { axString($0, kAXSubroleAttribute) },
                bundleIdentifier: front?.bundleIdentifier,
                secureInputEnabled: secureInput,
                readbackStatus: readback,
                fallbackReason: reason,
                elapsedMs: elapsedMilliseconds(since: start)
            )
        }
        guard let app = front,
              // Never AX-insert into Cascade's OWN focused element — if Cascade is
              // frontmost the insert "succeeds" silently and the text never reaches
              // the target app (the audited phantom "can't type"). Fall through to
              // paste / keystrokes, which follow real keyboard focus.
              app.bundleIdentifier != "com.humain.cascade" else { return result(succeeded: false, reason: "cascade-frontmost") }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXClient.setMessagingTimeout(appRef)
        guard case .success(let element) = AXClient.elementAttribute(appRef, kAXFocusedUIElementAttribute as String) else {
            return result(succeeded: false, reason: "no-focused-element")
        }
        guard AXClient.isSettable(element, kAXSelectedTextAttribute as String) else {
            return result(succeeded: false, element: element, reason: "selected-text-not-settable")
        }
        guard AXClient.setAttribute(element, kAXSelectedTextAttribute as String, value: text as CFString) == .success else {
            return result(succeeded: false, element: element, reason: "set-selected-text-failed")
        }
        // VERIFY the insert actually took. Web <input>/combobox elements (Google
        // Flights, most sites) ACCEPT the set and report .success while the value
        // never changes — the phantom write behind the audited "can't type"
        // (computer.type.ax → no-effect, while the SAME field+text via paste worked).
        // Read the value back; only claim success if it now reflects the text, else
        // return false so the caller falls to paste/keystrokes, which DO land. A
        // field that doesn't expose its value reads nil → also falls through (paste
        // is reliable, so an occasional unnecessary paste is harmless).
        let after = axString(element, kAXValueAttribute as String)
            ?? axString(element, kAXSelectedTextAttribute as String)
        let matched = after?.contains(text)
        return result(
            succeeded: matched == true,
            element: element,
            readback: Self.textReadbackStatus(matched),
            reason: matched == true ? nil : "readback-mismatch"
        )
    }

    private nonisolated static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard case .success(let value) = AXClient.attribute(element, attribute, as: String.self) else { return nil }
        return value
    }

    private nonisolated static func textReadbackStatus(_ matched: Bool?) -> TextInjectionResult.ReadbackStatus {
        switch matched {
        case .some(true): return .matched
        case .some(false): return .mismatched
        case .none: return .notAvailable
        }
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    /// The title of a sheet or modal dialog currently focused in the frontmost
    /// app, or nil when the UI is in its normal state. AppKit/AX stay on main.
    private static func unexpectedModal() async -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.isActive }) else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXClient.setMessagingTimeout(appRef)
        guard case .success(let window) = AXClient.elementAttribute(appRef, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        let role = axString(window, kAXRoleAttribute) ?? ""
        let subrole = axString(window, kAXSubroleAttribute) ?? ""
        guard role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" else { return nil }
        let title = axString(window, kAXTitleAttribute) ?? ""
        return title.isEmpty ? (role == "AXSheet" ? "sheet" : "dialog") : title
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Current cursor position in CGEvent global (top-left) coordinates.
    private static func cursorCG() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// "Where can I find/do X" when X isn't on the current screen: navigate (open the
    /// right app/menu/tab, scroll) to bring it into view, then frame it with the marquee.
    /// It reveals — it does NOT click the target itself. STOP-able and capped.
    private func findAndReveal(question: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int) async {
        driver.runState.reset()
        teachMessage = "Let me find that for you…"
        voice.speak("One moment — let me find that.")
        let dw = Int(screen.frame.width), dh = Int(screen.frame.height)

        let navigator = ComputerUseAgent(effort: "low", environmentNote: """
        The user is trying to FIND or REACH "\(question)" but it is not on the screen yet. \
        Navigate this Mac to bring it into view — open the relevant app, menu, or tab, or \
        scroll. Take the most DIRECT path and use as few steps as possible. One action at a \
        time. Do NOT click or activate the target itself; just surface it so it becomes \
        visible. Once it is visible on screen, stop.
        """)
        var step = await navigator.begin(
            goal: "Surface on screen where the user can find or do: \(question)",
            screenshot: firstScreenshotPNG,
            displayWidthPoints: dw, displayHeightPoints: dh,
            conversation: assistMemory.historyForAPI()
        )

        // Backstop only — surfacing an element is a bounded task, but 6 nav steps
        // wasn't enough to open an app, switch a tab, and scroll to the target.
        let maxSteps = 14
        var count = 0
        while count < maxSteps {
            if assistGeneration != gen { return }  // superseded by a newer turn
            if driver.runState.isStopRequested { teachMessage = "Stopped."; return }
            var failed = false
            for action in step.actions {
                if !(await executeCU(action, on: screen)) { failed = true; break }
                try? await Task.sleep(for: .milliseconds(80))
            }
            if failed { return }  // executeCU surfaced the permission/STOP reason
            try? await Task.sleep(for: .milliseconds(220))

            // Capture once at the agent's resolution as JPEG — both consumers below
            // accept it as-is, skipping the PNG round-trip, OCR, and re-encodes.
            let size = navigator.captureSize
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) else { break }
            // Detection (is it visible now?) and the next nav step fire concurrently, so
            // each loop turn costs ONE round-trip of wall-clock instead of two. If found,
            // the speculative nav step is just discarded.
            async let regionTask = locateRegionGrounded(
                screenshot: shot, question: question, displayWidthPoints: dw, displayHeightPoints: dh,
                conversation: assistMemory.historyForAPI()
            )
            async let nextStepTask = navigator.proceed(screenshot: shot)

            let region = await regionTask
            if let local = region.rect {
                let g = CGRect(
                    x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                    width: local.width, height: local.height
                )
                guidanceOverlay.highlight(globalRect: g)
                guidanceOverlay.present(atGlobalPoint: CGPoint(x: g.midX, y: g.midY), label: "here")
                assistMemory.rememberPointed(label: question, globalPoint: CGPoint(x: g.midX, y: g.midY))
                assistMemory.remember(user: question, assistant: region.speech)
                teachMessage = region.speech
                voice.speak(region.speech)
                voice.done()
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.reveal", detail: Self.textAuditDetail("question", question)))
                await refreshAll()
                return
            }
            let next = await nextStepTask
            if next.done { break }
            step = next
            count += 1
        }

        guidanceOverlay.hide()
        teachMessage = "I opened a few things but couldn't surface that — it may not be here."
        assistMemory.remember(user: question, assistant: teachMessage, ok: false)
        voice.speak("I couldn't bring that on screen.")
        voice.done()
    }

    /// Splits a Computer Use key string ("Return", "cmd+space", "ctrl+c") into a
    /// key name + modifier list the native actuator understands.
    private static func parseKey(_ combo: String) -> (String, [String]) {
        let parts = combo.split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let last = parts.last, !last.isEmpty else { return (combo.lowercased(), []) }
        let modifiers = parts.dropLast().map { $0 == "super" || $0 == "win" ? "command" : $0 }
        let key: String
        switch last {
        case "enter", "\u{000A}": key = "return"
        case "esc": key = "escape"
        case "del", "backspace": key = "delete"
        case "spc": key = "space"
        default: key = last
        }
        return (key, modifiers)
    }

    /// Maps a Computer Use scroll direction + click count to pixel deltas for the
    /// native scroll actuator (wheel1 = vertical, positive = up).
    private static func scrollDelta(direction: String, amount: Int) -> (Double, Double) {
        let step = Double(max(1, amount)) * 40
        switch direction.lowercased() {
        case "up": return (0, step)
        case "down": return (0, -step)
        case "left": return (step, 0)
        case "right": return (-step, 0)
        default: return (0, -step)
        }
    }

    /// Commands with no multi-part connectors skip the planner round-trip — a
    /// single Computer Use episode handles them (exactly the pre-planner behavior),
    /// saving ~a second of up-front latency on the most common short commands.
    private static func isSinglePartCommand(_ text: String) -> Bool {
        guard text.count < 60 else { return false }
        let t = " " + text.lowercased() + " "
        let connectors = [" then ", " after that ", " and then ", "; ", ", and ", " followed by "]
        return !connectors.contains { t.contains($0) }
    }

    /// Heuristic: did the user ask Cascade to *do* something (act) vs *find/show*
    /// something (point only)? Imperatives ACT by default — a whitelist of verbs
    /// kept failing open-ended requests ("design me a landing page" was coached
    /// instead of done). Only clearly question-shaped asks stay point-only.
    nonisolated static func isActionRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        // Highlight/mark requests go to the acting agent — it owns the highlight
        // tool and can navigate/scroll to surface the target first. This wins even
        // over question-y phrasing ("show me X and highlight them").
        if t.contains("highlight") || t.contains("point out") || t.contains(" mark ") || t.hasPrefix("mark ") {
            return true
        }
        // The find-vs-where-is split: "where is X" / "where can I find X" / "show me X"
        // POINT at the target (highlight); a bare imperative "find X" / "find it for me"
        // means GO DO IT — navigate / open / surface it. So "find" is NOT a point
        // trigger; only the locational "where…" is (which still catches "where can I
        // find X"). Previously "find " sat here and sent every "find …" to point-only.
        let teachy = ["where", "how do i", "how can i", "show me", "what is", "what's",
                      "which ", "who ", "is there", "are there", "can i ", "does "]
        if teachy.contains(where: { t.contains($0) }) { return false }
        return true
    }

    /// Questions about the recorded past ("what did I do today?") — answered from
    /// the local record, never by driving the screen.
    private static func isRetrospective(_ text: String) -> Bool {
        let t = text.lowercased()
        let markers = ["what did", "what was", "what have", "did i ", "summar", "recap",
                       "yesterday", "this morning", "this week", "last week", "earlier today"]
        return markers.contains { t.contains($0) }
    }

    /// Global AppKit (bottom-left, primary-display origin) → CGEvent global
    /// (top-left) coordinates for the native actuator.
    private static func toCGGlobal(_ appkit: CGPoint) -> CGPoint {
        if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(appkit) }),
           let mapper = DisplayCoordinateMapper(screen: screen) {
            let local = CGPoint(x: appkit.x - screen.frame.minX, y: appkit.y - screen.frame.minY)
            if let cg = mapper.cgGlobal(fromScreenLocal: local) { return cg }
        }
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? appkit.y
        return CGPoint(x: appkit.x, y: primaryHeight - appkit.y)
    }

    // MARK: - Teach-once (demonstrate a task → agent)

    /// How far before the finishing ⌥⌃T press the bracket ends — enough to exclude
    /// the recorded hotkey combo without dropping real work (the user is mid-keystroke
    /// reaching for the chord, not acting in the app).
    private static let teachFinishGuard: TimeInterval = 0.3

    /// ⌥⌃T toggles a demonstration: first press starts the bracket, second press ends
    /// it and curates the recording into an agent.
    public func toggleTeaching() {
        if teachingMode { endTeaching() } else { beginTeaching() }
    }

    /// The banner dismiss (×). The persistent "Teaching…"/"Saving…" states move on by
    /// themselves; this is for the terminal result lines.
    public func dismissTeachStatus() { teachStatus = nil }

    private var teachStatusToken = 0

    /// A terminal teach status that fades on its own (added/sent/nothing-found/error),
    /// unless a newer one supersedes it or a demonstration is in progress.
    private func flashTeachStatus(_ text: String) {
        teachStatusToken += 1
        let token = teachStatusToken
        teachStatus = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.teachStatusToken == token, !self.teachingMode else { return }
            self.teachStatus = nil
        }
    }

    /// Start a demonstration. Recording is already always-on, so this only stamps the
    /// lower bound of the time range and reroutes narration into the intent buffer —
    /// nothing new is captured. Refuses while an agent is acting (those events would
    /// be the agent's, not the user's hand).
    public func beginTeaching() {
        guard !teachingMode else { return }
        guard !assistTaskRunning, !agentRunning else {
            flashTeachStatus("Finish the running task before teaching.")
            return
        }
        teachStartedAt = Date()
        teachIntentBuffer.removeAll()
        teachingMode = true
        teachStatus = "Teaching — do the task, narrate if you like, then press ⌥⌃T to finish."
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.started", detail: "")) }
    }

    /// End the demonstration and turn the bracketed range into a curated agent (shown
    /// in the preview sheet). The curation rides the SAME spine as auto-detection —
    /// `curateRange` → `DetectedWaste` → `curateOne` → the existing `createAgent`.
    public func endTeaching() {
        guard teachingMode, let start = teachStartedAt else { return }
        // The finishing ⌥⌃T press is itself recorded (control+option = a structural
        // key combo), so end the bracket just BEFORE it — otherwise it becomes a
        // spurious recipe step that on replay would re-trigger teaching. (The start
        // press is already excluded: it lands before `teachStartedAt` was stamped.)
        // The guard only drops the fraction of a second around the hotkey, where the
        // user is reaching for keys, never doing the task.
        let end = max(start, Date().addingTimeInterval(-Self.teachFinishGuard))
        teachingMode = false
        teachStartedAt = nil
        let intent = teachIntentBuffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        teachIntentBuffer.removeAll()
        teachStatus = "Saving your demonstration…"
        Task {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "employee",
                action: "teach.stopped",
                detail: intent.isEmpty ? "status=silent" : Self.textAuditDetail("intent", intent)
            ))
        }
        Task { await buildTaughtAgent(from: start, to: end, statedIntent: intent.isEmpty ? nil : intent) }
    }

    private func buildTaughtAgent(from start: Date, to end: Date, statedIntent: String?) async {
        // Let the always-on recorder's 1s drain flush the bracketed events AND attach
        // AX click labels before we read them — the drain defers unlabeled clicks
        // <0.35s old, and those labels are the strongest replay anchor, so a forced
        // immediate flush would lose them. ~1.5s is a safe settle.
        try? await Task.sleep(for: .milliseconds(1500))
        do {
            let curated = try await orchestrator.curateRange(
                from: start, to: end,
                statedIntent: statedIntent,
                webAppIdentity: Self.webAppIdentity
            )
            if let curated {
                teachStatus = nil
                teachPreview = curated
            } else {
                flashTeachStatus("Nothing repeatable in that demonstration yet — try the task again.")
            }
        } catch {
            flashTeachStatus("Couldn't build an agent from that: \(error.localizedDescription)")
        }
    }

    /// "Add to my agents": the employee self-serves the taught recipe straight into
    /// their Cascades, ready to deploy — the same `createAgent` the manager path uses.
    public func createTaughtAgent(_ curated: CuratedAgent) {
        Task {
            do {
                _ = try await orchestrator.createAgent(from: curated)
                teachPreview = nil
                _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "agent.taught", detail: Self.curatedAgentAuditDetail(curated)))
                selectedTab = .cascades
                flashTeachStatus("Added “\(curated.name)” to your agents.")
            } catch {
                flashTeachStatus("Couldn't add “\(curated.name)”: \(error.localizedDescription)")
            }
            await refreshAll()
        }
    }

    /// "Send to manager": the taught recipe joins the manager's review queue
    /// (`pendingCuratedAgents`) instead of being created directly — the manager
    /// approves or declines it like any auto-detected workflow.
    public func sendTaughtAgentToManager(_ curated: CuratedAgent) {
        teachPreview = nil
        if !taughtForReview.contains(where: { $0.signature == curated.signature }) {
            taughtForReview.insert(curated, at: 0)
        }
        flashTeachStatus("Sent “\(curated.name)” to your manager for review.")
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.sentToManager", detail: Self.curatedAgentAuditDetail(curated))) }
    }

    /// Drop a taught proposal from the review queue once it's been acted on (approved
    /// → it's a real agent now; declined → it's dismissed).
    private func clearTaughtForReview(signature: String) {
        taughtForReview.removeAll { $0.signature == signature }
    }

    // MARK: - Agents built from recorded workflows

    private func suggestionPreferenceModel() async -> PreferenceModel {
        let priors = Self.preferencePriors(
            timing: suggestionTimingPreference,
            background: backgroundAgentPreference
        )
        let events = (try? await store.recentPreferenceEvents(limit: 1_500)) ?? []
        var model = PreferenceModel(events: events, priorAlpha: priors.alpha, priorBeta: priors.beta)
        for signature in dismissedWasteSignatures {
            model.record(signature, accepted: false)
        }
        switch backgroundAgentPreference {
        case .prefer:
            model.record("backgroundCapable:true", reward: 0.6, weight: 1)
        case .avoid:
            model.record("backgroundCapable:true", reward: -0.8, weight: 1)
        case .askFirst:
            break
        }
        return model
    }

    private nonisolated static func preferencePriors(
        timing: SuggestionTimingPreference,
        background: BackgroundAgentPreference
    ) -> (alpha: Double, beta: Double) {
        var alpha = 1.0
        var beta = 1.0
        switch timing {
        case .early:
            alpha += 0.45
        case .strongEvidence:
            beta += 0.65
        case .balanced:
            break
        }
        if background == .avoid { beta += 0.15 }
        if background == .prefer { alpha += 0.10 }
        return (alpha, beta)
    }

    private func applySuggestionTimingPreference() {
        switch suggestionTimingPreference {
        case .early:
            if proactiveMode == .quiet { proactiveMode = .askFirst }
        case .balanced:
            break
        case .strongEvidence:
            proactiveMode = .quiet
        }
    }

    private func recordColdStartPreference(kind: String, value: String) async {
        await appendPreferenceEvent(
            kind: .coldStartSet,
            reward: 0.25,
            surface: "settings.personalization",
            appName: nil,
            workflowSignature: "cold-start:\(kind)",
            agentID: nil,
            features: [
                "candidateType": "coldStart",
                "\(kind)Preference": value,
                "timingPreference": suggestionTimingPreference.rawValue,
                "backgroundPreference": backgroundAgentPreference.rawValue
            ],
            evidence: ["preferenceHash": Self.auditHash(value)]
        )
    }

    private static func enabledByDefault(_ defaults: UserDefaults, key: String) -> Bool {
        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }
        return true
    }

    public nonisolated static func rankCuratedSuggestions(
        _ candidates: [CuratedAgent],
        using model: PreferenceModel,
        ranker: SuggestionRanker = SuggestionRanker()
    ) -> [CuratedAgent] {
        ranker.rankElements(
            candidates,
            key: \.signature,
            base: { $0.value },
            context: {
                PreferenceContext(
                    appName: $0.apps.first,
                    surface: "manager.review",
                    candidateType: "curatedAgent",
                    backgroundCapable: Self.runsInBackground(apps: $0.apps),
                    privacyRiskBucket: ($0.source.quality?.privacyPenalty ?? 0) >= 0.25 ? "medium" : "low"
                )
            },
            using: model
        )
    }

    public nonisolated static func nextActionTokens(for events: [InputEvent]) -> [String] {
        NextActionPredictor.tokens(for: events, webAppIdentity: Self.webAppIdentity)
    }

    public nonisolated static func nextActionToken(for event: InputEvent) -> String {
        NextActionPredictor.token(for: event, webAppIdentity: Self.webAppIdentity)
    }

    public nonisolated static func userIsActivelyTyping(events: [InputEvent], now: Date, window: TimeInterval = 6) -> Bool {
        guard let last = events.last else { return false }
        let age = now.timeIntervalSince(last.capturedAt)
        guard age >= 0, age <= window else { return false }
        if last.kind == .type { return true }
        guard last.kind == .key else { return false }
        let modifierSet = Set(last.modifiers.map { $0.lowercased() })
        guard modifierSet.isDisjoint(with: ["command", "control", "option"]) else { return false }
        let key = (last.key ?? "").lowercased()
        return key.count == 1 || ["space", "delete", "return", "tab"].contains(key)
    }

    public func dismissProactiveNextActionOffer() {
        guard proactiveNextActionOffer != nil || proactiveOffer != nil else { return }
        let dismissedOffer = proactiveOffer
        let signature = proactiveOffer?.signature
            ?? proactiveNextActionOffer.map { "next-action:\($0.token)" }
            ?? "unknown"
        dismissedNextActionOfferKeys.insert(Self.nextActionOfferDismissalKey(for: signature))
        proactiveNextActionOffer = nil
        proactiveOffer = nil
        recentNextActionDismissals += 1
        Task {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "employee",
                action: "proactive.dismiss",
                detail: Self.proactiveDecisionAuditDetail(signature: signature, reason: "not_this")
            ))
            if let dismissedOffer {
                await appendPreferenceEvent(
                    kind: .proactiveDismissed,
                    reward: -0.55,
                    surface: "proactive",
                    appName: nil,
                    workflowSignature: dismissedOffer.signature,
                    agentID: dismissedOffer.relatedAgentID,
                    features: Self.offerFeaturePayload(dismissedOffer, state: "dismissed"),
                    evidence: Self.offerEvidencePayload(dismissedOffer)
                )
            }
        }
    }

    static func nextActionOfferDismissalKey(for token: String) -> String {
        let signaturePrefixes = ["next-action:", "agent:", "skill:", "repetition:", "struggle:", "rewind:", "background-web:"]
        if signaturePrefixes.contains(where: { token.hasPrefix($0) }) {
            return AuditIdentity.hash(token)
        }
        return AuditIdentity.hash("next-action:\(token)")
    }

    private func appendPreferenceEvent(
        kind: PreferenceEventKind,
        reward: Double,
        surface: String?,
        appName: String?,
        workflowSignature: String?,
        agentID: Int64?,
        features: [String: String],
        evidence: [String: String] = [:]
    ) async {
        let event = PreferenceEvent(
            kind: kind,
            reward: reward,
            surface: surface,
            appName: appName,
            workflowSignature: workflowSignature,
            agentID: agentID,
            featureJSON: Self.preferenceJSON(features),
            evidenceJSON: evidence.isEmpty ? nil : Self.preferenceJSON(evidence)
        )
        _ = try? await store.appendPreferenceEvent(event)
        if let snapshot = try? await store.personalizationSnapshot() {
            personalizationSnapshot = snapshot
        }
    }

    private nonisolated static func preferenceJSON(_ fields: [String: String]) -> String {
        let sorted = Dictionary(uniqueKeysWithValues: fields.sorted { $0.key < $1.key })
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func recordCuratedProposalsShown(_ proposals: [CuratedAgent]) async {
        for (index, proposal) in proposals.enumerated() {
            let key = "\(proposal.signature)#\(index)"
            guard loggedCuratedProposalKeys.insert(key).inserted else { continue }
            await appendPreferenceEvent(
                kind: .agentProposed,
                reward: 0,
                surface: "manager.review",
                appName: proposal.apps.first,
                workflowSignature: proposal.signature,
                agentID: nil,
                features: Self.curatedFeaturePayload(proposal, displayedRank: index + 1, score: proposal.value),
                evidence: Self.curatedEvidencePayload(proposal)
            )
        }
    }

    private nonisolated static func curatedFeaturePayload(
        _ curated: CuratedAgent,
        displayedRank: Int? = nil,
        score: Double? = nil
    ) -> [String: String] {
        var fields: [String: String] = [
            "candidateType": "curatedAgent",
            "backgroundCapable": runsInBackground(apps: curated.apps) ? "true" : "false",
            "privacyRiskBucket": ((curated.source.quality?.privacyPenalty ?? 0) >= 0.25) ? "medium" : "low",
            "appFamily": AuditIdentity.safeToken((curated.apps.first ?? "unknown").lowercased())
        ]
        if let displayedRank { fields["displayedRank"] = "\(displayedRank)" }
        if let score { fields["score"] = String(format: "%.3f", score) }
        return fields
    }

    private nonisolated static func curatedEvidencePayload(_ curated: CuratedAgent) -> [String: String] {
        [
            "nameHash": auditHash(curated.name),
            "goalHash": auditHash(curated.goal),
            "whyHash": auditHash(curated.why),
            "evidenceCount": "\(curated.evidence.count)",
            "evidenceHash": auditHash(curated.evidence.map(String.init).joined(separator: "|"))
        ]
    }

    private nonisolated static func agentFeaturePayload(_ agent: CascadeAgent) -> [String: String] {
        [
            "candidateType": "savedAgent",
            "backgroundCapable": runsInBackground(apps: agent.apps) ? "true" : "false",
            "appFamily": AuditIdentity.safeToken((agent.apps.first ?? "unknown").lowercased()),
            "runCount": "\(agent.runCount)",
            "scheduled": agent.schedule == nil ? "false" : "true"
        ]
    }

    private nonisolated static func agentEvidencePayload(_ agent: CascadeAgent) -> [String: String] {
        [
            "nameHash": auditHash(agent.name),
            "goalHash": auditHash(agent.goal),
            "evidenceCount": "\(agent.evidenceCount)",
            "evidenceHash": auditHash(agent.evidenceIDs.map(String.init).joined(separator: "|"))
        ]
    }

    private nonisolated static func offerFeaturePayload(_ offer: ProactiveOffer, state: String) -> [String: String] {
        [
            "candidateType": offer.source.rawValue,
            "surfaceFamily": "proactive",
            "state": state,
            "backgroundCapable": offer.source == .backgroundWebAgent ? "true" : "false",
            "privacyRiskBucket": offer.source == .backgroundWebAgent ? "medium" : "low",
            "score": String(format: "%.3f", offer.score),
            "confidence": String(format: "%.2f", offer.confidence)
        ]
    }

    private nonisolated static func offerEvidencePayload(_ offer: ProactiveOffer) -> [String: String] {
        [
            "titleHash": auditHash(offer.title),
            "detailHash": auditHash(offer.detail),
            "evidenceCount": "\(offer.evidence.count)",
            "evidenceHash": auditHash(offer.evidence.joined(separator: "|"))
        ]
    }

    public func acceptProactiveOffer() {
        guard let offer = proactiveOffer else { return }
        proactiveNextActionOffer = nil
        proactiveOffer = nil
        Task {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "employee",
                action: "proactive.accept",
                detail: Self.proactiveOfferAuditDetail(offer, state: "accepted")
            ))
            await appendPreferenceEvent(
                kind: .proactiveAccepted,
                reward: 0.8,
                surface: "proactive",
                appName: nil,
                workflowSignature: offer.signature,
                agentID: offer.relatedAgentID,
                features: Self.offerFeaturePayload(offer, state: "accepted"),
                evidence: Self.offerEvidencePayload(offer)
            )
        }
        switch offer.source {
        case .savedAgent:
            if let id = offer.relatedAgentID, let agent = agents.first(where: { $0.id == id }) {
                deployAgent(agent)
            }
        case .appSkill:
            selectedTab = .cascades
            if let name = offer.skillName {
                dock.show(title: "Skill ready", detail: "Use \(name) with the current app.")
            }
        case .rewindQuestion, .struggle:
            beginUseDeviceIntent(source: "proactive")
        case .backgroundWebAgent:
            _ = createSandboxAgent(task: offer.task ?? offer.title)
        case .liveRepetition:
            selectedTab = .manager
            if let start = offer.rangeStart, let end = offer.rangeEnd {
                Task { [weak self] in
                    guard let self else { return }
                    if let curated = try? await self.orchestrator.curateRange(
                        from: start,
                        to: end,
                        statedIntent: offer.detail,
                        webAppIdentity: Self.webAppIdentity
                    ) {
                        if !self.taughtForReview.contains(where: { $0.signature == curated.signature }) {
                            self.taughtForReview.insert(curated, at: 0)
                        }
                        self.dock.show(title: "Ready for review", detail: "Cascade prepared “\(curated.name)”.")
                        _ = try? await self.store.appendAudit(AuditEvent(
                            actor: "system",
                            action: "proactive.offer",
                            detail: Self.proactiveOfferAuditDetail(offer, state: "curated")
                        ))
                    }
                }
            }
        case .nextAction:
            dock.show(title: offer.title, detail: offer.detail)
        }
    }

    public func snoozeProactiveOffer() {
        guard let offer = proactiveOffer else { return }
        snoozedProactiveOfferKeys.insert(Self.nextActionOfferDismissalKey(for: offer.signature))
        proactiveNextActionOffer = nil
        proactiveOffer = nil
        Task {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "employee",
                action: "proactive.snooze",
                detail: Self.proactiveOfferAuditDetail(offer, state: "snoozed")
            ))
            await appendPreferenceEvent(
                kind: .proactiveSnoozed,
                reward: -0.45,
                surface: "proactive",
                appName: nil,
                workflowSignature: offer.signature,
                agentID: offer.relatedAgentID,
                features: Self.offerFeaturePayload(offer, state: "snoozed"),
                evidence: Self.offerEvidencePayload(offer)
            )
        }
    }

    public func alwaysOfferProactiveSuggestion() {
        guard let offer = proactiveOffer else { return }
        alwaysOfferProactiveKeys.insert(Self.nextActionOfferDismissalKey(for: offer.signature))
        Task {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "employee",
                action: "proactive.accept",
                detail: Self.proactiveOfferAuditDetail(offer, state: "always_offer")
            ))
            await appendPreferenceEvent(
                kind: .proactiveAccepted,
                reward: 1.0,
                surface: "proactive",
                appName: nil,
                workflowSignature: offer.signature,
                agentID: offer.relatedAgentID,
                features: Self.offerFeaturePayload(offer, state: "always_offer"),
                evidence: Self.offerEvidencePayload(offer)
            )
        }
    }

    public func setProactiveControl(_ control: ProactiveAppControl, enabled: Bool, appName: String) {
        let key = Self.proactiveAppKey(appName)
        switch control {
        case .neverSuggest:
            if enabled { neverSuggestApps.insert(key) } else { neverSuggestApps.remove(key) }
        case .onlyInCascade:
            if enabled { onlyInCascadeApps.insert(key) } else { onlyInCascadeApps.remove(key) }
        case .savedAgentsOnly:
            if enabled { savedAgentsOnlyApps.insert(key) } else { savedAgentsOnlyApps.remove(key) }
        }
        Task {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "employee",
                action: "proactive.snooze",
                detail: "scope=app control=\(Self.safeAuditToken(control.rawValue)) appKey=\(Self.safeAuditToken(key)) enabled=\(enabled)"
            ))
            await appendPreferenceEvent(
                kind: enabled ? .personalizationDisabled : .coldStartSet,
                reward: enabled ? -1.0 : 0.2,
                surface: "settings.proactive",
                appName: appName,
                workflowSignature: "app-control:\(control.rawValue):\(key)",
                agentID: nil,
                features: [
                    "candidateType": "appControl",
                    "control": control.rawValue,
                    "enabled": enabled ? "true" : "false"
                ],
                evidence: ["appKeyHash": Self.auditHash(key)]
            )
        }
    }

    private func refreshProactiveNextActionOffer(now: Date) async {
        guard proactiveMode != .off else {
            proactiveNextActionOffer = nil
            proactiveOffer = nil
            return
        }
        let events = ((try? await store.recentInputEvents(limit: 160)) ?? []).reversed()
        let orderedEvents = Array(events)
        let activeEvent = orderedEvents.last
        let activeContext = contexts.first
        let activeAppKey = Self.proactiveAppKey(activeEvent?.appName ?? activeContext?.appName ?? "")
        if neverSuggestApps.contains(activeAppKey)
            || (onlyInCascadeApps.contains(activeAppKey) && selectedTab == .reel) {
            await appendProactiveSuppression(reason: "control.app", signature: activeAppKey)
            proactiveNextActionOffer = nil
            proactiveOffer = nil
            return
        }
        let secondsSinceLastOffer = lastNextActionOfferAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let predictor = NextActionPredictor()
        let prediction = predictor.predict(
            events: orderedEvents,
            webAppIdentity: Self.webAppIdentity,
            activeContext: activeContext
        )
        let liveRepetition = LiveRepetitionDetector().detect(
            events: orderedEvents,
            webAppIdentity: Self.webAppIdentity,
            now: activeEvent?.capturedAt ?? now
        )
        let struggle = StruggleDetector().detect(events: orderedEvents, contexts: contexts)
        let selector = ProactiveHelpSelector()
        let preferenceModel = await suggestionPreferenceModel()
        let routineProfiles = (try? await store.routineProfiles(limit: 200)) ?? []
        let candidates = selector.candidates(
            prediction: prediction,
            liveRepetition: liveRepetition,
            struggle: struggle,
            recentEvents: orderedEvents,
            agents: agents,
            appSkills: appSkills,
            preferenceModel: preferenceModel,
            routineProfiles: routineProfiles,
            dismissedSignatures: dismissedNextActionOfferKeys,
            browserWorkflowsAllowed: backgroundAgents.count < Self.maxConcurrentSandboxAgents,
            webAppIdentity: Self.webAppIdentity,
            now: now
        )
        let filteredCandidates = savedAgentsOnlyApps.contains(activeAppKey)
            ? candidates.filter { $0.kind == .savedAgent }
            : candidates
        guard var selectedOffer = filteredCandidates.first?.offer else {
            proactiveNextActionOffer = nil
            proactiveOffer = nil
            return
        }
        if proactiveMode == .quiet, selectedOffer.level == .action {
            selectedOffer = ProactiveOffer(
                id: selectedOffer.id,
                source: selectedOffer.source,
                level: .passive,
                title: selectedOffer.title,
                detail: selectedOffer.detail,
                actionTitle: selectedOffer.actionTitle,
                signature: selectedOffer.signature,
                confidence: selectedOffer.confidence,
                score: selectedOffer.score,
                evidence: selectedOffer.evidence,
                prediction: selectedOffer.prediction,
                relatedAgentID: selectedOffer.relatedAgentID,
                skillName: selectedOffer.skillName,
                task: selectedOffer.task,
                rangeStart: selectedOffer.rangeStart,
                rangeEnd: selectedOffer.rangeEnd
            )
        }
        let signatureKey = Self.nextActionOfferDismissalKey(for: selectedOffer.signature)
        let gateContext = InterruptibilityContext(
            confidence: selectedOffer.confidence,
            secondsSinceLastOffer: secondsSinceLastOffer,
            recentDismissals: recentNextActionDismissals,
            userIsActivelyTyping: Self.userIsActivelyTyping(events: orderedEvents, now: now),
            isPrivacySensitive: Self.isPrivacySensitive(event: activeEvent, context: activeContext),
            secureInputActive: startsSubsystems ? SecureInputGuard.isActive() : false,
            modifierHeavyKeySequence: Self.hasRecentModifierHeavySequence(events: orderedEvents, now: now),
            draggingOrSelecting: Self.looksLikeDragOrSelection(events: orderedEvents, now: now),
            agentRunning: agentRunning,
            assistTaskRunning: assistTaskRunning,
            stopRequested: driver.runState.isStopRequested,
            permissionsHealthy: !startsSubsystems || (permissionDiagnostics.screenRecording && permissionDiagnostics.accessibility && permissionDiagnostics.inputMonitoring),
            noisySurface: Self.isNoisySurface(event: activeEvent, context: activeContext),
            meetingOrFullscreenOrPrivateSurface: Self.isPrivateOrMeetingSurface(event: activeEvent, context: activeContext),
            perAppSnoozed: false,
            perSignatureSnoozed: snoozedProactiveOfferKeys.contains(signatureKey),
            recentlyDismissedSignature: dismissedNextActionOfferKeys.contains(signatureKey),
            boundary: Self.interruptibilityBoundary(events: orderedEvents, now: now),
            repeatedNoEffectOrErrorPlateau: struggle?.kind == .repeatedClick || struggle?.kind == .repeatedError,
            requiresBoundary: startsSubsystems && !alwaysOfferProactiveKeys.contains(signatureKey)
        )
        let decision = InterruptibilityGate().decide(gateContext)
        await appendProactiveSignal(
            prediction: prediction,
            liveRepetition: liveRepetition,
            struggle: struggle,
            selectedOffer: selectedOffer,
            decision: decision,
            activeEvent: activeEvent,
            activeContext: activeContext
        )
        guard decision == .offer else {
            proactiveNextActionOffer = nil
            proactiveOffer = nil
            return
        }
        proactiveNextActionOffer = selectedOffer.prediction ?? prediction
        proactiveOffer = selectedOffer
        lastNextActionOfferAt = now
        _ = try? await store.appendAudit(AuditEvent(
            actor: "system",
            action: "proactive.offer",
            detail: Self.proactiveOfferAuditDetail(selectedOffer, state: "shown")
        ))
        await appendPreferenceEvent(
            kind: .proactiveOfferShown,
            reward: 0,
            surface: "proactive",
            appName: activeEvent?.appName ?? activeContext?.appName,
            workflowSignature: selectedOffer.signature,
            agentID: selectedOffer.relatedAgentID,
            features: Self.offerFeaturePayload(selectedOffer, state: "shown"),
            evidence: Self.offerEvidencePayload(selectedOffer)
        )
        if selectedOffer.level >= .passive {
            dock.show(title: selectedOffer.title, detail: selectedOffer.detail)
        }
    }

    private func appendProactiveSuppression(reason: String, signature: String) async {
        _ = try? await store.appendAudit(AuditEvent(
            actor: "system",
            action: "proactive.signal",
            detail: Self.proactiveSignalAuditDetail(
                ProactiveSignal(
                    kind: .suppression,
                    reason: reason,
                    confidence: 0,
                    signature: signature,
                    featureSummary: ["suppressed"]
                )
            )
        ))
        await appendPreferenceEvent(
            kind: .proactiveOfferSuppressed,
            reward: -0.2,
            surface: "proactive",
            appName: nil,
            workflowSignature: signature,
            agentID: nil,
            features: [
                "candidateType": "suppression",
                "reason": Self.safeAuditToken(reason)
            ],
            evidence: ["signatureHash": Self.auditHash(signature)]
        )
    }

    private func appendProactiveSignal(
        prediction: NextActionPredictor.Prediction?,
        liveRepetition: LiveRepetitionCandidate?,
        struggle: StruggleSignal?,
        selectedOffer: ProactiveOffer,
        decision: InterruptibilityGate.Decision,
        activeEvent: InputEvent?,
        activeContext: RecordedContext?
    ) async {
        let reason: String
        switch decision {
        case .offer:
            reason = "candidate.selected"
        case .suppress(let code):
            reason = code
        }
        let kind: ProactiveSignal.Kind
        if selectedOffer.source == .liveRepetition {
            kind = .repetition
        } else if selectedOffer.source == .struggle || struggle != nil {
            kind = .struggle
        } else {
            kind = .prediction
        }
        var features: [String] = []
        if let prediction {
            features.append("prediction=\(Self.safeAuditToken(prediction.humanLabel))")
            features.append("evidence=\(prediction.evidenceCount)")
        }
        if let liveRepetition {
            features.append("repeats=\(liveRepetition.occurrences)")
            features.append("stage=\(Self.safeAuditToken(liveRepetition.stage.rawValue))")
        }
        if let struggle {
            features.append("struggle=\(Self.safeAuditToken(struggle.kind.rawValue))")
        }
        let appName = activeEvent?.appName ?? activeContext?.appName
        let window = activeEvent?.windowTitle ?? activeContext?.windowTitle
        let signal = ProactiveSignal(
            kind: kind,
            reason: reason,
            confidence: selectedOffer.confidence,
            signature: selectedOffer.signature,
            featureSummary: features,
            appName: appName.map { Self.safeAuditToken($0) },
            windowHash: window.map(Self.auditHash)
        )
        _ = try? await store.appendAudit(AuditEvent(
            actor: "system",
            action: "proactive.signal",
            detail: Self.proactiveSignalAuditDetail(signal)
        ))
        if case .suppress = decision {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "system",
                action: "proactive.offer",
                detail: Self.proactiveOfferAuditDetail(selectedOffer, state: "suppressed") + " reason=\(Self.safeAuditToken(reason))"
            ))
            await appendPreferenceEvent(
                kind: .proactiveOfferSuppressed,
                reward: -0.15,
                surface: "proactive",
                appName: appName,
                workflowSignature: selectedOffer.signature,
                agentID: selectedOffer.relatedAgentID,
                features: Self.offerFeaturePayload(selectedOffer, state: "suppressed").merging(["reason": Self.safeAuditToken(reason)]) { current, _ in current },
                evidence: Self.offerEvidencePayload(selectedOffer)
            )
        }
    }

    private nonisolated static func proactiveAppKey(_ appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AuditIdentity.safeToken(trimmed.isEmpty ? "unknown" : trimmed.lowercased())
    }

    private nonisolated static func isPrivacySensitive(event: InputEvent?, context: RecordedContext?) -> Bool {
        if let event,
           PrivacyRules.isSensitive(appName: event.appName, bundleIdentifier: event.bundleIdentifier, windowTitle: event.windowTitle) {
            return true
        }
        if let context, PrivacyRules.isSensitive(context) {
            return true
        }
        return false
    }

    private nonisolated static func isNoisySurface(event: InputEvent?, context: RecordedContext?) -> Bool {
        if let event, WasteDetector.isNoisySurface(appName: event.appName, bundleIdentifier: event.bundleIdentifier) {
            return true
        }
        if let context, WasteDetector.isNoisySurface(appName: context.appName, bundleIdentifier: context.bundleIdentifier) {
            return true
        }
        return false
    }

    private nonisolated static func isPrivateOrMeetingSurface(event: InputEvent?, context: RecordedContext?) -> Bool {
        let text = [
            event?.appName, event?.bundleIdentifier, event?.windowTitle,
            context?.appName, context?.bundleIdentifier, context?.windowTitle
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !text.isEmpty else { return false }
        let markers = ["zoom", "meet", "teams", "webex", "fullscreen", "full screen", "private browsing", "incognito", "password", "1password", "keychain"]
        return markers.contains { text.contains($0) }
    }

    private nonisolated static func hasRecentModifierHeavySequence(events: [InputEvent], now: Date, window: TimeInterval = 4) -> Bool {
        let recentKeys = events.suffix(6).filter { event in
            event.kind == .key && now.timeIntervalSince(event.capturedAt) <= window
        }
        guard recentKeys.count >= 2 else { return false }
        return recentKeys.allSatisfy { event in
            let modifiers = Set(event.modifiers.map { $0.lowercased() })
            return !modifiers.isDisjoint(with: ["command", "control", "option"])
        }
    }

    private nonisolated static func looksLikeDragOrSelection(events: [InputEvent], now: Date, window: TimeInterval = 4) -> Bool {
        let recent = events.suffix(8).filter { now.timeIntervalSince($0.capturedAt) <= window }
        guard recent.count >= 3 else { return false }
        let clicks = recent.filter { [.click, .doubleClick, .rightClick].contains($0.kind) }
        let shiftKeys = recent.filter { $0.modifiers.map { $0.lowercased() }.contains("shift") }
        if clicks.count >= 3 {
            let points = Set(clicks.map { "\(Int(($0.x ?? 0) / 10)):\(Int(($0.y ?? 0) / 10))" })
            return points.count >= 3
        }
        return shiftKeys.count >= 2
    }

    private nonisolated static func interruptibilityBoundary(events: [InputEvent], now: Date) -> InterruptibilityContext.Boundary? {
        guard let last = events.last else { return .userOpenedCascade }
        let age = now.timeIntervalSince(last.capturedAt)
        if age >= 2.0 && age <= 20.0 { return .idleAfterAction }
        if isCompletionControl(last) { return .completionControl }
        guard events.count >= 2 else { return nil }
        let previous = events[events.count - 2]
        if previous.appName != last.appName || previous.windowTitle != last.windowTitle {
            return .appOrWindowSwitch
        }
        return nil
    }

    private nonisolated static func isCompletionControl(_ event: InputEvent) -> Bool {
        if event.kind == .key {
            let key = event.key?.lowercased()
            let modifiers = Set(event.modifiers.map { $0.lowercased() })
            return (key == "s" && modifiers.contains("command"))
                || (key == "return" && (modifiers.contains("command") || modifiers.contains("control")))
        }
        guard [.click, .doubleClick, .rightClick].contains(event.kind) else { return false }
        let label = WasteDetector.normalizedActionLabel(event.text)
        let controls: Set<String> = ["apply", "archive", "complete", "done", "download", "export", "finish", "ok", "publish", "save", "send", "submit"]
        return controls.contains(label)
            || controls.contains { label.hasPrefix("\($0) ") }
    }

    private nonisolated static func proactiveSignalAuditDetail(_ signal: ProactiveSignal) -> String {
        var parts = [
            "kind=\(safeAuditToken(signal.kind.rawValue))",
            "reason=\(safeAuditToken(signal.reason))",
            String(format: "confidence=%.2f", signal.confidence),
            "signatureHash=\(auditHash(signal.signature))",
            "featuresHash=\(auditHash(signal.featureSummary.joined(separator: "|")))"
        ]
        if let appName = signal.appName { parts.append("app=\(safeAuditToken(appName))") }
        if let windowHash = signal.windowHash { parts.append("windowHash=\(safeAuditToken(windowHash))") }
        return parts.joined(separator: " ")
    }

    private nonisolated static func proactiveOfferAuditDetail(_ offer: ProactiveOffer, state: String) -> String {
        var parts = [
            "state=\(safeAuditToken(state))",
            "source=\(safeAuditToken(offer.source.rawValue))",
            "level=\(offer.level.rawValue)",
            String(format: "confidence=%.2f", offer.confidence),
            String(format: "score=%.3f", offer.score),
            "signatureHash=\(auditHash(offer.signature))",
            "evidenceHash=\(auditHash(offer.evidence.joined(separator: "|")))"
        ]
        if let id = offer.relatedAgentID { parts.append("agentID=\(id)") }
        if let skillName = offer.skillName { parts.append(textAuditDetail("skill", skillName)) }
        return parts.joined(separator: " ")
    }

    private nonisolated static func proactiveDecisionAuditDetail(signature: String, reason: String) -> String {
        "signatureHash=\(auditHash(signature)) reason=\(safeAuditToken(reason))"
    }

    /// The curated proposals still awaiting review — the review surface's source of
    /// truth (R1). Auto-detected workflows plus the demonstrations the employee sent
    /// up for review (taught-once); same approved/declined filter, keyed by signature.
    /// Taught proposals lead — they're the freshest, most intentional candidates.
	    public var pendingCuratedAgents: [CuratedAgent] {
	        let approved = Set(agents.map(\.signature))
	        var seen = Set<String>()
	        return (taughtForReview + curatedWaste).filter { candidate in
            guard !approved.contains(candidate.signature),
                  !dismissedWasteSignatures.contains(candidate.signature),
                  !seen.contains(candidate.signature) else { return false }
            seen.insert(candidate.signature)
            return true
	        }
	    }

    private func refreshLearningOpportunities(from wastes: [DetectedWaste]) async {
        var opportunities: [LearningOpportunity] = []
        var seen = Set<String>()
        func append(_ opportunity: LearningOpportunity) {
            guard !dismissedLearningOpportunityKeys.contains(opportunity.id),
                  seen.insert(opportunity.id).inserted else { return }
            opportunities.append(opportunity)
        }

        let approvedSignatures = Set(agents.map(\.signature))
        for waste in wastes where Self.meetsRepetitionBar(waste) && !approvedSignatures.contains(waste.signature) {
            let hasActiveSkill = waste.apps.contains { appSkills.skill(appName: $0, bundleIdentifier: nil) != nil }
            guard !hasActiveSkill else { continue }
            append(LearningOpportunity(
                id: "workflow:\(waste.signature)",
                kind: .repeatedWorkflow,
                title: "Form a skill for \(waste.title)",
                detail: "\(waste.occurrences) repeats, \(waste.estimatedSecondsPerRun)s each, with no active approved skill.",
                actionTitle: "Review workflow"
            ))
        }

        let draftsByApp = Dictionary(grouping: pendingLearnedSkills, by: \.appName)
        for (app, drafts) in draftsByApp where drafts.count > 1 {
            append(LearningOpportunity(
                id: "drafts:\(app.lowercased())",
                kind: .overlappingDrafts,
                title: "Consolidate \(app) drafts",
                detail: "\(drafts.count) learned-skill drafts target the same app.",
                actionTitle: "Review drafts"
            ))
        }

        let activeFailureMemories = (try? await store.agentFailureMemories(limit: 200)) ?? []
        let failuresByKey = Dictionary(grouping: activeFailureMemories) {
            "\($0.appName.lowercased())|\($0.failureKind.rawValue)"
        }
        for (_, memories) in failuresByKey where memories.count >= 2 {
            let first = memories[0]
            append(LearningOpportunity(
                id: "failure:\(first.appName.lowercased()):\(first.failureKind.rawValue)",
                kind: .recurringFailure,
                title: "Patch \(first.appName) failure pattern",
                detail: "\(memories.count) active \(first.failureKind.rawValue) avoid rules are recurring.",
                actionTitle: "Review failure rules"
            ))
        }

        for waste in wastes where waste.recipe.steps.contains(where: Self.parameterStepNeedsLabel) {
            append(LearningOpportunity(
                id: "parameter:\(waste.signature)",
                kind: .parameterizedRecipe,
                title: "Name live values in \(waste.title)",
                detail: "This recipe has parameters without useful labels, so a skill should define placeholders before reuse.",
                actionTitle: "Review parameters"
            ))
        }

        learningOpportunities = Array(opportunities.prefix(6))
    }

    nonisolated static func parameterStepNeedsLabel(_ step: RecipeStep) -> Bool {
        guard step.isParameter else { return false }
        let key = step.parameterKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty { return true }
        if key.range(of: #"^(field|value|input|param|parameter)[_-]?\d*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return step.parameterKind == .freeText && key.count < 4
    }

    public func dismissLearningOpportunity(_ opportunity: LearningOpportunity) {
        dismissedLearningOpportunityKeys.insert(opportunity.id)
        learningOpportunities.removeAll { $0.id == opportunity.id }
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "skill.learning_opportunity.dismissed", detail: Self.textAuditDetail("id", opportunity.id))) }
    }

    public func focusLearningOpportunity(_ opportunity: LearningOpportunity) {
        switch opportunity.kind {
        case .overlappingDrafts:
            selectedTab = .cascades
        case .repeatedWorkflow, .recurringFailure, .parameterizedRecipe:
            selectedTab = .manager
        }
    }

	    /// A transient confirmation for the Manager's review queue — approve/decline
    /// happen on the Manager tab, so the only feedback (the new agent landing in the
    /// Cascades tab) is somewhere the manager isn't looking. This banner closes that
    /// gap. It auto-clears, superseded by the next review action.
    @Published public private(set) var managerReviewNote: String?
    private var managerReviewNoteToken = 0

    private func flashManagerReviewNote(_ text: String) {
        managerReviewNoteToken += 1
        let token = managerReviewNoteToken
        managerReviewNote = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.managerReviewNoteToken == token else { return }
            self.managerReviewNote = nil
        }
    }

    /// The MANAGER approves a curated proposal from the review queue: it builds the
    /// agent from the recorded recipe but keeps the curator's human name, and the
    /// approved agent lands in the employee's Cascades tab ("Your agents"), ready to
    /// deploy (in the background sandbox for web work, on-screen for native).
    public func approveCurated(_ curated: CuratedAgent) {
        Task {
            do {
                let agent = try await orchestrator.createAgent(from: curated)
                clearTaughtForReview(signature: curated.signature)
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "manager",
                    action: "agent.approved",
                    detail: Self.curatedAgentAuditDetail(curated, agentID: agent.id)
                ))
                await appendPreferenceEvent(
                    kind: .agentApproved,
                    reward: 1.0,
                    surface: "manager.review",
                    appName: curated.apps.first,
                    workflowSignature: curated.signature,
                    agentID: agent.id,
                    features: Self.curatedFeaturePayload(curated, score: curated.value),
                    evidence: Self.curatedEvidencePayload(curated)
                )
                flashManagerReviewNote("Approved “\(curated.name)” — it's now in the employee's Cascades, ready to deploy.")
            } catch {
                flashManagerReviewNote("Couldn't approve “\(curated.name)”: \(error.localizedDescription)")
            }
            await refreshAll()
        }
    }

    /// The manager dismisses a curated proposal — hides its underlying workflow for
    /// good, so it never returns to the review queue.
    public func declineCurated(_ curated: CuratedAgent) {
        clearTaughtForReview(signature: curated.signature)
        dismissedWasteSignatures.insert(curated.signature)
        flashManagerReviewNote("Dismissed “\(curated.name)” — you won't see it again.")
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "agent.declined", detail: Self.curatedAgentAuditDetail(curated)))
            await appendPreferenceEvent(
                kind: .agentDeclined,
                reward: -1.0,
                surface: "manager.review",
                appName: curated.apps.first,
                workflowSignature: curated.signature,
                agentID: nil,
                features: Self.curatedFeaturePayload(curated, score: curated.value),
                evidence: Self.curatedEvidencePayload(curated)
            )
        }
    }

    public func setAgentEnabled(_ agent: CascadeAgent, enabled: Bool) {
        Task {
            try? await store.setAgentEnabled(id: agent.id, enabled: enabled)
            await appendPreferenceEvent(
                kind: enabled ? .agentEnabled : .agentDisabled,
                reward: enabled ? 0.35 : -1.0,
                surface: "agent.settings",
                appName: agent.apps.first,
                workflowSignature: agent.signature,
                agentID: agent.id,
                features: Self.agentFeaturePayload(agent).merging(["enabled": enabled ? "true" : "false"]) { current, _ in current },
                evidence: Self.agentEvidencePayload(agent)
            )
            await refreshAll()
        }
    }

    public func deleteAgent(_ agent: CascadeAgent) {
        Task {
            try? await store.deleteAgent(id: agent.id)
            await appendPreferenceEvent(
                kind: .agentDeleted,
                reward: -1.0,
                surface: "agent.settings",
                appName: agent.apps.first,
                workflowSignature: agent.signature,
                agentID: agent.id,
                features: Self.agentFeaturePayload(agent),
                evidence: Self.agentEvidencePayload(agent)
            )
            await refreshAll()
        }
    }

    /// Whether a workflow's apps are all web browsers — those agents deploy in the
    /// BACKGROUND sandbox (your screen stays yours, saved sign-ins reused).
    /// "Browser" is decided by CAPABILITY, not a brand list: any app the system
    /// registers to open https URLs qualifies, so every browser the user actually
    /// has — today or one installed later — counts, with nothing hardcoded.
    public nonisolated static func runsInBackground(apps: [String]) -> Bool {
        !apps.isEmpty && apps.allSatisfy { webBrowserNames.contains($0.lowercased()) }
    }

    /// How many non-overlapping repeats a detected workflow needs before it is
    /// worth a manager's attention. The detector recalls anything seen twice (it
    /// powers the Manager's "where the time goes" insight), but turning something
    /// into a reviewable agent demands a genuine HABIT — three or more.
    nonisolated static let minRepeatsToAutomate = 3

    /// The minimum observed time (seconds, across all repeats) a workflow must
    /// represent before it's worth a manager's review. The model's WORTH judgment
    /// (the curator) refines this, but the curator falls back to keeping everything
    /// without a key — so a deterministic floor keeps trivial sub-minute habits out
    /// of the queue regardless. "Really save time" starts here.
    nonisolated static let minSecondsToReview = 30
    nonisolated static let minRoutineQualityScore = 0.08
    nonisolated static let minRoutineDeterminismScore = 0.45
    nonisolated static let maxRoutinePrivacyPenalty = 0.55

    /// A real habit — repeated often enough to be worth automating, not a one-off.
    /// Browser-independent, so it can be pinned without the machine's browser list.
    nonisolated static func meetsRepetitionBar(
        _ waste: DetectedWaste,
        using model: PreferenceModel? = nil,
        ranker: SuggestionRanker = SuggestionRanker()
    ) -> Bool {
        let threshold = personalizationThreshold(for: waste, using: model, ranker: ranker)
        return waste.occurrences >= threshold.minRepeats
    }

    /// Represents real time — the cumulative observed seconds clear the floor, so a
    /// trivial sub-minute habit never reaches the queue even when the curator (which
    /// refines WORTH) is unavailable and would otherwise keep everything.
    nonisolated static func representsRealTime(_ waste: DetectedWaste) -> Bool {
        representsRealTime(waste, using: nil)
    }

    nonisolated static func representsRealTime(
        _ waste: DetectedWaste,
        using model: PreferenceModel?,
        ranker: SuggestionRanker = SuggestionRanker()
    ) -> Bool {
        let threshold = personalizationThreshold(for: waste, using: model, ranker: ranker)
        return waste.estimatedTotalSeconds >= threshold.minObservedSeconds
    }

    nonisolated static func personalizationThreshold(
        for waste: DetectedWaste,
        using model: PreferenceModel?,
        ranker: SuggestionRanker = SuggestionRanker()
    ) -> PersonalizationThreshold {
        guard let model else {
            return PersonalizationThreshold(
                minRepeats: minRepeatsToAutomate,
                minObservedSeconds: minSecondsToReview,
                confidence: 0
            )
        }
        let context = PreferenceContext(
            appName: waste.apps.first,
            surface: "manager.review",
            candidateType: "detectedWaste",
            hourBucket: Calendar.current.component(.hour, from: waste.lastSeenAt),
            backgroundCapable: runsInBackground(apps: waste.apps),
            privacyRiskBucket: (waste.quality?.privacyPenalty ?? 0) >= 0.25 ? "medium" : "low"
        )
        return ranker.personalizationThreshold(
            waste.signature,
            baseRepeats: minRepeatsToAutomate,
            baseObservedSeconds: minSecondsToReview,
            using: model,
            context: context
        )
    }

    nonisolated static func meetsQualityBar(_ waste: DetectedWaste) -> Bool {
        guard let quality = waste.quality else { return true }
        return quality.score >= minRoutineQualityScore
            && quality.determinismScore >= minRoutineDeterminismScore
            && quality.privacyPenalty <= maxRoutinePrivacyPenalty
    }

    /// The product bar for promoting a detected repetition into an agent the
    /// manager reviews: a real, time-saving habit — repeated enough to be a habit and
    /// representing real time. App identity does NOT gate this: a browser-only
    /// workflow deploys to the background sandbox, a native-app one replays on-screen
    /// (and escalates to the full cursor-class runtime on drift), so every kind of
    /// repeated work can become an agent. `deployAgent` routes by app at deploy time.
    nonisolated static func isAutomatable(_ waste: DetectedWaste, using model: PreferenceModel? = nil) -> Bool {
        meetsRepetitionBar(waste, using: model) && representsRealTime(waste, using: model) && meetsQualityBar(waste)
    }

    /// The web app inside a browser an event happened on (Gmail, Notion, Figma…), so a
    /// browser workflow is detected and named as THAT app, not the browser shell.
    /// Native-app events return nil — their app name already is the app. Passed to the
    /// detector so two web apps in one browser become two distinct agents.
    nonisolated static func webAppIdentity(for event: InputEvent) -> String? {
        guard webBrowserNames.contains(event.appName.lowercased()) else { return nil }
        return WebAppIdentity.surface(fromWindowTitle: event.windowTitle)
    }

    /// The app to SHOW for a recorded moment in the Reel: the web app inside the
    /// browser (Gmail, Notion…) when identifiable, else the macOS app — so the Rewind
    /// timeline reads like the user's actual workspace instead of "Google Chrome" for
    /// everything. Native moments return their own name unchanged.
    nonisolated static func displayApp(appName: String, windowTitle: String?) -> String {
        guard webBrowserNames.contains(appName.lowercased()) else { return appName }
        return WebAppIdentity.surface(fromWindowTitle: windowTitle) ?? appName
    }

    /// Installed https-handling apps (i.e. the user's browsers), in every name form
    /// the recorder might have captured them under — filename stem, localized display
    /// name, and bundle display/name keys. Queried once from LaunchServices and cached
    /// (`runsInBackground` is called from view bodies, so it must stay a set lookup).
    /// Empty — e.g. LaunchServices unavailable — degrades safely: agents simply deploy
    /// on-screen instead of in the sandbox.
    private nonisolated static let webBrowserNames: Set<String> = {
        guard let https = URL(string: "https://example.com") else { return [] }
        var names = Set<String>()
        for url in NSWorkspace.shared.urlsForApplications(toOpen: https) {
            names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            names.insert(FileManager.default.displayName(atPath: url.path).lowercased())
            if let info = Bundle(url: url)?.infoDictionary {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = info[key] as? String { names.insert(name.lowercased()) }
                }
            }
        }
        return names
    }()

    /// The natural-language task a recorded web workflow becomes in the sandbox:
    /// the agent there acts from intent (it has its own browser), not from
    /// recorded screen coordinates that mean nothing inside the box.
    static func sandboxTask(for agent: CascadeAgent) -> String {
        // Prefer the curator's plain-language goal — it's the intent written for
        // exactly this task. Recorded pixels mean nothing inside the sandbox; fall
        // back to the agent name only when there's no goal.
        let trimmedGoal = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intent = trimmedGoal.isEmpty ? agent.name : trimmedGoal
        var task = "Do this recurring web task the user normally does by hand: \(intent)."
        if let hint = agent.recipe.steps.compactMap(\.windowTitleHint).first(where: { !$0.isEmpty }) {
            task += " It normally happens on the page “\(String(hint.prefix(80)))”."
        }
        let steps = agent.recipe.humanSteps.filter { $0 != "type" && $0 != "scroll" }.prefix(6).joined(separator: ", ")
        if !steps.isEmpty { task += " The user's recorded steps look like: \(steps)." }
        task += " Carry it out and report the result."
        return task
    }

    /// Runs a saved agent. Web workflows deploy as a BACKGROUND sandbox agent —
    /// the work happens in a floating box while the user keeps their screen.
    /// Everything else replays the recorded recipe on the real Mac — visible
    /// cursor, STOP valve, step cap, every action audited.
    public func deployAgent(_ agent: CascadeAgent) {
        guard trustedAuditHistoryForSensitiveAction() else {
            refuseUntrustedAuditHistory()
            return
        }
        guard !agentRunning else { return }
        guard !agent.recipe.steps.isEmpty else {
            agentMessage = "“\(agent.name)” has no recorded steps yet."
            return
        }
        if Self.runsInBackground(apps: agent.apps) {
            agentMessage = "Running “\(agent.name)” in the background sandbox."
            createSandboxAgent(task: Self.sandboxTask(for: agent), forAgent: agent.id)
            return
        }
        driver.runState.reset()
        agentRunning = true
        agentMessage = "Deploying \(agent.name)…"
        dock.show(title: "Cascade is working", detail: "Running “\(agent.name)” · press STOP to take control.")
        Task { await runAgentRecipe(agent) }
    }

    func runAgentRecipe(_ agent: CascadeAgent) async {
        defer { agentRunning = false }
        guard trustedAuditHistoryForSensitiveAction() else {
            refuseUntrustedAuditHistory()
            return
        }
        let steps = agent.recipe.steps.sorted { $0.order < $1.order }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "recipe.run.started",
            detail: Self.recipeRunAuditDetail(agent: agent)
        ))
        var stoppedEarly = false
        // Clicks whose effect could not be confirmed in a row. One is tolerated
        // (some clicks legitimately change nothing the AX tree shows); two in a row
        // means the recipe has drifted from the live UI — pause instead of plowing
        // on blind (the tiptour-macos pattern).
        var unverifiedStreak = 0
        var verifyUnavailableLogged = false
        var skillVerifySkipLogged = false
        // Pre-replay state gate (JARVIS-1): before the FIRST click we confirm we're
        // actually in the app the recipe expects. If not, escalate to the goal-driven
        // assist loop immediately rather than clicking blind into the wrong screen
        // until two dead clicks trip the drift guard.
        var startStateChecked = false
        for (index, step) in steps.enumerated() {
            if driver.runState.isStopRequested {
                agentMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: agentMessage)
                stoppedEarly = true
                break
            }
            if step.kind == .activateApp {
                dock.show(title: "Open \(step.appName)", detail: step.windowTitleHint ?? "")
                await activateAndConfirm(name: step.appName, bundle: step.bundleIdentifier)
                continue
            }
            // Per-step precondition: a parameter (per-run-varying) value can't be
            // replayed from the recording. Hand the rest to the assist runtime,
            // which supplies the current value — never retype the stale one.
            if Self.recipeStepNeedsLiveValue(step) {
                let recovery = Self.recoveryAction(for: .parameterNeedsLiveValue, attempt: 1)
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "agent",
                    action: "recipe.parameter",
                    detail: Self.recipeAuditDetail(step) + " recoveryAction=\(recovery.rawValue)"
                ))
                await escalateRecipeToAssist(
                    agent,
                    reason: "this step enters a value that changes each run, and I need the current one",
                    failureKind: .parameterNeedsLiveValue,
                    recoveryAction: recovery
                )
                stoppedEarly = true
                break
            }
            do {
                // A sheet/dialog the recording never saw is up — recorded
                // coordinates would click straight into it (tiptour's modal
                // pause). Hand control back instead of plowing on.
                if step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
                    // One-time pre-flight: are we even in the right app before the first
                    // click? Catches activate-failed / wrong-app-stole-focus before we
                    // click into the void (activateAndConfirm gives up silently).
                    if !startStateChecked {
                        startStateChecked = true
                        if let reason = Self.startStateMismatch(step: step) {
                            let recovery = Self.recoveryAction(for: .wrongStartState, attempt: 1)
                            _ = try? await store.appendAudit(AuditEvent(
                                actor: "agent",
                                action: "recipe.pause.wrongstate",
                                detail: Self.textAuditDetail("reason", reason) + " recoveryAction=\(recovery.rawValue)"
                            ))
                            await escalateRecipeToAssist(
                                agent,
                                reason: reason,
                                failureKind: .wrongStartState,
                                recoveryAction: recovery
                            )
                            stoppedEarly = true
                            break
                        }
                    }
                    if let modalTitle = await Self.unexpectedModal() {
                        let recovery = AgentRecoveryPolicy.plan(for: AgentOrchestrator.AgentFailureKind.unexpectedModal).terminal
                        _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "recipe.pause.modal",
                            detail: Self.textAuditDetail("modalTitle", modalTitle) + " recoveryAction=\(recovery.rawValue)"
                        ))
                        await escalateRecipeToAssist(
                            agent,
                            reason: "an unexpected dialog (“\(modalTitle)”) appeared",
                            failureKind: .unexpectedModal,
                            recoveryAction: recovery
                        )
                        stoppedEarly = true
                        break
                    }
                }
                if let x = step.x, let y = step.y,
                   step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
                    let recorded = CGPoint(x: x, y: y)
                    // Canvas apps (Blender) have an AX tree that never reflects
	                    // their visible UI — the skill flags them so replay skips the
	                    // AX tier and fingerprint verification instead of false-pausing.
	                    let stepSkill = appSkills.skill(appName: step.appName, bundleIdentifier: step.bundleIdentifier)
	                    let axUnreliable = stepSkill?.axUnreliable == true
		                    let cacheSkipReason = Self.recipeTargetCacheSkipReason(step: step, axUnreliable: axUnreliable)
		                    let cacheInitialState = cacheSkipReason == nil ? await Self.uiState() : nil
		                    let targetCacheContext: RecipeTargetCacheContext?
		                    if let cacheSkipReason {
		                        targetCacheContext = nil
		                        _ = try? await store.appendAudit(AuditEvent(
		                            actor: "agent",
	                            action: "recipe.target_cache.skipped_sensitive",
		                            detail: Self.recipeTargetCacheAuditDetail(step: step, reason: cacheSkipReason)
		                        ))
		                    } else if let cacheInitialState {
		                        targetCacheContext = await recipeTargetCacheContext(
		                            for: step,
		                            stateFingerprint: String(cacheInitialState.rootHash)
		                        )
		                    } else {
		                        targetCacheContext = nil
		                    }
                            var previousVerifiedEntry: RecipeTargetCacheEntry?
			                    if let targetCacheContext,
			                       let cached = await recipeTargetCache.lookup(targetCacheContext) {
                                previousVerifiedEntry = cached
			                        try await driver.act(.computerUse(.move(x: cached.point.x, y: cached.point.y)))
		                        try? await Task.sleep(for: .milliseconds(320))
		                        try await clickAction(step, at: cached.point)
		                        let cacheVerification = await Self.verifyUIChange(after: cacheInitialState)
		                        if cacheVerification.changed {
			                            _ = await recipeTargetCache.promote(
	                                            targetCacheContext,
	                                            point: cached.point,
	                                            tier: cached.tier,
	                                            verifiedScore: cached.verifiedScore,
	                                            source: cached.source,
	                                            anchorHash: cached.anchorHash
	                                        )
                                        await promoteActionTrajectoryRecipeCache(
                                            step: step,
                                            point: cached.point,
                                            stateFingerprint: cacheInitialState.map { String($0.rootHash) }
                                        )
			                            unverifiedStreak = 0
			                            _ = try? await store.appendAudit(AuditEvent(
		                                actor: "agent",
		                                action: "recipe.target_cache.hit",
		                                detail: Self.recipeTargetCacheAuditDetail(
		                                    step: step,
		                                    tier: cached.tier,
		                                    confidence: cached.confidence,
		                                    deltaReason: cacheVerification.reason
		                                )
		                            ))
		                            dock.show(title: "Step \(index + 1) of \(steps.count)", detail: Self.recipeLabel(step))
		                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.step", detail: Self.recipeAuditDetail(step, tier: "cache")))
		                            try? await Task.sleep(for: .milliseconds(500))
		                            continue
		                        } else if cacheVerification.unavailable {
		                            unverifiedStreak = 0
		                            if !verifyUnavailableLogged {
		                                verifyUnavailableLogged = true
		                                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.verify.unavailable", detail: "AX fingerprint unavailable — steps run unverified"))
		                            }
		                            dock.show(title: "Step \(index + 1) of \(steps.count)", detail: Self.recipeLabel(step))
		                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.step", detail: Self.recipeAuditDetail(step, tier: "cache")))
		                            try? await Task.sleep(for: .milliseconds(500))
		                            continue
		                        }
			                        let demoted = await recipeTargetCache.demote(targetCacheContext)
                                    await demoteActionTrajectoryRecipeCache(
                                        step: step,
                                        stateFingerprint: cacheInitialState.map { String($0.rootHash) },
                                        reason: .wrongScreen
                                    )
		                        _ = try? await store.appendAudit(AuditEvent(
	                            actor: "agent",
	                            action: "recipe.target_cache.demote",
	                            detail: Self.recipeTargetCacheAuditDetail(
		                                step: step,
		                                tier: cached.tier,
		                                reason: cacheVerification.status.rawValue,
		                                confidence: demoted?.confidence,
		                                deltaReason: cacheVerification.reason
		                            )
			                        ))
			                    }
                                    if previousVerifiedEntry == nil,
                                       let targetCacheContext,
                                       await ensureActionTrajectoryCacheSchema() {
                                    let persistentState = ActionTrajectoryState(
                                        appName: step.appName,
                                        bundleIdentifier: step.bundleIdentifier,
                                        windowTitle: step.windowTitleHint,
                                        axFingerprint: cacheInitialState.map { String($0.rootHash) }
                                    )
                                    if let persistentLookup = try? await store.lookupActionTrajectoryCache(
                                        goal: step.humanLabel,
                                        state: persistentState,
                                        targetDescriptor: step.targetDescriptor,
                                        targetText: step.ocrAnchor ?? step.text,
                                        actionKind: "click"
                                    ),
                                       let persistentRow = persistentLookup.executable?.row,
                                       case .click(let cachedX, let cachedY)? = Self.actionTrajectoryCUAction(
                                            kind: persistentRow.actionKind,
                                            json: persistentRow.actionJSON
                                       ) {
                                        let cachedPoint = CGPoint(x: cachedX, y: cachedY)
                                        try await driver.act(.computerUse(.move(x: cachedPoint.x, y: cachedPoint.y)))
                                        try? await Task.sleep(for: .milliseconds(320))
                                        try await clickAction(step, at: cachedPoint)
                                        let persistentVerification = await Self.verifyUIChange(after: cacheInitialState)
                                        if persistentVerification.changed {
                                            _ = await recipeTargetCache.promote(
                                                targetCacheContext,
                                                point: cachedPoint,
                                                tier: .ax,
                                                verifiedScore: persistentRow.confidence,
                                                source: .accessibility,
                                                anchorHash: persistentRow.targetDescriptor.map(AuditIdentity.hash)
                                            )
                                            _ = try? await store.promoteActionTrajectoryCache(
                                                source: .recipe,
                                                goal: step.humanLabel,
                                                state: persistentState,
                                                targetDescriptor: step.targetDescriptor,
                                                targetText: step.ocrAnchor ?? step.text,
                                                action: ActionTrajectoryCacheAction(
                                                    kind: persistentRow.actionKind,
                                                    json: persistentRow.actionJSON,
                                                    preconditionJSON: persistentRow.preconditionJSON,
                                                    postconditionJSON: persistentRow.postconditionJSON
                                                )
                                            )
                                            unverifiedStreak = 0
                                            dock.show(title: "Step \(index + 1) of \(steps.count)", detail: Self.recipeLabel(step))
                                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.step", detail: Self.recipeAuditDetail(step, tier: "persistent_cache")))
                                            try? await Task.sleep(for: .milliseconds(500))
                                            continue
                                        }
                                        if persistentVerification.unavailable {
                                            unverifiedStreak = 0
                                            if !verifyUnavailableLogged {
                                                verifyUnavailableLogged = true
                                                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.verify.unavailable", detail: "AX fingerprint unavailable — steps run unverified"))
                                            }
                                            dock.show(title: "Step \(index + 1) of \(steps.count)", detail: Self.recipeLabel(step))
                                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.step", detail: Self.recipeAuditDetail(step, tier: "persistent_cache")))
                                            try? await Task.sleep(for: .milliseconds(500))
                                            continue
                                        }
                                        _ = try? await store.demoteActionTrajectoryCache(
                                            id: persistentRow.id,
                                            reason: .wrongScreen
                                        )
                                    }
                                }
		                    // Re-grounding cascade. Tier 1 (ax): re-find the element by its
	                    // recorded AX label in the live tree. Tier 2 (ocr): B4's ON-DEVICE
                    // OCR grounder — find the recorded target's text on the live frame
                    // via Apple Vision, no model round-trip, and it sees canvas/Electron
                    // text the AX tree can't. Tier 3 (vision): Claude vision via the OCR
                    // anchor. Tier 4 (recorded): the recorded pixel. The tier lands in
                    // the step's audit row so a drifting recipe is diagnosable.
	                    let axResolution = axUnreliable ? nil : await Self.resolveByAX(step: step, recorded: recorded)
                            if let axResolution,
                               axResolution.isRerankable,
                               let second = axResolution.topCandidates.dropFirst().first,
                               axResolution.confidence - second.confidence <= AnchorDriftScorer.Configuration.default.ambiguousTopMargin {
                                let choices = Self.recipeCandidateChoices(axResolution.topCandidates)
                                _ = try? await store.appendAudit(AuditEvent(
                                    actor: "agent",
                                    action: "recipe.drift",
                                    detail: Self.recipeDriftAuditDetail(
                                        step: step,
                                        outcome: .ambiguous,
                                        reasons: [.closeTopCandidates],
                                        previousScore: previousVerifiedEntry?.verifiedScore,
                                        selectedScore: axResolution.confidence,
                                        candidateCount: axResolution.topCandidates.count
                                    )
                                ))
                                await escalateRecipeToAssist(
                                    agent,
                                    reason: "multiple current targets match this recorded click",
                                    failureKind: .targetNotFound,
                                    recoveryAction: Self.recoveryAction(for: .targetNotFound, attempt: 1),
                                    ambiguityChoices: choices,
                                    ambiguityFrames: axResolution.topCandidates.compactMap { $0.candidate.frame }
                                )
                                stoppedEarly = true
                                break
                            }
                            var driftOutcome: AnchorDriftScorer.Outcome?
                            if let axResolution,
                               let previousVerifiedEntry,
                               axResolution.isRerankable {
                                let drift = AnchorDriftScorer.evaluate(
                                    previous: AnchorDriftScorer.VerifiedAnchor(
                                        score: previousVerifiedEntry.verifiedScore,
                                        source: previousVerifiedEntry.source,
                                        hash: previousVerifiedEntry.anchorHash,
                                        verifiedAt: previousVerifiedEntry.lastVerifiedAt
                                    ),
                                    rankedCandidates: Self.driftCandidates(
                                        from: axResolution.topCandidates,
                                        failureCount: previousVerifiedEntry.failureCount
                                    )
                                )
                                driftOutcome = drift.outcome
                                if drift.outcome != .stable {
                                    _ = try? await store.appendAudit(AuditEvent(
                                        actor: "agent",
                                        action: "recipe.drift",
                                        detail: Self.recipeDriftAuditDetail(
                                            step: step,
                                            outcome: drift.outcome,
                                            reasons: drift.reasons,
                                            previousScore: previousVerifiedEntry.verifiedScore,
                                            selectedScore: drift.selected?.score,
                                            candidateCount: axResolution.topCandidates.count
                                        )
                                    ))
                                }
                            }
	                    let target: CGPoint
	                    let tier: String
                            let targetSource: AnchorDriftScorer.AnchorSource?
                            let targetScore: Double?
                            let targetCandidateCount: Int?
                            let targetAnchorHash: String?
	                    if let axResolution, axResolution.isAutomatic {
	                        target = axResolution.point
	                        tier = "ax"
                                targetSource = axResolution.source
                                targetScore = axResolution.confidence
                                targetCandidateCount = axResolution.topCandidates.count
                                targetAnchorHash = Self.anchorHash(for: axResolution.selectedCandidate)
	                    } else {
                                let ocrTarget = await regroundedByOCR(anchor: step.ocrAnchor ?? step.text)
                                if let axResolution,
                                   axResolution.isRerankable,
                                   let ocrTarget,
                                   hypot(ocrTarget.x - axResolution.point.x, ocrTarget.y - axResolution.point.y) <= 120 {
                                    target = axResolution.point
                                    tier = "ax_rerank"
                                    targetSource = axResolution.source
                                    targetScore = axResolution.confidence
                                    targetCandidateCount = axResolution.topCandidates.count
                                    targetAnchorHash = Self.anchorHash(for: axResolution.selectedCandidate)
                                } else if let ocrTarget {
                                    target = ocrTarget
                                    tier = "ocr"
                                    targetSource = .vision
                                    targetScore = nil
                                    targetCandidateCount = axResolution?.topCandidates.count
                                    targetAnchorHash = nil
                                } else {
                                    let visualTarget = await regroundedTarget(anchor: step.ocrAnchor, recorded: recorded)
                                    if let axResolution,
                                       axResolution.isRerankable,
                                       visualTarget != recorded,
                                       hypot(visualTarget.x - axResolution.point.x, visualTarget.y - axResolution.point.y) <= 160 {
                                        target = axResolution.point
                                        tier = "ax_rerank"
                                        targetSource = axResolution.source
                                        targetScore = axResolution.confidence
                                        targetCandidateCount = axResolution.topCandidates.count
                                        targetAnchorHash = Self.anchorHash(for: axResolution.selectedCandidate)
                                    } else if visualTarget != recorded || axResolution == nil {
                                        target = visualTarget
                                        tier = visualTarget == recorded ? "recorded" : "vision"
                                        targetSource = visualTarget == recorded ? .recordedPoint : .vision
                                        targetScore = nil
                                        targetCandidateCount = axResolution?.topCandidates.count
                                        targetAnchorHash = nil
                                    } else if let axResolution {
                                        await escalateRecipeToAssist(
                                            agent,
                                            reason: "the recorded target is low-confidence in the current UI",
                                            failureKind: .targetNotFound,
                                            recoveryAction: Self.recoveryAction(for: .targetNotFound, attempt: 1),
                                            ambiguityChoices: Self.recipeCandidateChoices(axResolution.topCandidates),
                                            ambiguityFrames: axResolution.topCandidates.compactMap { $0.candidate.frame }
                                        )
                                        stoppedEarly = true
                                        break
                                    } else {
                                        target = recorded
                                        tier = "recorded"
                                        targetSource = .recordedPoint
                                        targetScore = nil
                                        targetCandidateCount = nil
                                        targetAnchorHash = nil
                                    }
                                }
                            }
	                    _ = try? await store.appendAudit(AuditEvent(
                            actor: "agent",
                            action: "recipe.target",
                            detail: Self.recipeTargetAuditDetail(
                                step: step,
                                tier: tier,
                                confidence: targetScore,
                                source: targetSource,
                                score: targetScore,
                                candidateCount: targetCandidateCount,
                                drift: driftOutcome
                            )
                        ))
                    try await driver.act(.computerUse(.move(x: target.x, y: target.y)))
                    try? await Task.sleep(for: .milliseconds(320))

                    if axUnreliable {
                        // Leave unverifiedStreak untouched — a streak from normal
                        // apps should still pause; these steps just don't count.
                        if !skillVerifySkipLogged {
                            skillVerifySkipLogged = true
                            _ = try? await store.appendAudit(AuditEvent(
                                actor: "agent",
                                action: "recipe.verify.skipped-skill",
                                detail: Self.textAuditDetail(stepSkill == nil ? "app" : "skill", stepSkill?.name ?? step.appName)
                            ))
                        }
                        try await clickAction(step, at: target)
                    } else {
	                        let before = await Self.uiState()
	                        if before == nil, !verifyUnavailableLogged {
	                            verifyUnavailableLogged = true
	                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.verify.unavailable", detail: "AX fingerprint unavailable — steps run unverified"))
	                        }
		                        try await clickAction(step, at: target)
		                        let verification = await Self.verifyUIChange(after: before)
		                        if verification.changed {
		                            unverifiedStreak = 0
			                            if let targetCacheContext,
                                           let cacheTier = (tier == "ax_rerank" ? RecipeTargetCacheTier.ax : RecipeTargetCacheTier(rawValue: tier)) {
			                                let promoted = await recipeTargetCache.promote(
                                                targetCacheContext,
                                                point: target,
                                                tier: cacheTier,
                                                verifiedScore: targetScore,
                                                source: targetSource,
                                                anchorHash: targetAnchorHash
                                            )
			                                _ = try? await store.appendAudit(AuditEvent(
			                                    actor: "agent",
			                                    action: "recipe.target_cache.promote",
			                                    detail: Self.recipeTargetCacheAuditDetail(
			                                        step: step,
			                                        tier: cacheTier,
			                                        confidence: promoted.confidence,
			                                        deltaReason: verification.reason
			                                    )
			                                ))
			                            }
                                        await promoteActionTrajectoryRecipeCache(
                                            step: step,
                                            point: target,
                                            stateFingerprint: before.map { String($0.rootHash) }
                                        )
			                        } else if verification.unavailable {
		                            unverifiedStreak = 0
		                        } else {
		                            // One corrective retry at the recorded coordinate (if the
		                            // resolved target differed), then count the step unverified.
		                            if target != recorded {
		                                try await clickAction(step, at: recorded)
		                            }
		                            let retryVerification = await Self.verifyUIChange(after: before)
		                            if retryVerification.changed {
		                                unverifiedStreak = 0
		                                if let targetCacheContext {
			                                    let promoted = await recipeTargetCache.promote(
                                                    targetCacheContext,
                                                    point: recorded,
                                                    tier: .recorded,
                                                    verifiedScore: nil,
                                                    source: .recordedPoint,
                                                    anchorHash: nil
                                                )
			                                    _ = try? await store.appendAudit(AuditEvent(
			                                        actor: "agent",
			                                        action: "recipe.target_cache.promote",
			                                        detail: Self.recipeTargetCacheAuditDetail(
			                                            step: step,
			                                            tier: .recorded,
			                                            confidence: promoted.confidence,
			                                            deltaReason: retryVerification.reason
			                                        )
			                                    ))
			                                }
                                            await promoteActionTrajectoryRecipeCache(
                                                step: step,
                                                point: recorded,
                                                stateFingerprint: before.map { String($0.rootHash) }
                                            )
			                            } else if retryVerification.unavailable {
		                                unverifiedStreak = 0
		                            } else {
	                                unverifiedStreak += 1
	                                let recovery = Self.recoveryAction(for: .noEffect, attempt: unverifiedStreak)
	                                _ = try? await store.appendAudit(AuditEvent(
	                                    actor: "agent",
	                                    action: "recipe.unverified",
	                                    detail: Self.recipeAuditDetail(step)
	                                        + " recoveryAction=\(recovery.rawValue)"
	                                        + " delta=\(Self.safeAuditToken(retryVerification.reason))"
	                                ))
                                if unverifiedStreak >= 2 {
                                    await escalateRecipeToAssist(
                                        agent,
                                        reason: "the screen no longer matches the recorded steps",
                                        failureKind: .noEffect,
                                        recoveryAction: recovery
                                    )
                                    stoppedEarly = true
                                    break
                                }
                            }
                        }
                    }
                } else if step.kind == .type, let text = step.text,
                          appSkills.skill(appName: step.appName, bundleIdentifier: step.bundleIdentifier)?
                              .shouldTypePhysicalKeys(text) == true,
                          let keys = AppSkillRegistry.physicalKeySequence(for: text) {
                    // Recorded modal numeric input (Blender) — the unicode-string
                    // typeText path is silently dropped there; replay as real keys.
                    for key in keys {
                        try await driver.act(.computerUse(.key(key, modifiers: [])))
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    unverifiedStreak = 0
                } else if let action = AgentAction(recipeStep: step) {
                    try await driver.act(action)
                    unverifiedStreak = 0
                }
                dock.show(title: "Step \(index + 1) of \(steps.count)", detail: Self.recipeLabel(step))
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.step", detail: Self.recipeAuditDetail(step)))
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                agentMessage = "Stopped: \(error.localizedDescription)"
                dock.show(title: "Stopped", detail: agentMessage)
                stoppedEarly = true
                break
            }
        }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "recipe.run.ended",
            detail: Self.recipeRunAuditDetail(agent: agent, status: stoppedEarly ? "paused" : "completed")
        ))
        if !stoppedEarly {
            agentMessage = "Done — ran “\(agent.name)”."
            dock.show(title: "Done", detail: agentMessage)
            // Only COMPLETED runs count — the reclaimed-time math multiplies
            // seconds-per-run by this counter, and a stopped run saved nothing.
            await recordOnScreenAgentCompletion(agent)
        }
        await refreshAll()
    }

    /// The natural-language goal a deployed on-screen workflow hands to the assist
    /// runtime: the curator's intent (or the agent name) plus the user's recorded
    /// steps as guidance — so the cursor-class agent reproduces the workflow with the
    /// full kit (skills, harness, streaming) instead of replaying brittle pixels.
    static func deployGoal(for agent: CascadeAgent) -> String {
        let intent = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        var goal = (intent?.isEmpty == false) ? intent! : agent.name
        let steps = agent.recipe.humanSteps.filter { $0 != "type" && $0 != "scroll" }.prefix(8).joined(separator: ", ")
        if !steps.isEmpty { goal += "\n(The user normally does this as: \(steps).)" }
        return goal
    }

    /// Recipe replay drifted from the live UI — instead of pausing, hand the rest of
    /// the job to the FULL assist runtime (skills, harness, streaming) from the current
    /// screen. The "fast deterministic replay, escalate to cursor-class on drift"
    /// model: fast when the UI matches, intelligent when it doesn't. Mirrors the
    /// hotkey/voice setup (bump generation, capture, supersession guard) so a barge-in
    /// still stands the escalated agent down. agentRunning stays true (the caller owns it).
    private func escalateRecipeToAssist(
        _ agent: CascadeAgent,
        reason: String,
        failureKind: AgentOrchestrator.AgentFailureKind? = nil,
        recoveryAction: RecoveryAction? = nil,
        ambiguityChoices: String? = nil,
        ambiguityFrames: [CGRect] = []
    ) async {
        // Honor a pending STOP: runAssistTask resets runState on entry, which would
        // otherwise swallow an abort the user pressed just as drift triggered.
        guard !driver.runState.isStopRequested else {
            agentMessage = "Stopped. Control returned to you."
            dock.show(title: "Stopped", detail: agentMessage)
            return
        }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent",
            action: "recipe.escalate",
            detail: Self.recipeEscalationAuditDetail(
                agent: agent,
                reason: reason,
                failureKind: failureKind,
                recoveryAction: recoveryAction
            )
        ))
        let mouse = NSEvent.mouseLocation
        guard hasAnthropicKey, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            if !ambiguityFrames.isEmpty {
                guidanceOverlay.highlight(globalRects: Array(ambiguityFrames.prefix(2)))
            }
            agentMessage = "Paused “\(agent.name)” — \(reason), and I can't take over without a Claude key. Take over, or re-record."
            dock.show(title: "Paused", detail: agentMessage)
            return
        }
        dock.show(title: "Adapting…", detail: "“\(agent.name)” — \(reason); finishing it intelligently.")
        assistGeneration += 1
        let gen = assistGeneration
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
            agentMessage = "Paused “\(agent.name)” — couldn't capture the screen to take over."
            dock.show(title: "Paused", detail: agentMessage)
            return
        }
        guard assistGeneration == gen else { return } // a barge-in superseded us
        var goal = Self.deployGoal(for: agent)
        if let ambiguityChoices, !ambiguityChoices.isEmpty {
            goal += "\nPossible current targets: \(ambiguityChoices)"
        }
        await runAssistTask(goal: goal, screen: screen, firstScreenshotPNG: shot, gen: gen)
        agentMessage = teachMessage
    }

    /// Performs the step's click kind at a CG global point.
    private func clickAction(_ step: RecipeStep, at point: CGPoint) async throws {
        if let action = AgentAction(recipeStep: Self.retargeted(step, to: point)) {
            try await driver.act(action)
        }
    }

    /// Tier-1 target resolution: the element matching the step's recorded AX label
    /// (stored in `text` for click steps), nearest to the recorded point. Runs off
    /// the main actor — AX tree walks take tens of milliseconds.
    /// Whether the frontmost app is the one a recipe step expects. Bundle id match
    /// wins outright; otherwise display-name containment EITHER direction — a recorded
    /// "Keynote" must still match a live "Keynote Creator Studio" (the exact-equality
    /// blind spot in `activateAndConfirm`). Pure + unit-pinned.
    /// Per-step precondition for parameterized replay (Phase 1, AWM-style). A
    /// `.type` step flagged `isParameter` typed a value that VARIED across the
    /// recorded occurrences — an order number, a date, a name that changes each
    /// run. Deterministic replay only has the STALE recorded value, so its
    /// precondition ("I have the current value") fails: replay must hand off to the
    /// assist runtime, whose deploy goal is written parameter-aware and supplies
    /// the right value from context — never blindly retype last run's. Fixed steps
    /// and pre-`isParameter` recipes return false and replay normally. Pure +
    /// pinned. See [[cascade-cu-downgrade-research]].
    nonisolated static func recipeStepNeedsLiveValue(_ step: RecipeStep) -> Bool {
        step.isParameter && (step.kind == .type || isPasteShortcut(step) || !step.sourceStepIDs.isEmpty)
    }

    nonisolated static func isPasteShortcut(_ step: RecipeStep) -> Bool {
        guard step.kind == .key, step.key?.lowercased() == "v" else { return false }
        let modifiers = step.modifiers.map { $0.lowercased() }
        return modifiers.contains("command") || modifiers.contains("control")
    }

    nonisolated static func appMatches(frontmostName: String?, frontmostBundle: String?, expectedName: String, expectedBundle: String?) -> Bool {
        if let expectedBundle, !expectedBundle.isEmpty, let frontmostBundle, !frontmostBundle.isEmpty,
           expectedBundle == frontmostBundle {
            return true
        }
        guard let frontmostName, !frontmostName.isEmpty, !expectedName.isEmpty else { return false }
        let live = frontmostName.lowercased(), expected = expectedName.lowercased()
        return live == expected || live.contains(expected) || expected.contains(live)
    }

    /// The reason the live screen doesn't match a click step's expected app, or nil
    /// when it does. The pre-replay state gate (JARVIS-1): escalate to goal-driven
    /// assist rather than click blind on the wrong screen.
    private static func startStateMismatch(step: RecipeStep) -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        if appMatches(frontmostName: front?.localizedName, frontmostBundle: front?.bundleIdentifier,
                      expectedName: step.appName, expectedBundle: step.bundleIdentifier) {
            return nil
        }
        return "expected “\(step.appName)” in front but “\(front?.localizedName ?? "no app")” is — the screen isn’t where the recording started"
    }

    private struct RecipeAXResolution: Sendable, Equatable {
        let point: CGPoint
        let confidence: Double
        let source: AnchorDriftScorer.AnchorSource
        let selectedCandidate: AXElementResolver.RankedCandidate
        let topCandidates: [AXElementResolver.RankedCandidate]

        var isAutomatic: Bool { confidence >= AXElementResolver.automaticHealMinimumConfidence }
        var isRerankable: Bool { confidence >= AXElementResolver.rerankMinimumConfidence }
    }

    private static func resolveByAX(step: RecipeStep, recorded: CGPoint) async -> RecipeAXResolution? {
        let label = (step.text ?? step.ocrAnchor) ?? ""
        let (role, identifier, container) = AXTargetDescriptor.decode(step.targetDescriptor)
        // Need a label or a stable identifier to re-find the element by identity.
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty || (identifier?.isEmpty == false) else { return nil }
        let descriptor = AXTargetDescriptorV2.decode(step.targetDescriptor, fallbackLabel: label)
            ?? AXTargetDescriptorV2(
	                label: label,
	                role: role,
	                identifier: identifier,
	                container: container,
	                ancestorPath: container.map { [$0] } ?? []
	            )
        return await Task.detached(priority: .userInitiated) {
            let ranked = AXElementResolver.rank(recorded: descriptor, near: recorded, limit: 5)
            guard let selected = ranked.first,
                  let point = selected.candidate.center else { return nil }
            return RecipeAXResolution(
                point: point,
                confidence: selected.confidence,
                source: Self.anchorSource(for: selected.candidate.source),
                selectedCandidate: selected,
                topCandidates: ranked
            )
        }.value
    }

    nonisolated private static func anchorSource(for source: AXElementResolver.CandidateSource) -> AnchorDriftScorer.AnchorSource {
        switch source {
        case .accessibility: .accessibility
        case .synthetic: .semantic
        case .unknown: .unknown
        }
    }

    nonisolated private static func anchorHash(for candidate: AXElementResolver.RankedCandidate?) -> String? {
        guard let descriptor = candidate?.candidate.descriptor else { return nil }
        return descriptor.identifier
            ?? descriptor.pathHash
            ?? descriptor.subtreeHash
            ?? descriptor.semanticTextHash
            ?? descriptor.semanticHash
    }

    nonisolated static func recipeCandidateChoices(_ candidates: [AXElementResolver.RankedCandidate], limit: Int = 2) -> String {
        candidates.prefix(limit).enumerated().map { index, ranked in
            let descriptor = ranked.candidate.descriptor
            let label = descriptor.label.isEmpty ? "unlabeled" : String(descriptor.label.prefix(36))
            let role = (descriptor.role ?? "AXElement").replacingOccurrences(of: "AX", with: "")
            let container = descriptor.container ?? descriptor.ancestorPath.last ?? "screen"
            return "\(index + 1). \(label) \(role.lowercased()) near \(String(container.prefix(28))) score \(String(format: "%.2f", ranked.confidence))"
        }.joined(separator: "; ")
    }

    nonisolated private static func driftCandidates(
        from ranked: [AXElementResolver.RankedCandidate],
        failureCount: Int = 0
    ) -> [AnchorDriftScorer.Candidate] {
        ranked.map { candidate in
            AnchorDriftScorer.Candidate(
                id: candidate.candidate.id,
                score: candidate.confidence,
                source: anchorSource(for: candidate.candidate.source),
                hash: anchorHash(for: candidate),
                failureCount: failureCount
            )
        }
    }

    private struct UIVerificationResult: Sendable, Equatable {
        enum Status: String, Sendable {
            case changed
            case unchanged
            case unavailable
        }

        let status: Status
        let reason: String

        var changed: Bool { status == .changed }
        var unavailable: Bool { status == .unavailable }
    }

    private static func uiState() async -> UIStateSnapshot? {
        // Off-main by design: AXUIElement calls are IPC (no TIS-style main-thread
        // assert) and a hung frontmost app would otherwise block the main actor —
        // and STOP — for up to 5 polls × 600 nodes × 0.3s AX timeouts.
        await Task.detached(priority: .userInitiated) {
            AXElementResolver.frontmostState(limit: 600, depth: 10)
        }.value
    }

    /// Polls for a meaningful AX delta. Missing AX remains a skip-open condition:
    /// replay proceeds unverified rather than counting the step as a no-effect failure.
    private static func verifyUIChange(after before: UIStateSnapshot?) async -> UIVerificationResult {
        guard let before else {
            return UIVerificationResult(status: .unavailable, reason: "ax_unavailable")
        }
        var lastSummary = "none"
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(80))
            guard let after = await uiState() else {
                return UIVerificationResult(status: .unavailable, reason: "ax_unavailable")
            }
            let delta = AXElementResolver.diff(before, after)
            lastSummary = delta.privacySafeSummary
            if delta.hasMeaningfulChange {
                return UIVerificationResult(status: .changed, reason: lastSummary)
            }
        }
        return UIVerificationResult(status: .unchanged, reason: lastSummary)
    }

    private func actionTrajectoryCachePreflight(goal: String, firstScreenshotPNG: Data) async -> ActionTrajectoryCacheLookup? {
        guard await ensureActionTrajectoryCacheSchema() else { return nil }
        let state = await actionTrajectoryState(firstScreenshotPNG: firstScreenshotPNG)
        return try? await store.lookupActionTrajectoryCache(
            goal: goal,
            state: state,
            topK: 3
        )
    }

    private func ensureActionTrajectoryCacheSchema() async -> Bool {
        guard Self.experimentalActionTrajectoryCacheEnabled(defaults: defaultsStore) else { return false }
        do {
            try await store.ensureActionTrajectoryCacheSchema()
            return true
        } catch {
            _ = try? await store.appendAudit(AuditEvent(
                actor: "agent",
                action: "action_cache.schema",
                detail: "status=failed errorHash=\(Self.auditHash(String(describing: error)))"
            ))
            return false
        }
    }

    private func actionTrajectoryState(firstScreenshotPNG: Data) async -> ActionTrajectoryState {
        let snapshot = await MainActor.run { AppWindowObserver.snapshot() }
        let grid = Self.gridHashes(ofJPEG: firstScreenshotPNG) ?? []
        let ui = await Self.uiState()
        let modalPresent = await Self.unexpectedModal() != nil
        return ActionTrajectoryState(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            screenHash: grid.first,
            screenGridHashes: grid,
            axFingerprint: ui.map { String($0.rootHash) },
            modalPresent: modalPresent
        )
    }

    private nonisolated static func frontmostAppMatches(_ name: String) async -> Bool {
        await MainActor.run {
            guard let front = NSWorkspace.shared.frontmostApplication?.localizedName else {
                return false
            }
            return front.localizedCaseInsensitiveContains(name)
                || name.localizedCaseInsensitiveContains(front)
        }
    }

    private func promoteActionTrajectoryRecipeCache(
        step: RecipeStep,
        point: CGPoint,
        stateFingerprint: String?
    ) async {
        guard await ensureActionTrajectoryCacheSchema(),
              step.kind == .click,
              let actionJSON = Self.actionTrajectoryActionJSON(
                for: .click(x: point.x, y: point.y),
                targetDescriptor: step.targetDescriptor
              ) else {
            return
        }
        let state = ActionTrajectoryState(
            appName: step.appName,
            bundleIdentifier: step.bundleIdentifier,
            windowTitle: step.windowTitleHint,
            axFingerprint: stateFingerprint
        )
        _ = try? await store.promoteActionTrajectoryCache(
            source: .recipe,
            goal: step.humanLabel,
            state: state,
            targetDescriptor: step.targetDescriptor,
            targetText: step.ocrAnchor ?? step.text,
            action: ActionTrajectoryCacheAction(kind: "click", json: actionJSON)
        )
    }

    private func demoteActionTrajectoryRecipeCache(
        step: RecipeStep,
        stateFingerprint: String?,
        reason: ActionTrajectoryCacheDecisionReason
    ) async {
        guard await ensureActionTrajectoryCacheSchema(),
              step.kind == .click else {
            return
        }
        let state = ActionTrajectoryState(
            appName: step.appName,
            bundleIdentifier: step.bundleIdentifier,
            windowTitle: step.windowTitleHint,
            axFingerprint: stateFingerprint
        )
        guard let lookup = try? await store.lookupActionTrajectoryCache(
            goal: step.humanLabel,
            state: state,
            targetDescriptor: step.targetDescriptor,
            targetText: step.ocrAnchor ?? step.text,
            actionKind: "click",
            audit: false
        ), let row = lookup.executable?.row else {
            return
        }
        _ = try? await store.demoteActionTrajectoryCache(id: row.id, reason: reason)
    }

    nonisolated static func actionTrajectoryCUAction(kind: String, json: String) -> CUAction? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch ActionTrajectoryCacheAction.normalizedKind(kind) {
        case "open_app":
            guard let app = stringValue(object, keys: ["app", "name", "app_name"]) else { return nil }
            return .openApp(app)
        case "open_url":
            return nil
        case "click":
            guard let x = doubleValue(object["x"]), let y = doubleValue(object["y"]) else { return nil }
            return .click(x: x, y: y)
        case "scroll":
            guard let x = doubleValue(object["x"]), let y = doubleValue(object["y"]) else { return nil }
            let direction = stringValue(object, keys: ["direction"]) ?? "down"
            let amount = intValue(object["amount"]) ?? 3
            return .scroll(x: x, y: y, direction: direction, amount: amount)
        default:
            return nil
        }
    }

    nonisolated static func actionTrajectoryActionJSON(for action: CUAction, targetDescriptor: String? = nil) -> String? {
        let object: [String: Any]
        switch action {
        case .openApp(let name):
            object = ["app": name]
        case .openURL(let url):
            object = ["url": url]
        case .click(let x, let y):
            var value: [String: Any] = ["x": x, "y": y]
            if let targetDescriptor { value["target_descriptor"] = targetDescriptor }
            object = value
        case .scroll(let x, let y, let direction, let amount):
            object = ["x": x, "y": y, "direction": direction, "amount": amount]
        default:
            return nil
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func recipeTargetCacheContext(for step: RecipeStep, stateFingerprint: String) async -> RecipeTargetCacheContext {
        let snapshot = await MainActor.run { AppWindowObserver.snapshot() }
        return RecipeTargetCacheContext(
            actionKey: step.idempotentActionKey,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier ?? step.bundleIdentifier,
            windowTitle: snapshot.windowTitle ?? step.windowTitleHint,
            stateFingerprint: stateFingerprint
        )
    }

    nonisolated static func recipeTargetCacheSkipReason(step: RecipeStep, axUnreliable: Bool) -> String? {
        if axUnreliable { return "ax_unreliable" }
        if PrivacyRules.isSensitive(
            appName: step.appName,
            bundleIdentifier: step.bundleIdentifier,
            windowTitle: step.windowTitleHint
        ) {
            return "sensitive"
        }
        let identityText = [
            step.kind == .type ? nil : step.text,
            step.ocrAnchor,
            step.targetDescriptor,
            step.parameterKey,
            step.windowTitleHint,
        ].compactMap { $0 }.joined(separator: " ")
        return PrivacyRules.isSensitiveText(identityText) ? "sensitive" : nil
    }

    /// Activates an app and waits (up to ~2s) until it is actually frontmost, so the
    /// next step runs against the right window — a lightweight verify between steps.
    private func activateAndConfirm(name: String, bundle: String?) async {
        activateApp(name: name, bundle: bundle)
        for _ in 0..<8 {
            if driver.runState.isStopRequested { return }
            try? await Task.sleep(for: .milliseconds(250))
            let front = NSWorkspace.shared.frontmostApplication
            // Containment, not equality: a recorded "Keynote" must confirm against a
            // live "Keynote Creator Studio" instead of burning the full 2s poll (and
            // then the B3 state gate would needlessly escalate). Shared matcher.
            if Self.appMatches(frontmostName: front?.localizedName, frontmostBundle: front?.bundleIdentifier,
                               expectedName: name, expectedBundle: bundle) { return }
        }
    }

    /// Re-locates a click target on the current screen using its recorded OCR anchor
    /// (needs a Claude key). Falls back to the recorded global coordinate when there
    /// is no anchor, no key, or the locator can't find it.
    private func regroundedTarget(anchor: String?, recorded: CGPoint) async -> CGPoint {
        guard hasAnthropicKey, let anchor, !anchor.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return recorded
        }
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
            return recorded
        }
        let guidance = await elementLocator.guide(
            screenshot: shot,
            question: "Where is \(anchor)?",
            displayWidthPoints: Int(screen.frame.width),
            displayHeightPoints: Int(screen.frame.height)
        )
        guard let local = guidance.point else { return recorded }
        guard let mapper = DisplayCoordinateMapper(screen: screen),
              let cg = mapper.cgGlobal(fromScreenLocal: local) else {
            let appKitGlobal = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
            return Self.toCGGlobal(appKitGlobal)
        }
        return cg
    }

    /// B4 on-device OCR grounder: re-locate a click target by finding its recorded
    /// text on the live screen via Apple Vision — NO model round-trip and NO
    /// Accessibility, so it grounds canvas/Electron text the AX tier is blind to, and
    /// spares the Claude-vision tier (the freeze) when the target carries text.
    /// Returns nil (caller falls through to Claude vision, then the recorded pixel)
    /// when there's no anchor or no confident text match. The coordinate conversion
    /// mirrors `regroundedTarget` EXACTLY: a Vision bounding box is normalized
    /// lower-left, the same origin as the AppKit display points `local` uses, so the
    /// box centre maps straight through with no Y-flip.
    private func regroundedByOCR(anchor: String?) async -> CGPoint? {
        guard let anchor, !anchor.trimmingCharacters(in: .whitespaces).isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return nil
        }
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else { return nil }
        let boxes = await Task.detached(priority: .userInitiated) {
            ScreenTextRecognizer.recognizeBoxes(inImageData: shot)
        }.value
        guard let match = ScreenTextRecognizer.bestMatch(anchor: anchor, in: boxes) else { return nil }
        let local = CGPoint(x: match.boundingBox.midX * screen.frame.width,
                            y: match.boundingBox.midY * screen.frame.height)
        guard let mapper = DisplayCoordinateMapper(screen: screen) else {
            let appKitGlobal = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
            return Self.toCGGlobal(appKitGlobal)
        }
        return mapper.cgGlobal(fromScreenLocal: local)
    }

    private static func retargeted(_ step: RecipeStep, to point: CGPoint) -> RecipeStep {
        RecipeStep(
            order: step.order,
            kind: step.kind,
            x: point.x,
            y: point.y,
            text: step.text,
            key: step.key,
            modifiers: step.modifiers,
            appName: step.appName,
            bundleIdentifier: step.bundleIdentifier,
            windowTitleHint: step.windowTitleHint,
            surface: step.surface,
            documentIdentityHash: step.documentIdentityHash,
            dataflowEdgeID: step.dataflowEdgeID,
            ocrAnchor: step.ocrAnchor,
            targetDescriptor: step.targetDescriptor,
            isParameter: step.isParameter,
            parameterKey: step.parameterKey,
            parameterKind: step.parameterKind,
            valueExamples: step.valueExamples,
            valueHashes: step.valueHashes,
            sourceStepIDs: step.sourceStepIDs,
            transform: step.transform
        )
    }

    private func activateApp(name: String, bundle: String?) {
        if let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            app.activate()
        }
    }

    /// Launches (or activates) an app by name via `/usr/bin/open -a`, which resolves
    /// the name through LaunchServices — handles apps that aren't running yet and
    /// localized names, unlike a runningApplications scan. Returns whether `open`
    /// accepted the name.
    private static func openApp(named name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private static func recipeLabel(_ step: RecipeStep) -> String {
        switch step.kind {
        case .activateApp: "open \(step.appName)"
        case .click: "click in \(step.appName)"
        case .doubleClick: "double-click in \(step.appName)"
        case .rightClick: "right-click in \(step.appName)"
        case .type: "type “\(step.text.map { String($0.prefix(24)) } ?? "")”"
        case .key: (step.modifiers + [step.key ?? ""]).joined(separator: "+")
        case .scroll: "scroll in \(step.appName)"
        }
    }

    // MARK: - Skill auto-learning (the library compounds with usage)

    /// A skill draft distilled from a successful assist run, awaiting the
    /// user's review in Cascades. Approving moves it into the live library.
    public struct LearnedSkill: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let appName: String
        public let slug: String
        public let markdown: String
        public let sourceTask: String
        public let sourceCaseIDs: [Int64]
        public let evidenceIDs: [Int64]
        public let successCount: Int
        public let failureCount: Int
        public let risk: SkillConsolidator.SkillRisk

        public init(
            id: UUID = UUID(),
            appName: String,
            slug: String,
            markdown: String,
            sourceTask: String,
            sourceCaseIDs: [Int64] = [],
            evidenceIDs: [Int64] = [],
            successCount: Int = 0,
            failureCount: Int = 0,
            risk: SkillConsolidator.SkillRisk = .low
        ) {
            self.id = id
            self.appName = appName
            self.slug = slug
            self.markdown = markdown
            self.sourceTask = sourceTask
            self.sourceCaseIDs = sourceCaseIDs
            self.evidenceIDs = evidenceIDs
            self.successCount = max(0, successCount)
            self.failureCount = max(0, failureCount)
            self.risk = risk
        }
    }

    public struct LearnedSkillConsolidationHint: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case newSkill
            case reviseExisting
            case archiveCandidate
            case quarantine
        }

        public let kind: Kind
        public let title: String
        public let detail: String
        public let existingSkillName: String?
        public let score: Double?
        public let sourceCaseIDs: [Int64]
        public let successCount: Int
        public let failureCount: Int
        public let predictedRisk: SkillConsolidator.SkillRisk
        public let requiredEvidence: [String]
        public let mergeReason: String

        public init(
            kind: Kind,
            title: String,
            detail: String,
            existingSkillName: String?,
            score: Double?,
            sourceCaseIDs: [Int64] = [],
            successCount: Int = 0,
            failureCount: Int = 0,
            predictedRisk: SkillConsolidator.SkillRisk = .low,
            requiredEvidence: [String] = [],
            mergeReason: String = ""
        ) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.existingSkillName = existingSkillName
            self.score = score
            self.sourceCaseIDs = sourceCaseIDs
            self.successCount = successCount
            self.failureCount = failureCount
            self.predictedRisk = predictedRisk
            self.requiredEvidence = requiredEvidence
            self.mergeReason = mergeReason
        }
    }

    @Published public private(set) var pendingLearnedSkills: [LearnedSkill] = []
    /// Per-app action tally for the current assist run (reset per task).
    private var episodeAppActions: [String: Int] = [:]

    /// After a successful run: if the work concentrated in one app that has no
    /// skill yet, distill what worked into a draft SKILL.md for review.
    private func maybeDistillSkill(goal: String, findings: [(task: String, result: String)]) {
        let totalActions = episodeAppActions.values.reduce(0, +)
        guard totalActions >= 6, hasAnthropicKey,
              let (app, count) = episodeAppActions.max(by: { $0.value < $1.value }),
              Double(count) / Double(totalActions) >= 0.7,
              appSkills.skill(appName: app, bundleIdentifier: nil) == nil,
              !pendingLearnedSkills.contains(where: { $0.appName == app })
        else { return }
        let groundingMemo = Self.groundingEvidenceMemo(
            episodeGroundingSelections.filter { $0.app == app && $0.screenChanged },
            calibrationReport: nil
        )
        let sparseAXMemo = Self.sparseAXEvidenceMemo(
            episodeSparseAXProfiles.snapshot().filter { $0.appName == app && $0.isSparse }
        )
        let memo = (findings.map { "\($0.task) → \($0.result)" } + groundingMemo + sparseAXMemo).joined(separator: "\n")
        Task { await distillSkill(app: app, goal: goal, findingsMemo: memo, actionCount: count) }
    }

    private static func groundingEvidenceMemo(
        _ selections: [GroundingSelectionEvidence],
        calibrationReport: VerifierCalibrationReport? = nil,
        minimumSamples: Int = 8,
        minimumAccuracy: Double = 0.85
    ) -> [String] {
        guard !selections.isEmpty else { return [] }
        let highConfidence = selections.filter { $0.confidence >= 0.72 }
        guard !highConfidence.isEmpty else { return [] }
        let grouped = Dictionary(grouping: highConfidence) {
            "\($0.target.lowercased())|\($0.source.rawValue)"
        }
        return grouped.values
            .filter { $0.count >= 1 }
            .prefix(8)
            .map { group in
                let first = group[0]
                let calibrated = Self.groundingBucketIsReliable(
                    confidence: first.confidence,
                    report: calibrationReport,
                    minimumSamples: minimumSamples,
                    minimumAccuracy: minimumAccuracy
                )
                let prefix = calibrated ? "Grounding evidence" : "Grounding hint"
                let verb = calibrated ? "worked" : "previously changed the screen"
                return "\(prefix): target \"\(first.target)\" \(verb) via \(first.source.rawValue) at confidence \(String(format: "%.2f", first.confidence)); candidate hash \(Self.safeAuditToken(first.candidateID)); screen changed after selection."
            }
    }

    nonisolated static func groundingBucketIsReliable(
        confidence: Double,
        report: VerifierCalibrationReport?,
        minimumSamples: Int = 8,
        minimumAccuracy: Double = 0.85
    ) -> Bool {
        guard let report else { return false }
        let bucketCount = max(1, report.buckets.count)
        let index = VerifierCalibration.bucketIndex(for: confidence, bucketCount: bucketCount)
        guard report.buckets.indices.contains(index) else { return false }
        let bucket = report.buckets[index]
        return bucket.sampleCount >= minimumSamples && bucket.accuracy >= minimumAccuracy
    }

    private func distillSkill(app: String, goal: String, findingsMemo: String, actionCount: Int) async {
        let sourceCases = (try? await store.verifiedAgentExperienceCases(appName: app, limit: 8)) ?? []
        guard !sourceCases.isEmpty else { return }
        let agents = (try? await store.agents()) ?? []
        let agentsBySignature = Dictionary(grouping: agents, by: \.signature)
        let activeAvoidRules = (try? await store.agentFailureMemories(
            matching: AgentFailureMemoryQuery(appName: app),
            limit: 12
        )) ?? []
        let procedureMemo = Self.skillProcedureEvidenceMemo(
            app: app,
            goal: goal,
            sourceCases: sourceCases,
            agentsBySignature: agentsBySignature,
            activeAvoidRules: activeAvoidRules
        )
        guard !procedureMemo.isEmpty else { return }
        let sourceCaseIDs = sourceCases.map(\.id)
        let evidenceIDs = Array(Set(sourceCases.flatMap(\.evidenceIDs))).sorted()
        let failureCount = ((try? await store.agentExperienceCases(
            matching: AgentExperienceQuery(appName: app, outcome: .failure),
            limit: 20
        )) ?? []).count
        let risk: SkillConsolidator.SkillRisk = activeAvoidRules.contains(where: { $0.failureKind == .unsafeAction || $0.failureKind == .secureInput || $0.failureKind == .permissionDenied }) ? .safety : (failureCount > 0 ? .medium : .low)
        let user = """
        App: \(app)
        Task the agent just completed there (\(actionCount) on-screen actions): \(goal)
        Verified procedure evidence from the experience ledger:
        \(procedureMemo)

        Supplemental run observations:
        \(findingsMemo)
        """
        guard let markdown = try? await AnthropicClient().complete(
            system: Self.skillAuthorPrompt, user: user, model: AnthropicModel.sonnet, maxTokens: 900
        ), markdown.hasPrefix("---"), markdown.contains("appMatchers") else { return }
        let slug = "learned-" + app.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        enqueueLearnedSkillForReview(LearnedSkill(
            appName: app,
            slug: slug,
            markdown: markdown,
            sourceTask: goal,
            sourceCaseIDs: sourceCaseIDs,
            evidenceIDs: evidenceIDs,
            successCount: sourceCaseIDs.count,
            failureCount: failureCount,
            risk: risk
        ))
	        _ = try? await store.appendAudit(AuditEvent(
	            actor: "agent",
	            action: "skill.learned.draft",
	            detail: Self.learnedSkillDraftAuditDetail(app: app, goal: goal, actionCount: actionCount)
	        ))
	    }

    nonisolated static func skillProcedureEvidenceMemo(
        app: String,
        goal: String,
        sourceCases: [AgentExperienceCase],
        agentsBySignature: [String: [CascadeAgent]],
        activeAvoidRules: [AgentFailureMemory]
    ) -> String {
        let builder = TrajectorySketchBuilder(maxActions: 8, maxAnchors: 6, maxChecks: 4, maxCorrections: 2)
        var sections: [String] = []
        sections.append("source_case_ids: \(sourceCases.map { String($0.id) }.joined(separator: ", "))")
        sections.append("evidence_ids: \(Array(Set(sourceCases.flatMap(\.evidenceIDs))).sorted().map(String.init).joined(separator: ", "))")

        var preconditions = Set<String>()
        var parameters: [String] = []
        var steps: [String] = []
        var postconditions = Set<String>()
        var seenParameters = Set<String>()
        var seenSteps = Set<String>()

        for experience in sourceCases {
            guard let agent = agentsBySignature[experience.recipeSignature]?.first else { continue }
            let sketch = builder.build(
                goal: experience.goalPattern.isEmpty ? goal : experience.goalPattern,
                recipe: agent.recipe,
                experiences: [experience]
            )
            if let appName = Self.safeProcedureText(sketch.appName) {
                preconditions.insert("App is \(appName).")
            }
            if let windowTitle = Self.safeProcedureText(sketch.windowTitle) {
                preconditions.insert("Relevant window contains \(windowTitle).")
            }
            for step in agent.recipe.steps.sorted(by: { $0.order < $1.order }) {
                if step.isParameter, let line = Self.parameterProcedureLine(step), seenParameters.insert(line).inserted {
                    parameters.append(line)
                }
            }
            for action in sketch.firstActions {
                let repeatText = action.repeatCount > 1 ? " \(action.repeatCount)x" : ""
                let line = "\(action.index). \(action.label)\(repeatText)"
                if let safe = Self.safeProcedureText(line), seenSteps.insert(safe).inserted {
                    steps.append(safe)
                }
            }
            for check in sketch.expectedChecks {
                if let safe = Self.safeProcedureText(check.label) {
                    postconditions.insert(safe)
                }
            }
        }

        let avoid = activeAvoidRules
            .filter { rule in
                let queryTokens = Set(TrajectorySketch.normalizedGoalTokens(from: goal))
                return queryTokens.isEmpty || !Set(rule.normalizedGoalTokens).isDisjoint(with: queryTokens)
            }
            .prefix(5)
            .compactMap { rule -> String? in
                guard rule.isActive else { return nil }
                let note = Self.failureSpecificMemoryNote(for: rule.failureKind)
                let hint = Self.safeProcedureText(rule.repairHint)
                let state = Self.safeProcedureText(rule.stateSummary).map { " State: \($0)" } ?? ""
                return "- \(rule.failureKind.rawValue): \(note) \(hint ?? "")\(state)"
            }

        if !preconditions.isEmpty {
            sections.append("preconditions:\n\(preconditions.sorted().map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !parameters.isEmpty {
            sections.append("parameters:\n\(parameters.joined(separator: "\n"))")
        }
        if !steps.isEmpty {
            sections.append("steps:\n\(steps.prefix(12).map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !postconditions.isEmpty {
            sections.append("postconditions:\n\(postconditions.sorted().prefix(6).map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !avoid.isEmpty {
            sections.append("avoid:\n\(avoid.joined(separator: "\n"))")
        }
        return sections.joined(separator: "\n\n")
    }

    private nonisolated static func parameterProcedureLine(_ step: RecipeStep) -> String? {
        let key = step.parameterKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? step.ocrAnchor?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "value"
        guard let safeKey = safeProcedureText(key) else { return nil }
        let placeholder = "<\(safeKey.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_")))>"
        let kind = step.parameterKind?.rawValue ?? "freeText"
        let hashes = Array(step.valueHashes.prefix(3)).map { String($0) }.joined(separator: ", ")
        let hashText = hashes.isEmpty ? "" : "; observed value hashes: \(hashes)"
        return "- \(safeKey): \(placeholder) (\(kind))\(hashText)"
    }

    private nonisolated static func safeProcedureText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !PrivacyRules.isSensitiveText(trimmed),
              !PIIDetector.containsHighConfidencePII(trimmed) else {
            return nil
        }
        let redacted = PIIDetector.redact(trimmed, includeNames: false, highConfidenceOnly: false).redacted
            .replacingOccurrences(of: #"\b[A-Za-z0-9_\-]{24,}\b"#, with: "<TOKEN>", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{7,}\b"#, with: "<NUMBER>", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? nil : String(redacted.prefix(220))
    }

    private static let skillAuthorPrompt = """
    You distill a completed computer-use run into a Cascade app skill: a SKILL.md \
    the agent will pull next time it works in this app. Output ONLY the file content.

    Format, exactly:
    ---
    name: <short-kebab-name>
    description: <one line>
    useWhen: <one line — when the agent should pull this skill>
    ---

    # <Title>

    ## Procedure

    ### Preconditions
    - 2–4 concrete app/window/state conditions evidenced by the source cases.

    ### Parameters
    - List each live value as `<placeholder>` with its kind. Never include raw typed values.

    ### Steps
    - 5–9 short, imperative steps with what actually works in this app: the \
    reliable entry points, shortcuts, gotchas, and the order that worked. Only \
    include things evidenced by verified source cases — no generic advice.

    ### Postconditions
    - Completion checks the next run should verify from visible state.

    ### Avoid
    - Failure-avoidance rules only from active failure memories. For safety, \
    permission, or secure-input failures, write boundary-respecting advice only; \
    never describe bypasses.

    ```cascade-runtime-hints
    {"appMatchers": {"names": ["<App Name>"]}}
    ```

    When the run evidence shows repeated or high-confidence grounding choices, you
    MAY add these optional keys inside cascade-runtime-hints:
    - "targetAliases": {"<canonical visible target>": ["<phrase the agent used>"]}
    - "preferredGroundingSource": "accessibility" or "ocr"
    - "axUnreliable": true only when the run proves AX was unreliable
    - "keysFollowPointer": true only when keyboard input followed the pointer
    Do not invent hints without evidence in the memo.
    """

    public func enqueueLearnedSkillForReview(_ skill: LearnedSkill) {
        pendingLearnedSkills.append(skill)
    }

    public func learnedSkillConsolidationHint(for skill: LearnedSkill) -> LearnedSkillConsolidationHint? {
	        guard defaultsStore.bool(forKey: Self.experimentalSkillConsolidationKey) else { return nil }
	        return Self.learnedSkillConsolidationHint(for: skill, registry: appSkills)
	    }

    public static func learnedSkillConsolidationHint(
        for skill: LearnedSkill,
        registry: AppSkillRegistry,
        consolidator: SkillConsolidator = SkillConsolidator()
    ) -> LearnedSkillConsolidationHint {
	        let path = "/Cascade/Skills/\(skill.slug)/SKILL.md"
	        let sourceCaseIDStrings = Set(skill.sourceCaseIDs.map(String.init))
	        guard let candidate = SkillConsolidator.record(
	            id: skill.slug,
	            markdown: skill.markdown,
	            path: path,
	            source: "draft",
	            approved: false,
	            successCount: skill.successCount,
	            failureCount: skill.failureCount,
	            evidenceIDs: Set(skill.evidenceIDs.map(String.init)),
	            sourceCaseIDs: sourceCaseIDStrings,
	            risk: skill.risk,
	            status: .draft
	        ), skill.markdown.hasPrefix("---"), candidate.skill.hints.appMatchers != nil else {
	            return LearnedSkillConsolidationHint(
	                kind: .quarantine,
	                title: "Quarantine draft",
                detail: "Cascade could not parse this draft as a valid SKILL.md. Review the metadata before adding it.",
                existingSkillName: nil,
                score: nil
            )
        }

        let existing = consolidator.learnedSkillRecords(from: registry, source: "user")
        let namesByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.skill.name) })
	        let result = consolidator.evaluate(candidate, against: existing)
	        let score = result.bestMatch?.total
	        func metadata(
	            _ kind: LearnedSkillConsolidationHint.Kind,
	            _ title: String,
	            _ detail: String,
	            _ existingSkillName: String?
	        ) -> LearnedSkillConsolidationHint {
	            LearnedSkillConsolidationHint(
	                kind: kind,
	                title: title,
	                detail: detail,
	                existingSkillName: existingSkillName,
	                score: score,
	                sourceCaseIDs: result.sourceCaseIDs.compactMap(Int64.init),
	                successCount: result.successCount,
	                failureCount: result.failureCount,
	                predictedRisk: result.predictedRisk,
	                requiredEvidence: result.requiredEvidence,
	                mergeReason: result.mergeReason
	            )
	        }

	        switch result.action {
	        case .newSkill:
	            return metadata(
	                .newSkill,
	                "New skill",
	                "No similar loaded user skill matched this draft. Approval will add it as a new playbook.",
	                nil
	            )
	        case .reviseExisting(let existingID):
	            let name = namesByID[existingID] ?? existingID
	            return metadata(
	                .reviseExisting,
	                "Revise existing skill",
	                "Similar to \(name). Treat this as an update candidate; Cascade will not edit the existing skill automatically.",
	                name
	            )
	        case .archiveCandidate(let existingID):
	            let name = namesByID[existingID] ?? existingID
	            return metadata(
	                .archiveCandidate,
	                "Archive candidate",
	                "\(name) already covers this draft with stronger signal. Discard it unless you want a separate playbook.",
	                name
	            )
	        case .quarantine(let reason):
	            return metadata(
	                .quarantine,
	                "Quarantine draft",
	                "Cascade marked this draft for review: \(reason).",
	                nil
	            )
	        }
	    }

    private static func sparseAXEvidenceMemo(_ profiles: [AXRuntimeProfile], minimumSamples: Int = 2) -> [String] {
        guard profiles.count >= minimumSamples else { return [] }
        let nodes = profiles.map(\.sampledNodeCount).reduce(0, +) / max(1, profiles.count)
        let labeled = profiles.map(\.labeledActionableCount).reduce(0, +) / max(1, profiles.count)
        let canvas = profiles.map(\.canvasSizedElementRatio).reduce(0, +) / Double(max(1, profiles.count))
        return [
            "AX sparse evidence: \(profiles.count) sampled turns exposed sparse accessibility for this app (avg nodes \(nodes), avg labeled actionable \(labeled), avg canvas ratio \(String(format: "%.2f", canvas))). It is legitimate to set \"axUnreliable\": true if other run evidence also relied on OCR or visual grounding."
        ]
    }

    /// Moves a reviewed draft into the live skill library (user skills dir).
	    public func approveLearnedSkill(_ skill: LearnedSkill) {
	        guard let root = learnedSkillDirectory ?? Self.defaultLearnedSkillDirectory() else { return }
	        let dir = root.appendingPathComponent(skill.slug, isDirectory: true)
	        let hint = learnedSkillConsolidationHint(for: skill)
	        let approvedMarkdown = Self.markdownWithLearnedSkillMetadata(skill, hint: hint)
	        do {
	            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	            try approvedMarkdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
	        } catch {
	            teachMessage = "Couldn't save the skill: \(error.localizedDescription)"
            return
        }
        pendingLearnedSkills.removeAll { $0.id == skill.id }
        if learnedSkillDirectory == nil {
            appSkills = AppSkillRegistry.load()
        }
	        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "skill.learned.approved", detail: Self.textAuditDetail("app", skill.appName))) }
	    }

    nonisolated static func markdownWithLearnedSkillMetadata(
        _ skill: LearnedSkill,
        hint: LearnedSkillConsolidationHint?,
        now: Date = Date()
    ) -> String {
        guard skill.markdown.hasPrefix("---\n"),
              let endRange = skill.markdown.range(
                of: "\n---",
                range: skill.markdown.index(skill.markdown.startIndex, offsetBy: 4)..<skill.markdown.endIndex
              ) else {
            return skill.markdown
        }
        let existingBlock = String(skill.markdown[skill.markdown.index(skill.markdown.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let existingKeys = Set(existingBlock.split(separator: "\n").compactMap { line -> String? in
            line.split(separator: ":", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        })
        let parentSkills = hint?.existingSkillName.map { [$0] } ?? []
        let version = hint?.kind == .reviseExisting ? 2 : 1
        let metadata: [(String, String)] = [
            ("version", "\(version)"),
            ("parentSkills", Self.yamlInlineList(parentSkills)),
            ("sourceCaseIDs", Self.yamlInlineList(skill.sourceCaseIDs.map(String.init))),
            ("lastVerifiedAt", ISO8601DateFormatter().string(from: now)),
            ("successCount", "\(max(skill.successCount, hint?.successCount ?? 0))"),
            ("failureCount", "\(max(skill.failureCount, hint?.failureCount ?? 0))"),
            ("riskClass", (hint?.predictedRisk ?? skill.risk).rawValue),
            ("status", "active"),
        ].filter { !existingKeys.contains($0.0) }
        guard !metadata.isEmpty else { return skill.markdown }
        let insertion = metadata.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        var updated = skill.markdown
        updated.insert(contentsOf: "\n\(insertion)", at: endRange.lowerBound)
        return updated
    }

    private nonisolated static func yamlInlineList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "[]" }
        return "[" + values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") + "]"
    }

	    private static func defaultLearnedSkillDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cascade/Skills", isDirectory: true)
    }

    public func discardLearnedSkill(_ skill: LearnedSkill) {
        pendingLearnedSkills.removeAll { $0.id == skill.id }
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "skill.learned.discarded", detail: Self.textAuditDetail("app", skill.appName))) }
    }

    // MARK: - Agent scheduling

    private var schedulerTask: Task<Void, Never>?
    private var firedScheduleKeys: Set<String> = []

    /// "daily@HH:mm" check every 30s. Background (sandbox) agents fire for
    /// real; on-screen agents only get a reminder — Cascade never takes the
    /// user's screen unprompted.
    func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fireDueSchedules()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func fireDueSchedules() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let nowSlot = formatter.string(from: Date())
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: Date())

        for agent in agents where agent.enabled {
            guard agent.schedule == "daily@\(nowSlot)" else { continue }
            let key = "\(agent.id)@\(today)@\(nowSlot)"
            guard !firedScheduleKeys.contains(key) else { continue }
            guard capturePrivacyPolicy.scheduledRunsAvailable else {
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "policy",
                    action: "policy.enforced",
                    detail: Self.scheduleAuditDetail(agent: agent, schedule: agent.schedule, status: "blocked_policy")
                ))
                continue
            }
            if Self.runsInBackground(apps: agent.apps) {
                // Only consume the daily slot if it actually started — if the cap
                // refused, leave the key unset so a later tick (this minute) retries.
                guard createSandboxAgent(task: Self.sandboxTask(for: agent), forAgent: agent.id) else { continue }
                firedScheduleKeys.insert(key)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.schedule.fired", detail: Self.scheduleAuditDetail(agent: agent, schedule: agent.schedule, status: "fired")))
                agentMessage = "Scheduled: running “\(agent.name)” in the background."
            } else {
                firedScheduleKeys.insert(key)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.schedule.due", detail: Self.scheduleAuditDetail(agent: agent, schedule: agent.schedule, status: "due")))
                dock.show(title: "Scheduled agent is due", detail: "“\(agent.name)” is ready — deploy it from Cascades whenever you want.")
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    if self?.agentRunning != true { self?.dock.dismiss() }
                }
            }
        }
        if firedScheduleKeys.count > 500 { firedScheduleKeys.removeAll() }
    }

    public func setAgentSchedule(_ agent: CascadeAgent, schedule: String?) {
        guard schedule == nil || capturePrivacyPolicy.scheduledRunsAvailable else {
            refuseManagedPolicy(capability: "agent_schedule", reason: "scheduled_runs_unavailable")
            return
        }
        Task {
            try? await store.setAgentSchedule(id: agent.id, schedule: schedule)
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "agent.schedule.set", detail: Self.scheduleAuditDetail(agent: agent, schedule: schedule, status: "set")))
            await appendPreferenceEvent(
                kind: schedule == nil ? .agentScheduleCleared : .agentScheduleSet,
                reward: schedule == nil ? -0.25 : 0.8,
                surface: "agent.schedule",
                appName: agent.apps.first,
                workflowSignature: agent.signature,
                agentID: agent.id,
                features: Self.agentFeaturePayload(agent).merging([
                    "schedule": schedule ?? "off",
                    "scheduled": schedule == nil ? "false" : "true"
                ]) { current, _ in current },
                evidence: Self.agentEvidencePayload(agent)
            )
            await refreshAll()
        }
    }

    private static let onboardedKey = "cascade.onboarded"

    /// Closes the first-run guide for good (Settings can reopen it).
    public func finishOnboarding() {
        showOnboarding = false
        defaultsStore.set(true, forKey: Self.onboardedKey)
        refreshPermissionState()
        startRecording()
    }

    public var personalizationEnabled: Bool {
        get { Self.enabledByDefault(defaultsStore, key: Self.experimentalSuggestionRankingKey) }
        set {
            defaultsStore.set(newValue, forKey: Self.experimentalSuggestionRankingKey)
            Task {
                await appendPreferenceEvent(
                    kind: newValue ? .coldStartSet : .personalizationDisabled,
                    reward: newValue ? 0.2 : -1.0,
                    surface: "settings.personalization",
                    appName: nil,
                    workflowSignature: "personalization.enabled",
                    agentID: nil,
                    features: [
                        "candidateType": "personalizationControl",
                        "enabled": newValue ? "true" : "false"
                    ],
                    evidence: [:]
                )
                await refreshAll()
            }
        }
    }

    public func clearAllPersonalization() {
        dismissedWasteSignatures.removeAll()
        dismissedNextActionOfferKeys.removeAll()
        snoozedProactiveOfferKeys.removeAll()
        alwaysOfferProactiveKeys.removeAll()
        Task {
            try? await store.clearPersonalization()
            if let snapshot = try? await store.personalizationSnapshot() {
                personalizationSnapshot = snapshot
            }
            await refreshAll()
        }
    }

    public func clearPersonalization(signature: String? = nil, appName: String? = nil) {
        if let signature { dismissedWasteSignatures.remove(signature) }
        if let appName {
            let key = Self.proactiveAppKey(appName)
            neverSuggestApps.remove(key)
            onlyInCascadeApps.remove(key)
            savedAgentsOnlyApps.remove(key)
        }
        Task {
            try? await store.clearPersonalization(workflowSignature: signature, appName: appName)
            if let snapshot = try? await store.personalizationSnapshot() {
                personalizationSnapshot = snapshot
            }
            await refreshAll()
        }
    }

    public func toggleTheme() {
        prefersDark.toggle()
    }

    public func refreshKeyStatus() {
        hasAnthropicKey = keyStore.hasKey()
        keyMessage = hasAnthropicKey
            ? "Claude key connected in macOS Keychain."
            : "Paste your Anthropic API key to enable Claude-backed Q&A and agent generation."
        hasOpenAIKey = openAIKeyStore.hasKey()
        openAIKeyMessage = hasOpenAIKey
            ? "OpenAI key connected — GPT-Realtime voice enabled."
            : "Paste your OpenAI API key to enable the GPT-Realtime voice (talk + spoken replies)."
        hasGroqKey = groqKeyStore.hasKey()
        groqKeyMessage = hasGroqKey
            ? "Groq key connected — planner, validators, and the Scout on-screen agent can run on Groq."
            : "Paste your Groq API key to run the cheap models (Llama 3.3 70B planner/validators, Llama 4 Scout agent)."
        hasOpenRouterKey = openRouterKeyStore.hasKey()
        openRouterKeyMessage = hasOpenRouterKey
            ? "OpenRouter key connected — the on-screen agent grounds clicks with hosted UI-TARS."
            : "Paste your OpenRouter API key to ground the on-screen agent with hosted UI-TARS (Opus plans, UI-TARS locates)."
        refreshVisualGrounderRuntimeStatus()
    }

    private func refreshVisualGrounderRuntimeStatus() {
        let d = defaultsStore
        let backend = d.string(forKey: "cascade.visualGrounder.backend") ?? "uitars"
        let presetID = backend == "claude"
            ? "claude"
            : (d.string(forKey: "cascade.visualGrounder.preset") ?? GrounderRegistry.defaultPresetID)
        let preset = GrounderRegistry.preset(id: presetID)
        let model = d.string(forKey: "cascade.visualGrounder.model")
            .flatMap { $0.isEmpty ? nil : $0 } ?? preset.modelID
        let endpoint = d.string(forKey: "cascade.visualGrounder.endpoint")
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (preset.endpointClass == .hosted ? GrounderRegistry.defaultHostedEndpoint : "http://localhost:8000/v1/chat/completions")
        let coordSpace = UITARSGrounder.CoordSpace(
            rawValue: d.string(forKey: "cascade.visualGrounder.coordSpace") ?? ""
        ) ?? preset.coordinateSpace
        let score = d.object(forKey: "cascade.visualGrounder.lastMiniEvalScore") as? Double
        visualGrounderRuntime = VisualGrounderRuntimeStatus(
            preset: preset,
            backend: backend,
            modelID: model,
            endpoint: endpoint,
            coordSpace: coordSpace,
            probeStatus: d.string(forKey: "cascade.visualGrounder.coordProbeStatus") ?? "not run",
            lastMiniEvalScore: score
        )
    }

    public func selectVisualGrounderPreset(_ presetID: String) {
        let preset = GrounderRegistry.preset(id: presetID)
        defaultsStore.set(preset.id, forKey: "cascade.visualGrounder.preset")
        defaultsStore.set(preset.endpointClass == .claude ? "claude" : "uitars", forKey: "cascade.visualGrounder.backend")
        defaultsStore.set(preset.modelID, forKey: "cascade.visualGrounder.model")
        defaultsStore.set(preset.coordinateSpace.rawValue, forKey: "cascade.visualGrounder.coordSpace")
        if preset.endpointClass == .hosted {
            defaultsStore.set(GrounderRegistry.defaultHostedEndpoint, forKey: "cascade.visualGrounder.endpoint")
        } else if defaultsStore.string(forKey: "cascade.visualGrounder.endpoint")?.isEmpty != false {
            defaultsStore.set("http://localhost:8000/v1/chat/completions", forKey: "cascade.visualGrounder.endpoint")
        }
        defaultsStore.set("not run", forKey: "cascade.visualGrounder.coordProbeStatus")
        refreshVisualGrounderRuntimeStatus()
    }

    public func updateVisualGrounderEndpoint(_ endpoint: String) {
        defaultsStore.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "cascade.visualGrounder.endpoint")
        defaultsStore.set("not run", forKey: "cascade.visualGrounder.coordProbeStatus")
        refreshVisualGrounderRuntimeStatus()
    }

    public func updateVisualGrounderCoordSpace(_ rawValue: String) {
        guard UITARSGrounder.CoordSpace(rawValue: rawValue) != nil else { return }
        defaultsStore.set(rawValue, forKey: "cascade.visualGrounder.coordSpace")
        defaultsStore.set("not run", forKey: "cascade.visualGrounder.coordProbeStatus")
        refreshVisualGrounderRuntimeStatus()
    }

    public func runVisualGrounderCoordinateProbe() {
        let coordSpace = visualGrounderRuntime.coordSpace
        let output = GrounderRegistry.syntheticProbeOutput(for: coordSpace)
        let probe = GrounderRegistry.probeCoordSpace(coordSpace: coordSpace, modelOutput: output)
        let status: String
        switch probe.status {
        case .passed:
            status = "passed \(coordSpace.rawValue)"
        case .failed:
            status = "failed \(coordSpace.rawValue)"
        case .parseMiss:
            status = "parse miss \(coordSpace.rawValue)"
        }
        defaultsStore.set(status, forKey: "cascade.visualGrounder.coordProbeStatus")
        refreshVisualGrounderRuntimeStatus()
    }

    public func saveAnthropicKey(_ key: String) {
        do {
            try keyStore.save(key)
            refreshKeyStatus()
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    public func clearAnthropicKey() {
        do {
            try keyStore.delete()
            refreshKeyStatus()
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    public func saveOpenAIKey(_ key: String) {
        do {
            try openAIKeyStore.save(key)
            refreshKeyStatus()
        } catch {
            openAIKeyMessage = error.localizedDescription
        }
    }

    public func clearOpenAIKey() {
        do {
            try openAIKeyStore.delete()
            refreshKeyStatus()
        } catch {
            openAIKeyMessage = error.localizedDescription
        }
    }

    public func saveGroqKey(_ key: String) {
        do {
            try groqKeyStore.save(key)
            refreshKeyStatus()
        } catch {
            groqKeyMessage = error.localizedDescription
        }
    }

    public func clearGroqKey() {
        do {
            try groqKeyStore.delete()
            refreshKeyStatus()
        } catch {
            groqKeyMessage = error.localizedDescription
        }
    }

    public func saveOpenRouterKey(_ key: String) {
        do {
            try openRouterKeyStore.save(key)
            refreshKeyStatus()
        } catch {
            openRouterKeyMessage = error.localizedDescription
        }
    }

    public func clearOpenRouterKey() {
        do {
            try openRouterKeyStore.delete()
            refreshKeyStatus()
        } catch {
            openRouterKeyMessage = error.localizedDescription
        }
    }

    public func refreshPermissionState() {
        recorder.refreshPermissions()
        permissionDiagnostics = PermissionProbe.diagnostics()
        autoStartIfPermitted()
        statusLine = recorder.status.message
    }

    public func setCapturePrivateMode(_ enabled: Bool) {
        var policy = capturePrivacyPolicy
        policy.privateModeEnabled = enabled
        capturePrivacyPolicy = policy
        statusLine = enabled ? "Recording paused by private mode." : recorder.status.message
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "privacy.private_mode", detail: "enabled=\(enabled)")) }
    }

    public func exportCapturePolicyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(capturePrivacyPolicy.exportedJSONString(), forType: .string)
        statusLine = "Capture policy JSON copied."
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "policy.exported", detail: "format=json")) }
    }

    public func importCapturePolicyFromPasteboard() {
        guard let json = NSPasteboard.general.string(forType: .string),
              let policy = try? CapturePrivacyPolicy.importJSONString(json) else {
            statusLine = "Clipboard does not contain a valid capture policy JSON document."
            return
        }
        capturePrivacyPolicy = policy
        statusLine = "Capture policy imported."
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "policy.imported", detail: "format=json version=\(Self.safeAuditToken(policy.version))"))
            await refreshAll()
        }
    }

    public func exportPrivacyManifestToPasteboard(scope: PrivacyDataScope = PrivacyDataScope()) {
        Task {
            do {
                let manifest = try await store.privacyExportManifest(scope: scope, policy: capturePrivacyPolicy)
                copyJSONToPasteboard(manifest)
                statusLine = "Privacy manifest copied."
                privacySummary = manifest.summary
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "employee",
                    action: "privacy.exported",
                    detail: "contexts=\(manifest.summary.totalContexts) omitted=\(manifest.omittedFields.count)"
                ))
            } catch {
                statusLine = error.localizedDescription
            }
        }
    }

    public func deletePrivacyData(scope: PrivacyDataScope = PrivacyDataScope()) {
        Task {
            do {
                let result = try await store.deletePrivacyData(scope: scope)
                for path in result.backingImagePaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "employee",
                    action: "privacy.deleted",
                    detail: "contexts=\(result.deletedContextCount) inputEvents=\(result.deletedInputEventCount) files=\(result.backingImagePaths.count)"
                ))
                statusLine = "Deleted \(result.deletedContextCount) captured moments."
                await refreshAll()
            } catch {
                statusLine = error.localizedDescription
            }
        }
    }

    public func exportAgentAuditToPasteboard(format: AgentAuditExportFormat = .siemJSONL) {
        Task {
            do {
                let (content, package) = try await agentAuditExportContent(format: format)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
                statusLine = "Agent audit \(format.rawValue) copied."
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "employee",
                    action: "audit.exported",
                    detail: "format=\(Self.safeAuditToken(format.rawValue)) traces=\(package.manifest.traceCount) spans=\(package.manifest.spanCount)"
                ))
            } catch {
                statusLine = error.localizedDescription
            }
        }
    }

    public func saveAgentAuditExport(format: AgentAuditExportFormat) {
        Task {
            do {
                let (content, package) = try await agentAuditExportContent(format: format)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = Self.agentAuditExportFilename(format)
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try content.write(to: url, atomically: true, encoding: .utf8)
                statusLine = "Agent audit \(format.rawValue) saved."
                let action = format == .diagnosticBundleMetadata ? "trace.export.diagnostic" : "audit.exported"
                _ = try? await store.appendAudit(AuditEvent(
                    actor: "employee",
                    action: action,
                    detail: "format=\(Self.safeAuditToken(format.rawValue)) traces=\(package.manifest.traceCount) spans=\(package.manifest.spanCount) destination=file"
                ))
            } catch {
                statusLine = error.localizedDescription
            }
        }
    }

    private func agentAuditExportContent(format: AgentAuditExportFormat) async throws -> (String, AgentAuditExportPackage) {
        guard capturePrivacyPolicy.agentAuditExportAvailable else {
            refuseManagedPolicy(capability: "audit_export", reason: "agent_audit_export_unavailable")
            throw CocoaError(.userCancelled)
        }
        if format == .diagnosticBundleMetadata, !capturePrivacyPolicy.diagnosticBundleExportAvailable {
            refuseManagedPolicy(capability: "diagnostic_export", reason: "diagnostic_bundle_export_unavailable")
            throw CocoaError(.userCancelled)
        }
        let status = try await store.verifyAuditChain()
        auditIntegrityStatus = Self.auditIntegrityStatus(from: status)
        guard !auditIntegrityEnforcementEnabled || AgentAuditExportPackage.isTrusted(status) else {
            refuseManagedPolicy(capability: "audit_export", reason: "audit_chain_untrusted")
            throw CocoaError(.userCancelled)
        }
        let end = Date()
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let events = try await store.auditWindowForTraceAssembly(from: start, to: end, enableTraceAssembly: true)
        let package = AgentAuditExportPackage.build(
            trustedChronologicalEvents: events,
            windowStart: start,
            windowEnd: end,
            auditChainStatus: status,
            auditHead: try await store.auditHead()
        )
        let content = format == .manifestJSON ? package.manifestJSON() : package.content(format: format)
        return (content, package)
    }

    private static func agentAuditExportFilename(_ format: AgentAuditExportFormat) -> String {
        switch format {
        case .otelJSON:
            return "cascade-traces-otlp.json"
        case .siemJSONL:
            return "cascade-traces-siem.jsonl"
        case .csv:
            return "cascade-traces-csv-bundle.txt"
        case .reliabilityJSONL:
            return "cascade-reliability.jsonl"
        case .manifestJSON:
            return "cascade-trace-manifest.json"
        case .diagnosticBundleMetadata:
            return "cascade-diagnostic-metadata.json"
        }
    }

    public func copySLOSnapshotToPasteboard() {
        let snapshot = sloSnapshot ?? ReliabilityReport.sloSnapshot(from: [])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.deterministicJSON(), forType: .string)
        statusLine = "SLO snapshot copied."
    }

    private func copyJSONToPasteboard<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Prepends a freshly recorded moment to the Reel, newest-first, capped so the
    /// in-memory list stays bounded.
    private func ingestLiveMoment(_ context: RecordedContext) {
        guard !contexts.contains(where: { $0.id == context.id }) else { return }
        contexts.insert(context, at: 0)
        if contexts.count > 200 {
            contexts.removeLast(contexts.count - 200)
        }
    }

    public func refreshClickMarkers(near context: RecordedContext?) {
        guard let context else { return }
        if reelClickMarkersByContextID[context.id] != nil { return }
        Task {
            let events = (try? await store.clickInputEvents(near: context.capturedAt, window: 1.25, limit: 12)) ?? []
            let markers = events.compactMap(ReelClickMarker.init(event:))
            reelClickMarkersByContextID[context.id] = markers
        }
    }

    /// Full-text search over recorded moments. Empty query clears results and the
    /// Reel falls back to the recent timeline.
    public func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        Task {
            let results = (try? await store.searchContexts(query: trimmed)) ?? []
            // Ignore stale responses if the query moved on while we awaited.
            guard searchQuery == trimmed else { return }
            searchResults = results
        }
    }

    public func requestScreenRecording() {
        _ = PermissionProbe.requestScreenRecordingPrompt()
        refreshPermissionState()
    }

    public func requestAccessibility() {
        PermissionProbe.request(.accessibility)
        refreshPermissionState()
    }

    public func requestInputMonitoring() {
        PermissionProbe.request(.inputMonitoring)
        refreshPermissionState()
    }

    public func refreshComputerUseHealth() async {
        let health = await NativeComputerUseActuator().health()
        screenAgentReady = health.ready
        screenAgentMessage = health.message
    }

    public func refreshComputerUseHealthFromUI() {
        Task { await refreshComputerUseHealth() }
    }

    public func openSystemSettings() {
        let now = Date()
        guard now.timeIntervalSince(lastSettingsOpen) > 1.0 else { return }
        lastSettingsOpen = now
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        if let bundleURL = Bundle.main.bundleURL as URL? {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
    }
}

private extension MixtureGrounder.VerifierOutcome {
    var auditOutcome: String {
        switch outcome {
        case .selected:
            return "selected"
        case .rejected:
            return "rejected"
        case .abstained:
            return "abstained"
        case .drifted:
            return "drifted"
        case .ambiguous:
            return "ambiguous"
        case .demote:
            return "demote"
        case .retryNextCandidate:
            return "retryNextCandidate"
        }
    }
}
