import CascadeMemory
import Foundation
import ProviderKit

/// §6 MEASURE — the Phase-0 baseline ledger.
///
/// A pure, read-only derivation of per-surface reliability metrics from the
/// `audit_event` table: episode failure rate with a terminated-vs-succeeded split,
/// no-effect rate, grounding source shares, verifier accept/reject/abstain,
/// transport retries, turn latency, escalations, and cost. Every later phase
/// diffs against this snapshot.
///
/// Double-gated and additive: nothing in any shipped code path calls this file,
/// and the only store-touching entry point (`FailureLedger.snapshot`) is dead
/// unless `enabled == true` (defaults to the env flag `CASCADE_FAILURE_LEDGER`,
/// absent everywhere today). Even when ON it is SELECT-only via the existing
/// opt-in `CascadeStore.auditWindowForTraceAssembly(enableTraceAssembly:)` read
/// API — no `appendAudit`, no schema change, no default flip.

/// The half-open time window a ledger snapshot was derived over.
public struct FailureLedgerWindow: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Verifier verdict tallies parsed from `grounding.verifier` rows via the
/// existing `verdict=` detail token (emitted by
/// `CascadeAppModel.groundingVerifierAuditDetail`).
public struct FailureLedgerVerifierCounts: Codable, Sendable, Equatable {
    public let accepted: Int
    public let rejected: Int
    public let abstained: Int

    public init(accepted: Int, rejected: Int, abstained: Int) {
        self.accepted = accepted
        self.rejected = rejected
        self.abstained = abstained
    }

    public static let zero = FailureLedgerVerifierCounts(accepted: 0, rejected: 0, abstained: 0)
}

/// Per-surface metrics — one row per surface (`assist` / `backgroundWeb` /
/// `recipeReplay`) seen in the window.
public struct FailureLedgerSurfaceMetrics: Codable, Sendable, Equatable {
    public let surface: String
    public let episodes: Int
    public let episodesSucceeded: Int
    /// 98c2f2a SPLIT: `ScenarioStatus` .failed / .paused / .escalated.
    public let episodesTerminated: Int
    /// .refused / .userStop — desirable terminals per
    /// `AgentFailureKind.isDesirableTerminal`; EXCLUDED from the failure-rate
    /// denominator.
    public let episodesRefusedOrStopped: Int
    /// terminated / (succeeded + terminated); 0 when the denominator is 0.
    public let episodeFailureRate: Double
    public let stepsAttempted: Int
    public let noEffectCount: Int
    public let noEffectRate: Double
    /// Keyed by `ProviderKit.GroundingSource.rawValue` (accessibility / dom /
    /// ocr / uiTars / claude / cache / visualModel / compatibility / unknown),
    /// parsed from the structured `source=<raw>` safe-token the SANITIZED
    /// emitters persist on `agent.ground` / `sandbox.ground` rows
    /// (`CascadeAppModel.groundAuditDetail` /
    /// `BackgroundWebAgent.sandboxGroundAuditDescriptor` — the in-agent log
    /// string at ComputerUseAgent.swift:1906 is hashed by P7-05/P7-07 before
    /// appendAudit and is NOT the persisted format). Raw enum keys are the
    /// truth — no lossy remap to coarser buckets. Rows whose token is missing
    /// or unrecognized — including all history persisted before the source
    /// token existed — count under `unknown` (degrade to MISSED, never FALSE).
    public let groundingSourceShares: [String: Double]
    public let verifier: FailureLedgerVerifierCounts
    /// Sum of `AgentTrace.retryCount` across the surface's episodes.
    public let transportRetries: Int
    /// Count of raw rows classifying as `AgentFailureKind.transportFailure`.
    public let transportFailures: Int
    /// From each trace's span extent (min start → max end), nearest-rank.
    public let episodeDurationMsP50: Int
    public let episodeDurationMsP95: Int
    /// `ScenarioOutcome.status == .escalated` episodes plus raw
    /// `recipe.escalate` rows, deduplicated: an escalated episode whose trace
    /// already contains a `recipe.escalate` span is counted ONCE via the raw
    /// row, so a recipeReplay run that both audited the escalation and
    /// resolved to an escalate terminal never counts twice.
    public let escalations: Int
    /// Sum of `AgentTrace.totalCostUSD` — best-effort; 0 on surfaces that do
    /// not emit cost tokens yet (reported as 0 with the field present so later
    /// phases diff cleanly).
    public let costUSD: Double
    /// `AgentFailureKind.rawValue` histogram via `init?(auditAction:detail:)`
    /// over raw rows — independent of episode segmentation.
    public let failureKindCounts: [String: Int]

    public init(
        surface: String,
        episodes: Int,
        episodesSucceeded: Int,
        episodesTerminated: Int,
        episodesRefusedOrStopped: Int,
        episodeFailureRate: Double,
        stepsAttempted: Int,
        noEffectCount: Int,
        noEffectRate: Double,
        groundingSourceShares: [String: Double],
        verifier: FailureLedgerVerifierCounts,
        transportRetries: Int,
        transportFailures: Int,
        episodeDurationMsP50: Int,
        episodeDurationMsP95: Int,
        escalations: Int,
        costUSD: Double,
        failureKindCounts: [String: Int]
    ) {
        self.surface = surface
        self.episodes = episodes
        self.episodesSucceeded = episodesSucceeded
        self.episodesTerminated = episodesTerminated
        self.episodesRefusedOrStopped = episodesRefusedOrStopped
        self.episodeFailureRate = episodeFailureRate
        self.stepsAttempted = stepsAttempted
        self.noEffectCount = noEffectCount
        self.noEffectRate = noEffectRate
        self.groundingSourceShares = groundingSourceShares
        self.verifier = verifier
        self.transportRetries = transportRetries
        self.transportFailures = transportFailures
        self.episodeDurationMsP50 = episodeDurationMsP50
        self.episodeDurationMsP95 = episodeDurationMsP95
        self.escalations = escalations
        self.costUSD = costUSD
        self.failureKindCounts = failureKindCounts
    }
}

/// Wiring-smoke input: a flag-ON module's promised audit actions.
public struct FailureLedgerExpectedModule: Codable, Sendable, Equatable {
    public let module: String
    public let expectedActions: [String]

    public init(module: String, expectedActions: [String]) {
        self.module = module
        self.expectedActions = expectedActions
    }
}

/// Wiring-smoke output: every expected action that emitted 0 rows in the window
/// (the e6e5275 antidote — a flag-ON module whose promised actions never appear
/// is DORMANT, not working). A module is listed iff `dormantActions` is
/// non-empty.
public struct FailureLedgerDormantFinding: Codable, Sendable, Equatable {
    public let module: String
    public let dormantActions: [String]

    public init(module: String, dormantActions: [String]) {
        self.module = module
        self.dormantActions = dormantActions
    }
}

/// The full ledger dump — deterministic, diffable, Codable.
public struct FailureLedgerSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let window: FailureLedgerWindow
    /// How many audit rows the derivation actually saw. When a fetch is bounded
    /// by `limit` and `eventsScanned == limit`, `truncated` is true so a
    /// baseline diff never silently compares a truncated window against a full
    /// one.
    public let eventsScanned: Int
    public let truncated: Bool
    /// Sorted by surface name.
    public let surfaces: [FailureLedgerSurfaceMetrics]
    /// Sorted by module.
    public let dormant: [FailureLedgerDormantFinding]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        window: FailureLedgerWindow,
        eventsScanned: Int,
        truncated: Bool,
        surfaces: [FailureLedgerSurfaceMetrics],
        dormant: [FailureLedgerDormantFinding]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.window = window
        self.eventsScanned = eventsScanned
        self.truncated = truncated
        self.surfaces = surfaces
        self.dormant = dormant
    }

    /// Deterministic JSON dump (`.sortedKeys` + `.iso8601` dates), mirroring
    /// `ReliabilityReport.SLOSnapshot.deterministicJSON` (ReliabilityReport.swift:465)
    /// so baseline snapshots diff cleanly run-to-run.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

public enum FailureLedger {
    public static let flagEnvironmentKey = "CASCADE_FAILURE_LEDGER"

    /// Default-OFF: true only when the env var is exactly "1".
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[flagEnvironmentKey] == "1"
    }

    // MARK: Pure core

    /// Derive a snapshot from already-fetched audit rows. Pure: no store, no
    /// clock (beyond the injected `generatedAt`), no side effects.
    public static func derive(
        events: [AuditEvent],
        window: FailureLedgerWindow,
        generatedAt: Date = Date(),
        expectedWiring: [FailureLedgerExpectedModule] = [],
        truncated: Bool = false
    ) -> FailureLedgerSnapshot {
        // (a) Episode pass: segment runs with the real builder and roll up the
        // ScenarioOutcome-derived splits per surface.
        var episodeAccumulators: [String: EpisodeAccumulator] = [:]
        let traces = AgentTraceBuilder.fromAuditEvents(events)
        for trace in traces {
            var acc = episodeAccumulators[trace.surface] ?? EpisodeAccumulator()
            let outcome = trace.scenarioOutcome
            acc.episodes += 1
            switch outcome.status {
            case .success:
                acc.succeeded += 1
            case .failed, .paused, .escalated:
                acc.terminated += 1
            case .refused, .userStop:
                acc.refusedOrStopped += 1
            }
            // Dedup with the raw pass: a trace that AUDITED its escalation
            // (a `recipe.escalate` span) is already counted by the raw
            // `recipe.escalate` row below — only count episode escalations
            // the raw rows can't see.
            if outcome.status == .escalated,
               !trace.spans.contains(where: { $0.name == "recipe.escalate" }) {
                acc.escalations += 1
            }
            acc.stepsAttempted += outcome.stepsAttempted
            acc.noEffectCount += outcome.noEffectCount
            acc.transportRetries += trace.retryCount
            acc.durationsMs.append(trace.durationMs)
            acc.costUSD += trace.totalCostUSD
            episodeAccumulators[trace.surface] = acc
        }

        // (b) Raw-event pass: classify each row's surface by action prefix and
        // accumulate the segmentation-independent counters.
        var rawAccumulators: [String: RawAccumulator] = [:]
        for event in events {
            let surface = rawSurface(forAction: event.action)
            var acc = rawAccumulators[surface] ?? RawAccumulator()
            if event.action == "agent.ground" || event.action == "sandbox.ground" {
                acc.groundingSourceCounts[groundingSourceKey(in: event.detail), default: 0] += 1
            }
            if event.action == "grounding.verifier" {
                switch auditValue("verdict", in: event.detail) {
                case "accept": acc.verifierAccepted += 1
                case "reject": acc.verifierRejected += 1
                case "abstain": acc.verifierAbstained += 1
                default: break
                }
            }
            if event.action == "recipe.escalate" {
                acc.escalations += 1
            }
            if let kind = AgentFailureKind(auditAction: event.action, detail: event.detail) {
                acc.failureKindCounts[kind.rawValue, default: 0] += 1
                if kind == .transportFailure { acc.transportFailures += 1 }
            }
            rawAccumulators[surface] = acc
        }

        // (c) Merge episode + raw accumulators per surface, sort, snapshot.
        let allSurfaces = Set(episodeAccumulators.keys).union(rawAccumulators.keys)
        let surfaces = allSurfaces.sorted().map { surface -> FailureLedgerSurfaceMetrics in
            let episode = episodeAccumulators[surface] ?? EpisodeAccumulator()
            let raw = rawAccumulators[surface] ?? RawAccumulator()
            let failureDenominator = episode.succeeded + episode.terminated
            let totalGroundRows = raw.groundingSourceCounts.values.reduce(0, +)
            let shares: [String: Double] = totalGroundRows == 0
                ? [:]
                : raw.groundingSourceCounts.mapValues { Double($0) / Double(totalGroundRows) }
            return FailureLedgerSurfaceMetrics(
                surface: surface,
                episodes: episode.episodes,
                episodesSucceeded: episode.succeeded,
                episodesTerminated: episode.terminated,
                episodesRefusedOrStopped: episode.refusedOrStopped,
                episodeFailureRate: failureDenominator == 0
                    ? 0
                    : Double(episode.terminated) / Double(failureDenominator),
                stepsAttempted: episode.stepsAttempted,
                noEffectCount: episode.noEffectCount,
                noEffectRate: episode.stepsAttempted == 0
                    ? 0
                    : Double(episode.noEffectCount) / Double(episode.stepsAttempted),
                groundingSourceShares: shares,
                verifier: FailureLedgerVerifierCounts(
                    accepted: raw.verifierAccepted,
                    rejected: raw.verifierRejected,
                    abstained: raw.verifierAbstained
                ),
                transportRetries: episode.transportRetries,
                transportFailures: raw.transportFailures,
                episodeDurationMsP50: percentile(episode.durationsMs, 0.50),
                episodeDurationMsP95: percentile(episode.durationsMs, 0.95),
                escalations: episode.escalations + raw.escalations,
                costUSD: episode.costUSD,
                failureKindCounts: raw.failureKindCounts
            )
        }

        return FailureLedgerSnapshot(
            generatedAt: generatedAt,
            window: window,
            eventsScanned: events.count,
            truncated: truncated,
            surfaces: surfaces,
            dormant: wiringSmoke(events: events, expected: expectedWiring)
        )
    }

    // MARK: Store entry point (flag-gated, read-only)

    /// Fetch a window of audit rows and derive the ledger. Returns nil unless
    /// `enabled` — the guard-parameter shape of
    /// `CascadeStore.auditWindowForTraceAssembly(enableTraceAssembly:)` — so
    /// with the flag absent not a single SQL statement executes.
    ///
    /// Requires a chained audit store: `appendAudit` chains rows, and the
    /// existing read API returns [] on broken/truncated/unchained chains. That
    /// empty result is a correct fail-safe — a MISSED measurement, never a
    /// FALSE one (LAW 7). The fetch is bounded by `limit`; when the row count
    /// hits it the snapshot is marked `truncated`.
    public static func snapshot(
        store: CascadeStore,
        from: Date,
        to: Date,
        limit: Int = 5000,
        expectedWiring: [FailureLedgerExpectedModule] = [],
        generatedAt: Date = Date(),
        enabled: Bool = FailureLedger.isEnabled
    ) async throws -> FailureLedgerSnapshot? {
        guard enabled else { return nil }
        let events = try await store.auditWindowForTraceAssembly(
            from: from,
            to: to,
            limit: limit,
            enableTraceAssembly: true
        )
        return derive(
            events: events,
            window: FailureLedgerWindow(start: from, end: to),
            generatedAt: generatedAt,
            expectedWiring: expectedWiring,
            truncated: events.count >= limit
        )
    }

    // MARK: Wiring smoke (e6e5275 antidote)

    /// Given the promised audit actions of flag-ON modules, flag every action
    /// that emitted 0 rows in the window as DORMANT. Findings are sorted by
    /// module; a module appears iff it has at least one dormant action.
    public static func wiringSmoke(
        events: [AuditEvent],
        expected: [FailureLedgerExpectedModule]
    ) -> [FailureLedgerDormantFinding] {
        let seen = Set(events.map(\.action))
        return expected.compactMap { module -> FailureLedgerDormantFinding? in
            let dormant = module.expectedActions.filter { !seen.contains($0) }
            guard !dormant.isEmpty else { return nil }
            return FailureLedgerDormantFinding(module: module.module, dormantActions: dormant)
        }
        .sorted { $0.module < $1.module }
    }

    // MARK: Internals

    private struct EpisodeAccumulator {
        var episodes = 0
        var succeeded = 0
        var terminated = 0
        var refusedOrStopped = 0
        var stepsAttempted = 0
        var noEffectCount = 0
        var transportRetries = 0
        var escalations = 0
        var durationsMs: [Int] = []
        var costUSD: Double = 0
    }

    private struct RawAccumulator {
        var groundingSourceCounts: [String: Int] = [:]
        var verifierAccepted = 0
        var verifierRejected = 0
        var verifierAbstained = 0
        var escalations = 0
        var transportFailures = 0
        var failureKindCounts: [String: Int] = [:]
    }

    private static func rawSurface(forAction action: String) -> String {
        if action.hasPrefix("sandbox.") { return "backgroundWeb" }
        if action.hasPrefix("recipe.") { return "recipeReplay" }
        return "assist"
    }

    /// Tolerant `source=` extraction over the whole detail. The persisted
    /// format is the sanitized descriptor's trailing safe-token
    /// ("groundHash=… groundChars=… source=accessibility" from
    /// `CascadeAppModel.groundAuditDetail`; "status=hit … source=dom" from
    /// `BackgroundWebAgent.sandboxGroundAuditDescriptor`). An unrecognized or
    /// missing token — including every row persisted before the emitters
    /// carried the token — counts under `unknown` rather than being dropped:
    /// degrade to MISSED, never FALSE.
    private static func groundingSourceKey(in detail: String) -> String {
        guard let range = detail.range(of: "source=") else {
            return GroundingSource.unknown.rawValue
        }
        let token = String(detail[range.upperBound...].prefix { $0.isLetter })
        guard let source = GroundingSource(rawValue: token) else {
            return GroundingSource.unknown.rawValue
        }
        return source.rawValue
    }

    /// Duplicated locally (~6 lines) from `AgentTraceBuilder`'s private
    /// `auditValue(_:in:)` (AgentTrace.swift:1730) — do NOT widen that access.
    /// Acceptable drift risk for one tiny helper; both follow the shared
    /// whitespace-separated `key=value` audit token grammar.
    private static func auditValue(_ key: String, in detail: String) -> String? {
        let prefix = "\(key)="
        return detail
            .split(separator: " ")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).lowercased() }
    }

    /// Nearest-rank percentile; 0 for an empty sample.
    private static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}
