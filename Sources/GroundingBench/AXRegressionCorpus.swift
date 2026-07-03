import AppKit
import CascadeMemory
import ComputerUseKit
import CoreGraphics
import Foundation

// d20: the regression corpus generator. d19 proved the live AX crawl is the
// ground truth that recorded (privacy-hashed) frames can't be; this turns that
// crawl into a durable, replayable REGRESSION corpus (macapptree-style: crawl
// the app's AX surface, keep the grounded material) for the canonical target
// apps — Notes, System Settings, Safari (Keynote via --apps when running).
// Each crawled control becomes:
//   1. a grounded TASK — a deterministic instruction over a real control the
//      crawl proved exists (never an invented description), and
//   2. a SEMANTIC ACTION TRACE — the exact d06 execution ladder the executor
//      should walk for that control (raise the app → semantic AX action such
//      as AXPress/AXSetFocused → exact-frame click as last-resort fallback).
// The corpus is what the d21 ablation replays: fixture JSONL per app + a
// counts/hashes manifest. Labels/instructions live ONLY in the local fixture
// files (harness input, same posture as the d19 target corpus); the manifest
// and every printed/audited row carry hashes, role/kind tokens, counts, and
// numeric coordinates — never raw label text. Everything here rides the
// existing `cascade.experimentalGroundingBench` flag via the CLI gate.

// MARK: - Semantic action trace

/// One step of the expected semantic execution ladder for a grounded task.
/// The trace asserts the d06 preference order (semantic AX action first,
/// exact AX-frame click only as fallback) so a regression run can diff the
/// path the executor ACTUALLY took against the path the corpus recorded.
public struct AXRegressionTraceStep: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Equatable, Sendable {
        /// Focus discipline (d08): raise the target app before acting.
        case raiseApp = "raise_app"
        /// Semantic AX action on the target node (`axAction` says which).
        case axAction = "ax_action"
        /// Coordinate click on the exact crawled frame center — the last
        /// resort of the d06 ladder, or the primary step when no semantic
        /// action applies (e.g. AXTextArea caret placement).
        case frameClick = "frame_click"
    }

    public let order: Int
    public let verb: Verb
    /// Semantic action name for `.axAction` steps (AXPress/AXConfirm/AXPick/
    /// AXShowMenu/AXSetFocused — mirrors the executor's ladder), nil otherwise.
    public let axAction: String?
    /// Stable AX node id (`ax:<hash>`) the step acts on; nil for `raiseApp`.
    public let targetID: String?
    /// Click point for `.frameClick` steps — numeric coordinates only.
    public let pointX: Double?
    public let pointY: Double?
    /// true = run only if the previous step failed (the d06 fallback rung).
    public let isFallback: Bool

    public init(
        order: Int,
        verb: Verb,
        axAction: String? = nil,
        targetID: String? = nil,
        pointX: Double? = nil,
        pointY: Double? = nil,
        isFallback: Bool = false
    ) {
        self.order = order
        self.verb = verb
        self.axAction = axAction
        self.targetID = targetID
        self.pointX = pointX
        self.pointY = pointY
        self.isFallback = isFallback
    }

    private enum CodingKeys: String, CodingKey {
        case order
        case verb
        case axAction = "ax_action"
        case targetID = "target_id"
        case pointX = "point_x"
        case pointY = "point_y"
        case isFallback = "is_fallback"
    }
}

// MARK: - Grounded task

/// A grounded regression task: an instruction over a control the crawl proved
/// exists, plus the crawled target itself (so the d19 eval can rescore it
/// later) and the expected semantic action trace. Fixture-only material —
/// the instruction/label never leaves the local corpus files.
public struct AXRegressionTask: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Deterministic id: `axtask:<hash(appKey|targetID|kind)>` — stable across
    /// regenerations of the same surface so corpus diffs are meaningful.
    public let taskID: String
    /// Interaction kind — `AXCompressedObservation.Modality` raw value
    /// (click/type/toggle/select/adjust/disclose).
    public let kind: String
    /// Deterministic natural-language instruction (fixture-local, like the
    /// d19 target label).
    public let instruction: String
    public let target: AXGroundingTarget
    public let trace: [AXRegressionTraceStep]

    public init(
        schemaVersion: Int = AXRegressionTask.currentSchemaVersion,
        taskID: String,
        kind: String,
        instruction: String,
        target: AXGroundingTarget,
        trace: [AXRegressionTraceStep]
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.kind = kind
        self.instruction = instruction
        self.target = target
        self.trace = trace
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case kind
        case instruction
        case target
        case trace
    }
}

public enum AXRegressionTaskJSONL {
    public static func load(from url: URL) throws -> [AXRegressionTask] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(AXRegressionTask.self, from: Data($0.utf8)) }
    }

    public static func write(_ tasks: [AXRegressionTask], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try tasks
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        try body.appending(tasks.isEmpty ? "" : "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Builder (pure: crawl targets -> tasks + traces)

public enum AXRegressionCorpusBuilder {
    /// Per-kind cap so one dense toolbar can't flood the corpus — this is a
    /// SMALL regression set, not an exhaustive dump.
    public static let defaultMaxTasksPerKind = 8

    /// The executor's semantic activation preference (d06 `axSemanticActivate`
    /// ladder) — the trace asserts the same order the real path walks.
    public static let semanticActivationPreference = ["AXPress", "AXConfirm", "AXPick"]
    static let showMenuAction = "AXShowMenu"
    /// Text roles get `AXSetFocused` (focus, then type); AXTextArea is the
    /// documented d06 exception — a coordinate click places the caret.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    public static func kind(for target: AXGroundingTarget) -> AXCompressedObservation.Modality {
        AXCompressedObservation.modality(role: target.role, supportedActions: target.supportedActions ?? [])
    }

    /// The semantic AX action the d06 ladder would try first for this target,
    /// nil when only a coordinate click applies.
    public static func semanticAction(for target: AXGroundingTarget) -> String? {
        if textRoles.contains(target.role) {
            return target.role == "AXTextArea" ? nil : "AXSetFocused"
        }
        let actions = target.supportedActions ?? []
        if let preferred = semanticActivationPreference.first(where: actions.contains) {
            return preferred
        }
        if actions.contains(showMenuAction) {
            return showMenuAction
        }
        return nil
    }

    public static func trace(for target: AXGroundingTarget) -> [AXRegressionTraceStep] {
        var steps: [AXRegressionTraceStep] = [
            AXRegressionTraceStep(order: 0, verb: .raiseApp)
        ]
        let semantic = semanticAction(for: target)
        if let semantic {
            steps.append(AXRegressionTraceStep(
                order: 1,
                verb: .axAction,
                axAction: semantic,
                targetID: target.targetID
            ))
        }
        steps.append(AXRegressionTraceStep(
            order: steps.count,
            verb: .frameClick,
            targetID: target.targetID,
            pointX: target.center.x,
            pointY: target.center.y,
            isFallback: semantic != nil
        ))
        return steps
    }

    /// Deterministic instruction per interaction kind. Fixture-local text.
    public static func instruction(
        for target: AXGroundingTarget,
        kind: AXCompressedObservation.Modality
    ) -> String {
        let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = target.appName
        switch kind {
        case .click: return "Click “\(label)” in \(app)."
        case .type: return "Type into the “\(label)” field in \(app)."
        case .toggle: return "Toggle “\(label)” in \(app)."
        case .select: return "Select “\(label)” in \(app)."
        case .adjust: return "Adjust “\(label)” in \(app)."
        case .disclose: return "Expand “\(label)” in \(app)."
        }
    }

    public static func taskID(for target: AXGroundingTarget, kind: AXCompressedObservation.Modality) -> String {
        "axtask:" + AuditIdentity.hash([target.appKey, target.targetID, kind.rawValue].joined(separator: "|"))
    }

    public static func task(from target: AXGroundingTarget) -> AXRegressionTask {
        let taskKind = kind(for: target)
        return AXRegressionTask(
            taskID: taskID(for: target, kind: taskKind),
            kind: taskKind.rawValue,
            instruction: instruction(for: target, kind: taskKind),
            target: target,
            trace: trace(for: target)
        )
    }

    /// Deterministic corpus from a crawl: screen order (top-to-bottom, then
    /// left-to-right), de-duplicated by task id, capped per kind so the corpus
    /// stays small. Same crawl in -> same corpus out.
    public static func tasks(
        from targets: [AXGroundingTarget],
        maxPerKind: Int = AXRegressionCorpusBuilder.defaultMaxTasksPerKind
    ) -> [AXRegressionTask] {
        let ordered = targets.sorted { lhs, rhs in
            if lhs.frameY != rhs.frameY { return lhs.frameY < rhs.frameY }
            if lhs.frameX != rhs.frameX { return lhs.frameX < rhs.frameX }
            return lhs.targetID < rhs.targetID
        }
        var seen = Set<String>()
        var perKind: [String: Int] = [:]
        var built: [AXRegressionTask] = []
        for target in ordered {
            let candidate = task(from: target)
            guard seen.insert(candidate.taskID).inserted else { continue }
            let count = perKind[candidate.kind, default: 0]
            guard count < max(0, maxPerKind) else { continue }
            perKind[candidate.kind] = count + 1
            built.append(candidate)
        }
        return built
    }

    /// Stable content hash over the task ids (order-independent) — the
    /// regression signal a later run diffs against. Hashes only, never text.
    public static func corpusHash(of tasks: [AXRegressionTask]) -> String {
        AuditIdentity.hash(tasks.map(\.taskID).sorted().joined(separator: "|"))
    }
}

// MARK: - Corpus manifest (hashes/counts only — safe to share)

public enum AXRegressionCorpusAppStatus: String, Codable, Equatable, Sendable {
    case crawled
    case appNotRunning = "app_not_running"
    case frontmostMismatch = "frontmost_mismatch"
    case sensitiveRefused = "sensitive_refused"
}

public struct AXRegressionCorpusAppEntry: Codable, Equatable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let status: AXRegressionCorpusAppStatus
    public let taskCount: Int
    /// Tasks per interaction kind (modality raw value -> count).
    public let kindCounts: [String: Int]
    public let visitedNodeCount: Int
    /// Order-independent hash of the app's task ids ("none" when empty).
    public let corpusHash: String
    /// Fixture file name inside the corpus directory, nil when nothing was written.
    public let file: String?

    public init(
        bundleID: String,
        displayName: String,
        status: AXRegressionCorpusAppStatus,
        taskCount: Int,
        kindCounts: [String: Int],
        visitedNodeCount: Int,
        corpusHash: String,
        file: String?
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.status = status
        self.taskCount = taskCount
        self.kindCounts = kindCounts
        self.visitedNodeCount = visitedNodeCount
        self.corpusHash = corpusHash
        self.file = file
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case displayName = "display_name"
        case status
        case taskCount = "task_count"
        case kindCounts = "kind_counts"
        case visitedNodeCount = "visited_node_count"
        case corpusHash = "corpus_hash"
        case file
    }
}

public struct AXRegressionCorpusManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: String
    public let apps: [AXRegressionCorpusAppEntry]
    public let totalTaskCount: Int
    /// Hash over the per-app corpus hashes — one value to diff between runs.
    public let corpusHash: String

    public init(
        schemaVersion: Int = AXRegressionCorpusManifest.currentSchemaVersion,
        generatedAt: String,
        apps: [AXRegressionCorpusAppEntry],
        totalTaskCount: Int,
        corpusHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.apps = apps
        self.totalTaskCount = totalTaskCount
        self.corpusHash = corpusHash
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case apps
        case totalTaskCount = "total_task_count"
        case corpusHash = "corpus_hash"
    }
}

// MARK: - Generator (multi-app crawl -> fixture files + manifest)

public struct AXRegressionCorpusApp: Equatable, Sendable {
    public let bundleID: String
    public let displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }

    /// Canonical d20 target apps. Keynote (in the plan's app list) is opt-in
    /// via `--apps` because it is rarely running on a dev box; the generator
    /// records not-running apps instead of failing the whole run.
    public static let notes = AXRegressionCorpusApp(bundleID: "com.apple.Notes", displayName: "Notes")
    public static let systemSettings = AXRegressionCorpusApp(bundleID: "com.apple.systempreferences", displayName: "System Settings")
    public static let safari = AXRegressionCorpusApp(bundleID: "com.apple.Safari", displayName: "Safari")
    public static let keynote = AXRegressionCorpusApp(bundleID: "com.apple.iWork.Keynote", displayName: "Keynote")

    public static let known: [AXRegressionCorpusApp] = [.notes, .systemSettings, .safari, .keynote]

    public static func named(bundleID: String) -> AXRegressionCorpusApp {
        known.first { $0.bundleID == bundleID } ?? AXRegressionCorpusApp(bundleID: bundleID, displayName: bundleID)
    }
}

public enum AXRegressionCorpusGenerator {
    public static let defaultApps: [AXRegressionCorpusApp] = [.notes, .systemSettings, .safari]

    public typealias Crawl = (AXRegressionCorpusApp) throws -> AXGroundingCrawl

    /// The live crawl: activate the already-running app (never launches
    /// software), then run the same bounded actionable harvest the grounder
    /// itself uses (d19 `AXGroundingCrawler`).
    public static func liveCrawl(limit: Int, settleSeconds: TimeInterval = 1.0) -> Crawl {
        { app in
            try AXGroundingCrawler.activate(bundleIdentifier: app.bundleID, settleSeconds: settleSeconds)
            return try AXGroundingCrawler.crawlFrontmost(limit: limit)
        }
    }

    /// Crawls each requested app into `<safe-bundle>.tasks.jsonl` under
    /// `outDirectory` and writes `manifest.json` (hashes/counts only) beside
    /// them. Per-app failures (not running, frontmost stolen, sensitive) are
    /// RECORDED, not fatal — a missing app must not kill the corpus for the
    /// others. Accessibility being unavailable is fatal (nothing can crawl).
    @discardableResult
    public static func generate(
        apps: [AXRegressionCorpusApp] = defaultApps,
        outDirectory: URL,
        maxPerKind: Int = AXRegressionCorpusBuilder.defaultMaxTasksPerKind,
        generatedAt: Date = Date(),
        crawl: Crawl
    ) throws -> AXRegressionCorpusManifest {
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        var entries: [AXRegressionCorpusAppEntry] = []
        for app in apps {
            do {
                let crawled = try crawl(app)
                let tasks = AXRegressionCorpusBuilder.tasks(from: crawled.targets, maxPerKind: maxPerKind)
                let fileName = AuditIdentity.safeToken(app.bundleID) + ".tasks.jsonl"
                try AXRegressionTaskJSONL.write(tasks, to: outDirectory.appendingPathComponent(fileName))
                var kindCounts: [String: Int] = [:]
                for task in tasks {
                    kindCounts[task.kind, default: 0] += 1
                }
                entries.append(AXRegressionCorpusAppEntry(
                    bundleID: app.bundleID,
                    displayName: app.displayName,
                    status: .crawled,
                    taskCount: tasks.count,
                    kindCounts: kindCounts,
                    visitedNodeCount: crawled.visitedNodeCount,
                    corpusHash: AXRegressionCorpusBuilder.corpusHash(of: tasks),
                    file: fileName
                ))
            } catch let error as AXGroundingCrawlError {
                let status: AXRegressionCorpusAppStatus
                switch error {
                case .appNotRunning:
                    status = .appNotRunning
                case .frontmostMismatch:
                    status = .frontmostMismatch
                case .sensitiveAppRefused:
                    status = .sensitiveRefused
                case .accessibilityUnavailable, .noFrontmostApplication:
                    throw error
                }
                entries.append(AXRegressionCorpusAppEntry(
                    bundleID: app.bundleID,
                    displayName: app.displayName,
                    status: status,
                    taskCount: 0,
                    kindCounts: [:],
                    visitedNodeCount: 0,
                    corpusHash: "none",
                    file: nil
                ))
            }
        }
        let manifest = AXRegressionCorpusManifest(
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            apps: entries,
            totalTaskCount: entries.reduce(0) { $0 + $1.taskCount },
            corpusHash: AuditIdentity.hash(entries.map(\.corpusHash).joined(separator: "|"))
        )
        try manifest.jsonString().appending("\n")
            .write(to: outDirectory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return manifest
    }
}
