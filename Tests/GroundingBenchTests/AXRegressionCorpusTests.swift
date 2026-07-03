import ComputerUseKit
import CoreGraphics
import Foundation
import GroundingBench
import Testing

struct AXRegressionCorpusTests {
    @Test
    func traceWalksSemanticLadderThenFrameClickFallback() {
        let button = target(id: "ax:btn", label: "New Note", role: "AXButton", actions: ["AXPress", "AXShowMenu"])
        let task = AXRegressionCorpusBuilder.task(from: button)

        #expect(task.kind == "click")
        #expect(task.taskID.hasPrefix("axtask:"))
        #expect(task.trace.count == 3)
        #expect(task.trace[0].verb == .raiseApp)
        #expect(task.trace[0].isFallback == false)
        #expect(task.trace[1].verb == .axAction)
        #expect(task.trace[1].axAction == "AXPress")
        #expect(task.trace[1].targetID == "ax:btn")
        #expect(task.trace[2].verb == .frameClick)
        #expect(task.trace[2].isFallback == true)
        #expect(task.trace[2].pointX == Double(button.center.x))
        #expect(task.trace[2].pointY == Double(button.center.y))
        #expect(task.trace.map(\.order) == [0, 1, 2])
    }

    @Test
    func tracePreferenceMirrorsExecutorLadder() {
        // AXConfirm outranks AXShowMenu when AXPress is missing (d06 order).
        let confirm = target(id: "ax:c", label: "OK", role: "AXCell", actions: ["AXShowMenu", "AXConfirm"])
        #expect(AXRegressionCorpusBuilder.semanticAction(for: confirm) == "AXConfirm")

        // AXShowMenu-only control still gets a semantic step.
        let menu = target(id: "ax:m", label: "More", role: "AXMenuButton", actions: ["AXShowMenu"])
        #expect(AXRegressionCorpusBuilder.semanticAction(for: menu) == "AXShowMenu")

        // Text fields focus semantically (then typing lands).
        let field = target(id: "ax:f", label: "Search", role: "AXTextField", actions: [])
        #expect(AXRegressionCorpusBuilder.semanticAction(for: field) == "AXSetFocused")
        #expect(AXRegressionCorpusBuilder.task(from: field).kind == "type")

        // AXTextArea is the documented exception: coordinate click places the
        // caret, so the frame click is the PRIMARY step, not a fallback.
        let area = target(id: "ax:a", label: "Body", role: "AXTextArea", actions: ["AXPress"])
        #expect(AXRegressionCorpusBuilder.semanticAction(for: area) == nil)
        let areaTrace = AXRegressionCorpusBuilder.trace(for: area)
        #expect(areaTrace.count == 2)
        #expect(areaTrace[1].verb == .frameClick)
        #expect(areaTrace[1].isFallback == false)

        // No semantic action at all -> primary frame click.
        let image = target(id: "ax:i", label: "Thumb", role: "AXImage", actions: [])
        let imageTrace = AXRegressionCorpusBuilder.trace(for: image)
        #expect(imageTrace.count == 2)
        #expect(imageTrace[1].isFallback == false)
    }

    @Test
    func tasksAreDeterministicScreenOrderedDedupedAndCapped() {
        let bottom = target(id: "ax:bottom", label: "Bottom", role: "AXButton", actions: ["AXPress"], y: 300)
        let topLeft = target(id: "ax:tl", label: "Top Left", role: "AXButton", actions: ["AXPress"], x: 10, y: 20)
        let topRight = target(id: "ax:tr", label: "Top Right", role: "AXButton", actions: ["AXPress"], x: 200, y: 20)
        let field = target(id: "ax:field", label: "Search", role: "AXTextField", actions: [], y: 40)

        let tasks = AXRegressionCorpusBuilder.tasks(
            from: [bottom, field, topRight, topLeft, topLeft],
            maxPerKind: 2
        )

        // Screen order, duplicate dropped, click kind capped at 2 (bottom pruned).
        #expect(tasks.map { $0.target.targetID } == ["ax:tl", "ax:tr", "ax:field"])
        #expect(tasks.filter { $0.kind == "click" }.count == 2)

        // Same crawl in -> same corpus out, ids and hash stable across runs.
        let again = AXRegressionCorpusBuilder.tasks(from: [bottom, field, topRight, topLeft, topLeft], maxPerKind: 2)
        #expect(again == tasks)
        #expect(AXRegressionCorpusBuilder.corpusHash(of: again) == AXRegressionCorpusBuilder.corpusHash(of: tasks))
        #expect(AXRegressionCorpusBuilder.corpusHash(of: tasks) != "none")
    }

    @Test
    func tasksRoundTripThroughJSONLWithSupportedActions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXRegressionCorpusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.jsonl")
        let tasks = AXRegressionCorpusBuilder.tasks(from: [
            target(id: "ax:1", label: "New Note", role: "AXButton", actions: ["AXShowMenu", "AXPress"]),
            target(id: "ax:2", label: "Search", role: "AXTextField", actions: [], y: 90),
        ])

        try AXRegressionTaskJSONL.write(tasks, to: url)
        let loaded = try AXRegressionTaskJSONL.load(from: url)

        #expect(loaded == tasks)
        #expect(loaded[0].target.supportedActions == ["AXPress", "AXShowMenu"])
        #expect(loaded[0].instruction.contains("New Note"))
        // d19 eval interop: the embedded targets feed the existing scorer.
        let report = AXGroundingEvalRunner().run(targets: loaded.map(\.target)) { _ in .notExposed }
        #expect(report.totalTargets == 2)
        #expect(report.notExposed == 2)
    }

    @Test
    func generatorWritesFixturesAndManifestAndRecordsMissingApps() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXRegressionCorpusTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps: [AXRegressionCorpusApp] = [.notes, .systemSettings, .safari]
        let notesTargets = [
            target(id: "ax:new", label: "New Note", role: "AXButton", actions: ["AXPress"], bundle: "com.apple.Notes", appName: "Notes"),
            target(id: "ax:search", label: "Search", role: "AXSearchField", actions: [], bundle: "com.apple.Notes", appName: "Notes", y: 80),
        ]

        let manifest = try AXRegressionCorpusGenerator.generate(
            apps: apps,
            outDirectory: directory,
            generatedAt: Date(timeIntervalSince1970: 0)
        ) { app in
            switch app.bundleID {
            case "com.apple.Notes":
                return AXGroundingCrawl(targets: notesTargets, appBundle: app.bundleID, appName: app.displayName, visitedNodeCount: 12)
            case "com.apple.Safari":
                throw AXGroundingCrawlError.appNotRunning(app.bundleID)
            default:
                return AXGroundingCrawl(targets: [], appBundle: app.bundleID, appName: app.displayName, visitedNodeCount: 3)
            }
        }

        #expect(manifest.apps.count == 3)
        #expect(manifest.totalTaskCount == 2)
        let notes = manifest.apps.first { $0.bundleID == "com.apple.Notes" }
        #expect(notes?.status == .crawled)
        #expect(notes?.taskCount == 2)
        #expect(notes?.kindCounts == ["click": 1, "type": 1])
        #expect(notes?.visitedNodeCount == 12)
        #expect(notes?.file == "com.apple.Notes.tasks.jsonl")
        let safari = manifest.apps.first { $0.bundleID == "com.apple.Safari" }
        #expect(safari?.status == .appNotRunning)
        #expect(safari?.taskCount == 0)
        #expect(safari?.file == nil)
        #expect(safari?.corpusHash == "none")
        let settings = manifest.apps.first { $0.bundleID == "com.apple.systempreferences" }
        #expect(settings?.status == .crawled)
        #expect(settings?.taskCount == 0)

        // Fixture files: written for crawled apps, absent for missing ones.
        let notesTasks = try AXRegressionTaskJSONL.load(from: directory.appendingPathComponent("com.apple.Notes.tasks.jsonl"))
        #expect(notesTasks.count == 2)
        #expect(notes?.corpusHash == AXRegressionCorpusBuilder.corpusHash(of: notesTasks))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.apple.Safari.tasks.jsonl").path))

        // Manifest on disk decodes back to the returned value (hashes/counts only).
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let decoded = try JSONDecoder().decode(AXRegressionCorpusManifest.self, from: manifestData)
        #expect(decoded == manifest)
        let manifestText = String(decoding: manifestData, as: UTF8.self)
        #expect(!manifestText.contains("New Note"))
        #expect(!manifestText.contains("instruction"))
    }

    @Test
    func accessibilityUnavailableIsFatalNotRecorded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXRegressionCorpusTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: AXGroundingCrawlError.accessibilityUnavailable) {
            try AXRegressionCorpusGenerator.generate(
                apps: [.notes],
                outDirectory: directory
            ) { _ in
                throw AXGroundingCrawlError.accessibilityUnavailable
            }
        }
    }

    @Test
    func v1TargetRowsWithoutSupportedActionsStillDecode() throws {
        let v1Row = """
        {"schema_version":1,"target_id":"ax:old","app_bundle":"com.apple.Notes","app_name":"Notes","label":"New Note","role":"AXButton","frame_x":10,"frame_y":20,"frame_width":40,"frame_height":20}
        """
        let decoded = try JSONDecoder().decode(AXGroundingTarget.self, from: Data(v1Row.utf8))
        #expect(decoded.supportedActions == nil)
        // A v1 row still builds a task — the trace degrades to a primary frame click.
        let trace = AXRegressionCorpusBuilder.trace(for: decoded)
        #expect(trace.count == 2)
        #expect(trace[1].verb == .frameClick)
        #expect(trace[1].isFallback == false)
    }

    private func target(
        id: String,
        label: String,
        role: String,
        actions: [String],
        identifier: String? = nil,
        bundle: String? = "app.one",
        appName: String = "One",
        x: Double = 100,
        y: Double = 40
    ) -> AXGroundingTarget {
        AXGroundingTarget(
            targetID: id,
            appBundle: bundle,
            appName: appName,
            label: label,
            role: role,
            identifier: identifier,
            supportedActions: actions.isEmpty ? nil : actions,
            frame: CGRect(x: x, y: y, width: 60, height: 40)
        )
    }
}
