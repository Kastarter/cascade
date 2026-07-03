import AppKit
import CascadeMemory
import ComputerUseKit
import CoreGraphics
import Foundation

// d22 (stretch): thin MacAgentBench adapter STUB. MacAgentBench scores agents at
// CHECKPOINT level — each task decomposes into observable milestones, and an
// external harness verifies each one against the machine's final/intermediate
// state instead of a single pass/fail. This file gives Cascade the scoring half
// of that contract using machinery that already exists: checkpoints are AX-state
// predicates evaluated through `AXElementResolver` with the same frontmost
// discipline and identity rules as the d19 eval. The external harness (or a
// human) drives Cascade on the task's instruction, then calls
// `grounding-bench mab-score` to grade the checkpoints.
//
// Deliberately minimal — a schema-versioned local task format + a pure scorer +
// a live probe. What it is NOT yet (remaining wiring, documented in
// docs/research/AX_FIRST_GROUNDING_PLAN.md "d22"):
//   1. the official MacAgentBench task/checkpoint JSON — map the released schema
//      into `MacAgentBenchTask` when pinned (decoder is schema-versioned for it);
//   2. a driver that launches a Cascade run per instruction with setup/reset
//      between tasks (executeCU loop invocation);
//   3. the submission/result format the external leaderboard expects.
//
// Privacy: instruction/label/expected-value text lives ONLY in the local task
// file (harness input, like the d19/d20 corpus JSONL). Report rows carry bench
// ids, status tokens, counts, and `ax:<hash>` stable ids — never raw AX text.

// MARK: - Task + checkpoint schema (v1, local stub format)

public enum MacAgentBenchCheckpointKind: String, Codable, Equatable, Sendable {
    /// The task's app (or the checkpoint's override) is frontmost.
    case frontmostApp = "frontmost_app"
    /// An AX element matching the descriptor exists in the frontmost app.
    case elementExists = "element_exists"
    /// The matched element's AXValue equals `expectedValue`.
    case elementValue = "element_value"
}

public struct MacAgentBenchCheckpoint: Codable, Equatable, Sendable {
    public let checkpointID: String
    public let kind: MacAgentBenchCheckpointKind
    /// Overrides the task's app for this checkpoint (e.g. a save dialog owned by
    /// another process). nil = the task's `appBundle`.
    public let appBundle: String?
    /// Descriptor for the element kinds — same locator tuple `AXElementResolver`
    /// replays (label + role + identifier + container). Local-file only.
    public let label: String?
    public let role: String?
    public let identifier: String?
    public let container: String?
    /// element_value only. Compared locally; the report records match/mismatch,
    /// never the value.
    public let expectedValue: String?

    public init(
        checkpointID: String,
        kind: MacAgentBenchCheckpointKind,
        appBundle: String? = nil,
        label: String? = nil,
        role: String? = nil,
        identifier: String? = nil,
        container: String? = nil,
        expectedValue: String? = nil
    ) {
        self.checkpointID = checkpointID
        self.kind = kind
        self.appBundle = appBundle
        self.label = label
        self.role = role
        self.identifier = identifier
        self.container = container
        self.expectedValue = expectedValue
    }

    private enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case kind
        case appBundle = "app_bundle"
        case label
        case role
        case identifier
        case container
        case expectedValue = "expected_value"
    }
}

public struct MacAgentBenchTask: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let taskID: String
    /// The natural-language task the DRIVER hands to Cascade. The adapter never
    /// executes it — scoring is read-only.
    public let instruction: String
    public let appBundle: String
    public let checkpoints: [MacAgentBenchCheckpoint]

    public init(
        schemaVersion: Int = MacAgentBenchTask.currentSchemaVersion,
        taskID: String,
        instruction: String,
        appBundle: String,
        checkpoints: [MacAgentBenchCheckpoint]
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.instruction = instruction
        self.appBundle = appBundle
        self.checkpoints = checkpoints
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case instruction
        case appBundle = "app_bundle"
        case checkpoints
    }
}

public enum MacAgentBenchTaskFileError: Error, Equatable, CustomStringConvertible {
    case undecodable
    case emptyTasks
    case unknownTaskID(String)

    public var description: String {
        switch self {
        case .undecodable:
            return "Task file is neither a JSON array of tasks nor {\"tasks\": [...]}. See MacAgentBenchTask (schema v1)."
        case .emptyTasks:
            return "Task file contains no tasks."
        case .unknownTaskID(let id):
            return "No task with task_id \(id) in the task file."
        }
    }
}

public enum MacAgentBenchTaskFile {
    private struct Wrapper: Codable {
        let tasks: [MacAgentBenchTask]
    }

    /// Accepts a bare JSON array of tasks or `{"tasks": [...]}` — tolerant to
    /// the exact top-level shape the external bench ships.
    public static func load(from url: URL) throws -> [MacAgentBenchTask] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let tasks: [MacAgentBenchTask]
        if let bare = try? decoder.decode([MacAgentBenchTask].self, from: data) {
            tasks = bare
        } else if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            tasks = wrapped.tasks
        } else {
            throw MacAgentBenchTaskFileError.undecodable
        }
        guard !tasks.isEmpty else { throw MacAgentBenchTaskFileError.emptyTasks }
        return tasks
    }
}

// MARK: - Checkpoint probe (live AX read, injectable for tests)

public enum MacAgentBenchCheckpointStatus: String, Codable, Equatable, Sendable {
    case satisfied
    case unsatisfied
    /// The checkpoint's app is not frontmost — an element predicate would be
    /// meaningless, so the checkpoint is skipped (it still counts against the
    /// task score: an unreachable checkpoint is not a reached one).
    case skippedAppNotFrontmost = "skipped_app_not_frontmost"
}

public struct MacAgentBenchCheckpointProbeResult: Equatable, Sendable {
    public let status: MacAgentBenchCheckpointStatus
    /// `ax:<hash>` stable id of the matched element, when one was resolved.
    public let hitElementID: String?
    /// element_value only: did AXValue equal the expectation (value never leaves
    /// the local comparison).
    public let valueMatched: Bool?

    public init(status: MacAgentBenchCheckpointStatus, hitElementID: String? = nil, valueMatched: Bool? = nil) {
        self.status = status
        self.hitElementID = hitElementID
        self.valueMatched = valueMatched
    }
}

// MARK: - Checkpoint-level scoring (pure; the live probe is the only AX touch)

public struct MacAgentBenchCheckpointObservation: Codable, Equatable, Sendable {
    public let taskID: String
    public let checkpointID: String
    public let kind: MacAgentBenchCheckpointKind
    public let status: MacAgentBenchCheckpointStatus
    public let hitElementID: String?
    public let valueMatched: Bool?
    public let latency: TimeInterval?

    public init(
        taskID: String,
        checkpointID: String,
        kind: MacAgentBenchCheckpointKind,
        status: MacAgentBenchCheckpointStatus,
        hitElementID: String? = nil,
        valueMatched: Bool? = nil,
        latency: TimeInterval? = nil
    ) {
        self.taskID = taskID
        self.checkpointID = checkpointID
        self.kind = kind
        self.status = status
        self.hitElementID = hitElementID
        self.valueMatched = valueMatched
        self.latency = latency
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case checkpointID = "checkpoint_id"
        case kind
        case status
        case hitElementID = "hit_element_id"
        case valueMatched = "value_matched"
        case latency
    }
}

public struct MacAgentBenchTaskScore: Codable, Equatable, Sendable {
    public let taskID: String
    public let checkpointCount: Int
    public let satisfied: Int
    public let unsatisfied: Int
    public let skipped: Int
    /// Checkpoint-level score: satisfied / total. Skips count against the task —
    /// an unverifiable checkpoint is not a reached one.
    public let checkpointScore: Double
    /// Task success = every checkpoint satisfied (MacAgentBench full credit).
    public let success: Bool

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case checkpointCount = "checkpoint_count"
        case satisfied
        case unsatisfied
        case skipped
        case checkpointScore = "checkpoint_score"
        case success
    }
}

public struct MacAgentBenchReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Order-independent hash over the scored task ids — identifies the bench
    /// slice without embedding instructions.
    public let benchHash: String
    public let taskCount: Int
    public let checkpointCount: Int
    public let satisfiedCheckpoints: Int
    /// Mean per-task checkpoint score — the checkpoint-level number the external
    /// harness compares.
    public let meanCheckpointScore: Double
    public let taskSuccessCount: Int
    public let taskSuccessRate: Double
    public let taskScores: [MacAgentBenchTaskScore]
    public let observations: [MacAgentBenchCheckpointObservation]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case benchHash = "bench_hash"
        case taskCount = "task_count"
        case checkpointCount = "checkpoint_count"
        case satisfiedCheckpoints = "satisfied_checkpoints"
        case meanCheckpointScore = "mean_checkpoint_score"
        case taskSuccessCount = "task_success_count"
        case taskSuccessRate = "task_success_rate"
        case taskScores = "task_scores"
        case observations
    }
}

public struct MacAgentBenchScorer: Sendable {
    public typealias Probe = @Sendable (MacAgentBenchTask, MacAgentBenchCheckpoint) -> MacAgentBenchCheckpointProbeResult

    public init() {}

    /// Grade every checkpoint of every task against the CURRENT screen state.
    /// Read-only: the adapter never acts; whoever ran the task (Cascade via the
    /// external driver, or a human baseline) already left the state behind.
    public func run(tasks: [MacAgentBenchTask], probe: Probe = MacAgentBenchScorer.liveProbe) -> MacAgentBenchReport {
        var observations: [MacAgentBenchCheckpointObservation] = []
        for task in tasks {
            for checkpoint in task.checkpoints {
                let started = ContinuousClock.now
                let result = probe(task, checkpoint)
                let latency = started.duration(to: .now).asTimeInterval
                observations.append(
                    MacAgentBenchCheckpointObservation(
                        taskID: task.taskID,
                        checkpointID: checkpoint.checkpointID,
                        kind: checkpoint.kind,
                        status: result.status,
                        hitElementID: result.hitElementID,
                        valueMatched: result.valueMatched,
                        latency: latency
                    )
                )
            }
        }
        return Self.report(tasks: tasks, observations: observations)
    }

    /// The live probe: same frontmost discipline + resolver as the d19 eval.
    /// `AXElementResolver.find` replays the checkpoint's locator tuple against
    /// the frontmost app; element checkpoints of a non-frontmost app are skipped,
    /// never guessed.
    public static let liveProbe: Probe = { task, checkpoint in
        let expectedBundle = checkpoint.appBundle ?? task.appBundle
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch checkpoint.kind {
        case .frontmostApp:
            return MacAgentBenchCheckpointProbeResult(status: frontmost == expectedBundle ? .satisfied : .unsatisfied)
        case .elementExists, .elementValue:
            guard frontmost == expectedBundle else {
                return MacAgentBenchCheckpointProbeResult(status: .skippedAppNotFrontmost)
            }
            guard let label = checkpoint.label ?? checkpoint.identifier else {
                return MacAgentBenchCheckpointProbeResult(status: .unsatisfied)
            }
            let descriptor = AXElementResolver.Descriptor(
                label: label,
                role: checkpoint.role,
                identifier: checkpoint.identifier,
                container: checkpoint.container
            )
            guard let match = AXElementResolver.find(descriptor: descriptor) else {
                return MacAgentBenchCheckpointProbeResult(status: .unsatisfied)
            }
            if checkpoint.kind == .elementExists {
                return MacAgentBenchCheckpointProbeResult(status: .satisfied, hitElementID: match.id)
            }
            let matched = valueMatches(expected: checkpoint.expectedValue, actual: match.actionableNode?.value)
            return MacAgentBenchCheckpointProbeResult(
                status: matched ? .satisfied : .unsatisfied,
                hitElementID: match.id,
                valueMatched: matched
            )
        }
    }

    /// Whitespace-trimmed equality; the raw strings never leave this comparison.
    public static func valueMatches(expected: String?, actual: String?) -> Bool {
        guard let expected, let actual else { return false }
        return expected.trimmingCharacters(in: .whitespacesAndNewlines)
            == actual.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func report(
        tasks: [MacAgentBenchTask],
        observations: [MacAgentBenchCheckpointObservation]
    ) -> MacAgentBenchReport {
        let byTask = Dictionary(grouping: observations, by: \.taskID)
        let taskScores = tasks.map { task -> MacAgentBenchTaskScore in
            let rows = byTask[task.taskID] ?? []
            let satisfied = rows.filter { $0.status == .satisfied }.count
            let unsatisfied = rows.filter { $0.status == .unsatisfied }.count
            let skipped = rows.filter { $0.status == .skippedAppNotFrontmost }.count
            let total = task.checkpoints.count
            return MacAgentBenchTaskScore(
                taskID: task.taskID,
                checkpointCount: total,
                satisfied: satisfied,
                unsatisfied: unsatisfied,
                skipped: skipped,
                checkpointScore: total == 0 ? 0 : Double(satisfied) / Double(total),
                success: total > 0 && satisfied == total
            )
        }
        let checkpointCount = taskScores.reduce(0) { $0 + $1.checkpointCount }
        let satisfiedCheckpoints = taskScores.reduce(0) { $0 + $1.satisfied }
        let successCount = taskScores.filter(\.success).count
        return MacAgentBenchReport(
            schemaVersion: MacAgentBenchReport.currentSchemaVersion,
            benchHash: benchHash(of: tasks),
            taskCount: tasks.count,
            checkpointCount: checkpointCount,
            satisfiedCheckpoints: satisfiedCheckpoints,
            meanCheckpointScore: taskScores.isEmpty
                ? 0
                : taskScores.reduce(0) { $0 + $1.checkpointScore } / Double(taskScores.count),
            taskSuccessCount: successCount,
            taskSuccessRate: taskScores.isEmpty ? 0 : Double(successCount) / Double(taskScores.count),
            taskScores: taskScores,
            observations: observations
        )
    }

    /// Order-independent hash over the task ids — ids only, never instructions.
    public static func benchHash(of tasks: [MacAgentBenchTask]) -> String {
        AuditIdentity.hash(tasks.map(\.taskID).sorted().joined(separator: "|"))
    }
}

private extension Duration {
    var asTimeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
