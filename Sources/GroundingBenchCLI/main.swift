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

    private static let usage = """
    Usage:
      swift run grounding-bench export --db <copy/Cascade.sqlite> --out <cases.jsonl> [--frame-root <dir>] [--target-sidecar <hash-to-text.json>]
      swift run grounding-bench fixture --out-dir <dir> [--jsonl <cases.jsonl>]
      swift run grounding-bench run --jsonl <cases.jsonl> [--preset <id>] [--endpoint <url>] [--model <id>] [--coord-space <smartResize|sent|normalized>] [--api-key-env <ENV>]

    Required flag:
      defaults write -g cascade.experimentalGroundingBench -bool true

    Export reads a closed/checkpointed copy of Cascade.sqlite. Never pass the live database in ~/Library/Application Support/Cascade.
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
