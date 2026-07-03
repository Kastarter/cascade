import ComputerUseKit
import Foundation
import GroundingBench
import ProviderKit
import Darwin

@main
struct GroundingBenchCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, command != "help", command != "--help", command != "-h" else {
                print(Self.usage)
                return
            }
            guard GroundingBenchFlags.isEnabled() else {
                throw CLIError.flagDisabled
            }
            let options = ArgumentParser(Array(arguments.dropFirst()))
            switch command {
            case "export":
                try export(options)
            case "fixture":
                try fixture(options)
            case "run":
                try await run(options)
            case "ax-crawl":
                try axCrawl(options)
            case "ax-corpus":
                try axCorpus(options)
            case "ax-eval":
                try axEval(options)
            case "ax-ablation":
                try await axAblation(options)
            case "mab-score":
                try mabScore(options)
            default:
                throw CLIError.usage("Unknown command: \(command)\n\n\(Self.usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func export(_ options: ArgumentParser) throws {
        let db = try options.requiredURL("--db")
        let out = try options.requiredURL("--out")
        let sidecar = try GroundingAuditExporter.loadTargetSidecar(from: options.optionalURL("--target-sidecar"))
        let frameRoot = options.optionalURL("--frame-root")
        let exporter = GroundingAuditExporter()
        let rows = try exporter.export(
            databasePath: db,
            outputURL: out,
            options: GroundingAuditExporter.Options(frameRoot: frameRoot, targetTextByHash: sidecar)
        )
        print("exported \(rows.count) cases to \(out.path)")
    }

    private static func fixture(_ options: ArgumentParser) throws {
        let outDir = try options.requiredURL("--out-dir")
        let jsonl = options.optionalURL("--jsonl") ?? outDir.appendingPathComponent("grounding-fixture.jsonl")
        let rows = try GroundingBenchFixtures.generate(into: outDir, jsonlURL: jsonl)
        print("wrote \(rows.count) fixture cases to \(jsonl.path)")
    }

    private static func run(_ options: ArgumentParser) async throws {
        let jsonl = try options.requiredURL("--jsonl")
        let apiKeyEnv = options.value("--api-key-env") ?? "OPENROUTER_API_KEY"
        let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv]
        guard let grounder = GrounderRegistry.makeGrounder(
            presetID: options.value("--preset"),
            apiKey: apiKey,
            endpointOverride: options.value("--endpoint"),
            modelOverride: options.value("--model"),
            coordSpaceOverride: options.value("--coord-space")
        ) else {
            throw CLIError.usage("Unable to construct grounder. Check --preset, --endpoint, --model, --coord-space, and --api-key-env.")
        }
        let report = try await GroundingBenchmarkRunner().run(jsonlURL: jsonl, grounder: grounder)
        print(try report.jsonString())
    }

    /// d19: crawl the live AX tree of the app under test into an eval corpus.
    /// Ground truth comes from the crawl itself (label/role/identifier/frame), so
    /// no privacy-hashed recorded frame is involved. `--app` activates an
    /// already-running app first; otherwise the current frontmost app is crawled.
    private static func axCrawl(_ options: ArgumentParser) throws {
        let out = try options.requiredURL("--out")
        if let bundleID = options.value("--app") {
            try AXGroundingCrawler.activate(bundleIdentifier: bundleID)
        }
        let limit = options.value("--limit").flatMap(Int.init) ?? 40
        let crawl = try AXGroundingCrawler.crawlFrontmost(limit: limit)
        try AXGroundingTargetJSONL.write(crawl.targets, to: out)
        print("crawled \(crawl.targets.count) targets from \(crawl.appBundle ?? crawl.appName) (visited \(crawl.visitedNodeCount) nodes) to \(out.path)")
    }

    /// d20: crawl the canonical target apps (Notes, System Settings, Safari by
    /// default; --apps adds e.g. Keynote) into a regression corpus: per-app
    /// grounded-task fixtures (`<bundle>.tasks.jsonl` — instruction + target +
    /// semantic action trace) plus a counts/hashes-only manifest.json. Apps that
    /// aren't running are recorded in the manifest, not fatal.
    private static func axCorpus(_ options: ArgumentParser) throws {
        let outDir = try options.requiredURL("--out-dir")
        let limit = options.value("--limit").flatMap(Int.init) ?? 40
        let maxPerKind = options.value("--max-per-kind").flatMap(Int.init)
            ?? AXRegressionCorpusBuilder.defaultMaxTasksPerKind
        let apps: [AXRegressionCorpusApp]
        if let raw = options.value("--apps") {
            apps = raw.split(separator: ",")
                .map { AXRegressionCorpusApp.named(bundleID: $0.trimmingCharacters(in: .whitespaces)) }
        } else {
            apps = AXRegressionCorpusGenerator.defaultApps
        }
        let manifest = try AXRegressionCorpusGenerator.generate(
            apps: apps,
            outDirectory: outDir,
            maxPerKind: maxPerKind,
            crawl: AXRegressionCorpusGenerator.liveCrawl(limit: limit)
        )
        for app in manifest.apps {
            print("\(app.bundleID): \(app.status.rawValue) — \(app.taskCount) tasks (hash \(app.corpusHash))")
        }
        print("corpus: \(manifest.totalTaskCount) tasks across \(manifest.apps.count) apps (hash \(manifest.corpusHash)) -> \(outDir.path)")
    }

    /// d19: score a crawled corpus — per app/target, does AX still expose the
    /// target, and does the resolved click LAND on it (systemwide hit-test of the
    /// final screen state), never click-count. d20: `--tasks` replays a stored
    /// regression-corpus fixture through the same scorer.
    private static func axEval(_ options: ArgumentParser) throws {
        if let bundleID = options.value("--app") {
            try AXGroundingCrawler.activate(bundleIdentifier: bundleID)
        }
        let targets: [AXGroundingTarget]
        if let tasksURL = options.optionalURL("--tasks") {
            targets = try AXRegressionTaskJSONL.load(from: tasksURL).map(\.target)
        } else {
            targets = try AXGroundingTargetJSONL.load(from: options.requiredURL("--targets"))
        }
        let report = AXGroundingEvalRunner().run(targets: targets)
        let json = try report.jsonString()
        if let out = options.optionalURL("--out") {
            try json.appending("\n").write(to: out, atomically: true, encoding: .utf8)
        }
        print(json)
    }

    /// d21: the ablation — AX-only vs vision-only vs hybrid over the SAME
    /// corpus, scored by the same execution/final-state landing check, so the
    /// only variable is the grounding stack. The hybrid arm's failure rate is
    /// the number the AX-first plan tracks. Needs a LIVE run: Accessibility +
    /// Screen Recording granted, the corpus apps running, and (for the vision
    /// arms) a reachable grounder endpoint.
    private static func axAblation(_ options: ArgumentParser) async throws {
        let arms: [AXGroundingAblationArm]
        if let raw = options.value("--arms") {
            arms = try raw.split(separator: ",").map { token in
                let name = token.trimmingCharacters(in: .whitespaces)
                guard let arm = AXGroundingAblationArm(rawValue: name) else {
                    throw CLIError.usage("Unknown arm \(name). Arms: ax_only, vision_only, hybrid.")
                }
                return arm
            }
        } else {
            arms = AXGroundingAblationArm.allCases
        }
        var grounder: (any VisualGrounder)?
        if arms.contains(where: \.needsVisualGrounder) {
            let apiKeyEnv = options.value("--api-key-env") ?? "OPENROUTER_API_KEY"
            grounder = GrounderRegistry.makeGrounder(
                presetID: options.value("--preset"),
                apiKey: ProcessInfo.processInfo.environment[apiKeyEnv],
                endpointOverride: options.value("--endpoint"),
                modelOverride: options.value("--model"),
                coordSpaceOverride: options.value("--coord-space")
            )
            guard grounder != nil else {
                throw CLIError.usage(
                    "vision_only/hybrid need a visual grounder. Check --preset, --endpoint, --model, --coord-space, and --api-key-env."
                )
            }
        }
        let groups: [AXGroundingAblationCorpus.AppGroup]
        if let corpusDir = options.optionalURL("--corpus-dir") {
            groups = try AXGroundingAblationCorpus.loadGroups(fromCorpusDirectory: corpusDir)
        } else if let tasksURL = options.optionalURL("--tasks") {
            groups = AXGroundingAblationCorpus.groups(
                fromTargets: try AXRegressionTaskJSONL.load(from: tasksURL).map(\.target)
            )
        } else {
            groups = AXGroundingAblationCorpus.groups(
                fromTargets: try AXGroundingTargetJSONL.load(from: options.requiredURL("--targets"))
            )
        }
        let allTargets = groups.flatMap(\.targets)
        guard !allTargets.isEmpty else { throw AXGroundingAblationCorpusError.emptyCorpus }
        let probes = AXGroundingAblationRunner.liveProbes(
            arms: arms,
            grounder: grounder,
            skills: AppSkillRegistry.load()
        )
        let runner = AXGroundingAblationRunner()
        var observationsByArm: [AXGroundingAblationArm: [AXGroundingEvalObservation]] = [:]
        // One activation per app covers every arm — probes score targets of a
        // non-frontmost app as skipped, so a failed activation is recorded,
        // never fatal for the other apps.
        for group in groups {
            do {
                try AXGroundingCrawler.activate(bundleIdentifier: group.bundleID)
            } catch {
                FileHandle.standardError.write(Data("\(group.bundleID): \(error) — its targets will be skipped\n".utf8))
            }
            for arm in AXGroundingAblationArm.allCases {
                guard let probe = probes[arm] else { continue }
                let rows = await runner.observations(targets: group.targets, probe: probe)
                observationsByArm[arm, default: []].append(contentsOf: rows)
            }
        }
        let report = AXGroundingAblationRunner.report(targets: allTargets, observationsByArm: observationsByArm)
        let json = try report.jsonString()
        if let out = options.optionalURL("--out") {
            try json.appending("\n").write(to: out, atomically: true, encoding: .utf8)
        }
        print(json)
        for summary in report.summaries {
            print("\(summary.arm): landed \(summary.landed)/\(summary.scored) (land \(String(format: "%.3f", summary.landRate)), failure \(String(format: "%.3f", summary.failureRate)))")
        }
        if let failureRate = report.hybridFailureRate, let wins = report.hybridWins {
            print("hybrid failure rate: \(String(format: "%.3f", failureRate)) — hybrid \(wins ? "WINS" : "does NOT win") on this corpus (hash \(report.corpusHash))")
        }
    }

    /// d22 (stretch): MacAgentBench adapter stub — grade a task file's
    /// checkpoints (AX-state predicates) against the CURRENT screen state, after
    /// an external driver ran Cascade on the task's instruction. Read-only; the
    /// remaining wiring (official schema, per-task driver, submission format) is
    /// documented in docs/research/AX_FIRST_GROUNDING_PLAN.md.
    private static func mabScore(_ options: ArgumentParser) throws {
        var tasks = try MacAgentBenchTaskFile.load(from: options.requiredURL("--tasks"))
        if let taskID = options.value("--task") {
            tasks = tasks.filter { $0.taskID == taskID }
            guard !tasks.isEmpty else { throw MacAgentBenchTaskFileError.unknownTaskID(taskID) }
        }
        if options.value("--activate") == "true" {
            // Bring each task's app forward before grading (already-running apps
            // only). Default off — the external driver owns the screen.
            for bundleID in Set(tasks.map(\.appBundle)) {
                do {
                    try AXGroundingCrawler.activate(bundleIdentifier: bundleID)
                } catch {
                    FileHandle.standardError.write(Data("\(bundleID): \(error) — its element checkpoints will be skipped\n".utf8))
                }
            }
        }
        let report = MacAgentBenchScorer().run(tasks: tasks)
        let json = try report.jsonString()
        if let out = options.optionalURL("--out") {
            try json.appending("\n").write(to: out, atomically: true, encoding: .utf8)
        }
        print(json)
        for score in report.taskScores {
            print("\(score.taskID): \(score.satisfied)/\(score.checkpointCount) checkpoints (score \(String(format: "%.3f", score.checkpointScore))) — \(score.success ? "SUCCESS" : "not complete")")
        }
        print("mean checkpoint score \(String(format: "%.3f", report.meanCheckpointScore)), task success \(report.taskSuccessCount)/\(report.taskCount) (bench hash \(report.benchHash))")
    }

    private static let usage = """
    Usage:
      swift run grounding-bench export --db <copy/Cascade.sqlite> --out <cases.jsonl> [--frame-root <dir>] [--target-sidecar <hash-to-text.json>]
      swift run grounding-bench fixture --out-dir <dir> [--jsonl <cases.jsonl>]
      swift run grounding-bench run --jsonl <cases.jsonl> [--preset <id>] [--endpoint <url>] [--model <id>] [--coord-space <smartResize|sent|normalized>] [--api-key-env <ENV>]
      swift run grounding-bench ax-crawl --out <targets.jsonl> [--app <bundle-id>] [--limit <n>]
      swift run grounding-bench ax-corpus --out-dir <dir> [--apps <bundle,bundle,…>] [--limit <n>] [--max-per-kind <n>]
      swift run grounding-bench ax-eval (--targets <targets.jsonl> | --tasks <bundle.tasks.jsonl>) [--app <bundle-id>] [--out <report.json>]
      swift run grounding-bench ax-ablation (--corpus-dir <dir> | --tasks <bundle.tasks.jsonl> | --targets <targets.jsonl>) [--arms ax_only,vision_only,hybrid] [--preset <id>] [--endpoint <url>] [--model <id>] [--coord-space <smartResize|sent|normalized>] [--api-key-env <ENV>] [--out <report.json>]
      swift run grounding-bench mab-score --tasks <mab-tasks.json> [--task <task-id>] [--activate true] [--out <report.json>]

    Required flag:
      defaults write -g cascade.experimentalGroundingBench -bool true

    Export reads a closed/checkpointed copy of Cascade.sqlite. Never pass the live database in ~/Library/Application Support/Cascade.
    ax-crawl/ax-corpus/ax-eval need Accessibility permission and the app under test running; crawling and the eval are read-only (AX hit-tests, no synthetic clicks).
    ax-corpus defaults to Notes, System Settings, and Safari; apps that are not running are recorded in manifest.json instead of failing the run.
    ax-ablation (d21) replays the corpus through three arms — ax_only (d19 AX probe), vision_only (live capture + the configured visual grounder), hybrid (d15 route, AX-first, vision fallback) — and reports per-arm land/failure rates plus the hybrid deltas. It additionally needs Screen Recording permission and, for the vision arms, a reachable grounder endpoint (e.g. OPENROUTER_API_KEY for the hosted preset). Read-only: resolved points are hit-tested, never clicked. Keep the cursor on the display of the apps under test.
    mab-score (d22 stub) grades MacAgentBench-style checkpoints (frontmost_app / element_exists / element_value AX predicates) against the CURRENT screen state — run it AFTER an external driver executed the task's instruction through Cascade. Read-only; report rows are bench ids, status tokens, counts, and ax:<hash> stable ids only. Remaining wiring (official schema, per-task driver, submission format) is documented in docs/research/AX_FIRST_GROUNDING_PLAN.md.
    """
}

private enum CLIError: Error, CustomStringConvertible {
    case flagDisabled
    case usage(String)

    var description: String {
        switch self {
        case .flagDisabled:
            return "cascade.experimentalGroundingBench is off. Enable the private harness flag before running benchmark commands."
        case .usage(let message):
            return message
        }
    }
}

private struct ArgumentParser {
    private let arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func optionalURL(_ name: String) -> URL? {
        value(name).map { URL(fileURLWithPath: $0) }
    }

    func requiredURL(_ name: String) throws -> URL {
        guard let raw = value(name), !raw.isEmpty else {
            throw CLIError.usage("Missing required option \(name).")
        }
        return URL(fileURLWithPath: raw)
    }
}
