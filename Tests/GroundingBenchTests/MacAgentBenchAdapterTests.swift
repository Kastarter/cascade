import Foundation
import GroundingBench
import Testing

// d22: the adapter's decode + checkpoint-level scoring math are pure — pinned
// here so the live run only has to prove the AX predicates, not the plumbing.
struct MacAgentBenchAdapterTests {
    @Test
    func loadsBareArrayAndWrappedTaskFiles() throws {
        let bare = """
        [{"schema_version":1,"task_id":"notes-new","instruction":"Create a new note","app_bundle":"com.apple.Notes","checkpoints":[{"checkpoint_id":"cp1","kind":"frontmost_app"}]}]
        """
        let wrapped = """
        {"tasks":[{"schema_version":1,"task_id":"notes-new","instruction":"Create a new note","app_bundle":"com.apple.Notes","checkpoints":[{"checkpoint_id":"cp1","kind":"element_exists","label":"New Note","role":"AXButton"}]}]}
        """
        let bareURL = temporaryFile(contents: bare)
        let wrappedURL = temporaryFile(contents: wrapped)
        defer {
            try? FileManager.default.removeItem(at: bareURL)
            try? FileManager.default.removeItem(at: wrappedURL)
        }

        let bareTasks = try MacAgentBenchTaskFile.load(from: bareURL)
        #expect(bareTasks.count == 1)
        #expect(bareTasks[0].taskID == "notes-new")
        #expect(bareTasks[0].checkpoints[0].kind == .frontmostApp)

        let wrappedTasks = try MacAgentBenchTaskFile.load(from: wrappedURL)
        #expect(wrappedTasks[0].checkpoints[0].kind == .elementExists)
        #expect(wrappedTasks[0].checkpoints[0].label == "New Note")
    }

    @Test
    func rejectsUndecodableAndEmptyTaskFiles() throws {
        let garbage = temporaryFile(contents: "{\"nope\": 1}")
        let empty = temporaryFile(contents: "[]")
        defer {
            try? FileManager.default.removeItem(at: garbage)
            try? FileManager.default.removeItem(at: empty)
        }
        #expect(throws: MacAgentBenchTaskFileError.undecodable) {
            try MacAgentBenchTaskFile.load(from: garbage)
        }
        #expect(throws: MacAgentBenchTaskFileError.emptyTasks) {
            try MacAgentBenchTaskFile.load(from: empty)
        }
    }

    @Test
    func checkpointScoreIsSatisfiedOverTotalAndSuccessNeedsAllCheckpoints() {
        let full = task(
            id: "t-full",
            checkpoints: [checkpoint("a", .frontmostApp), checkpoint("b", .elementExists, label: "New Note")]
        )
        let partial = task(
            id: "t-partial",
            checkpoints: [
                checkpoint("a", .frontmostApp),
                checkpoint("b", .elementExists, label: "Missing"),
                checkpoint("c", .elementExists, label: "Elsewhere"),
            ]
        )
        let report = MacAgentBenchScorer().run(tasks: [full, partial]) { probed, cp in
            if probed.taskID == "t-full" { return .init(status: .satisfied, hitElementID: "ax:hit") }
            switch cp.checkpointID {
            case "a": return .init(status: .satisfied)
            case "b": return .init(status: .unsatisfied)
            default: return .init(status: .skippedAppNotFrontmost)
            }
        }

        #expect(report.taskCount == 2)
        #expect(report.checkpointCount == 5)
        #expect(report.satisfiedCheckpoints == 3)

        let fullScore = report.taskScores.first { $0.taskID == "t-full" }
        #expect(fullScore?.success == true)
        #expect(fullScore?.checkpointScore == 1.0)

        // Skips count against the score — an unverifiable checkpoint is not reached.
        let partialScore = report.taskScores.first { $0.taskID == "t-partial" }
        #expect(partialScore?.success == false)
        #expect(partialScore?.satisfied == 1)
        #expect(partialScore?.unsatisfied == 1)
        #expect(partialScore?.skipped == 1)
        #expect(partialScore.map { abs($0.checkpointScore - 1.0 / 3.0) < 0.0001 } == true)

        #expect(report.taskSuccessCount == 1)
        #expect(abs(report.taskSuccessRate - 0.5) < 0.0001)
        #expect(abs(report.meanCheckpointScore - (1.0 + 1.0 / 3.0) / 2.0) < 0.0001)
    }

    @Test
    func zeroCheckpointTaskNeverSucceeds() {
        let empty = task(id: "t-empty", checkpoints: [])
        let report = MacAgentBenchScorer().run(tasks: [empty]) { _, _ in .init(status: .satisfied) }
        #expect(report.taskScores[0].success == false)
        #expect(report.taskScores[0].checkpointScore == 0)
    }

    @Test
    func valueMatchTrimsWhitespaceAndNeverMatchesNil() {
        #expect(MacAgentBenchScorer.valueMatches(expected: "hello", actual: " hello\n"))
        #expect(!MacAgentBenchScorer.valueMatches(expected: "hello", actual: "world"))
        #expect(!MacAgentBenchScorer.valueMatches(expected: nil, actual: "hello"))
        #expect(!MacAgentBenchScorer.valueMatches(expected: "hello", actual: nil))
    }

    @Test
    func reportCarriesIdsAndTokensNeverInstructionOrLabelText() throws {
        let secretInstruction = "SECRET-open the tax spreadsheet"
        let secretLabel = "SECRET-2025 Tax Return.xlsx"
        let secretValue = "SECRET-SSN 000-00-0000"
        let bench = MacAgentBenchTask(
            taskID: "t-privacy",
            instruction: secretInstruction,
            appBundle: "com.apple.Notes",
            checkpoints: [
                MacAgentBenchCheckpoint(
                    checkpointID: "cp1",
                    kind: .elementValue,
                    label: secretLabel,
                    role: "AXTextField",
                    expectedValue: secretValue
                )
            ]
        )
        let report = MacAgentBenchScorer().run(tasks: [bench]) { _, _ in
            .init(status: .unsatisfied, hitElementID: "ax:abc123", valueMatched: false)
        }
        let json = try report.jsonString()
        #expect(!json.contains(secretInstruction))
        #expect(!json.contains(secretLabel))
        #expect(!json.contains(secretValue))
        #expect(json.contains("ax:abc123"))
        #expect(json.contains("\"value_matched\" : false"))
        #expect(report.benchHash == MacAgentBenchScorer.benchHash(of: [bench]))
        #expect(report.benchHash != "none")
    }

    @Test
    func benchHashIsOrderIndependent() {
        let a = task(id: "alpha", checkpoints: [])
        let b = task(id: "beta", checkpoints: [])
        #expect(MacAgentBenchScorer.benchHash(of: [a, b]) == MacAgentBenchScorer.benchHash(of: [b, a]))
        #expect(MacAgentBenchScorer.benchHash(of: [a]) != MacAgentBenchScorer.benchHash(of: [b]))
    }

    // MARK: - Helpers

    private func task(id: String, checkpoints: [MacAgentBenchCheckpoint]) -> MacAgentBenchTask {
        MacAgentBenchTask(
            taskID: id,
            instruction: "instruction for \(id)",
            appBundle: "com.apple.Notes",
            checkpoints: checkpoints
        )
    }

    private func checkpoint(
        _ id: String,
        _ kind: MacAgentBenchCheckpointKind,
        label: String? = nil
    ) -> MacAgentBenchCheckpoint {
        MacAgentBenchCheckpoint(checkpointID: id, kind: kind, label: label)
    }

    private func temporaryFile(contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mab-tests-\(UUID().uuidString).json")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
