import CascadeMemory
import Foundation

/// Which direct-Mac tools the assist agent is offered alongside the computer tool.
/// `readOnly` (the default for every run) can find and read; `full` — the
/// "Power harness" Settings toggle — can also run commands, drive scriptable
/// apps, and write files.
public enum HarnessTier: Sendable, Equatable {
    case off
    case readOnly
    case full
}

/// One parsed harness tool call — `Sendable`, so the caller can extract it from
/// the model's raw tool input on the main actor and hand it to the nonisolated
/// executor without crossing isolation with an untyped dictionary.
public enum HarnessCall: Sendable, Equatable {
    case searchFiles(query: String, folder: String?)
    case listFolder(path: String)
    case readFile(path: String)
    case runCommand(String)
    case runAppleScript(String)
    case writeFile(path: String, content: String)

    public init?(name: String, input: [String: Any]) {
        switch name {
        case "search_files":
            self = .searchFiles(query: input["query"] as? String ?? "", folder: input["folder"] as? String)
        case "list_folder":
            self = .listFolder(path: input["path"] as? String ?? "")
        case "read_file":
            self = .readFile(path: input["path"] as? String ?? "")
        case "run_command":
            self = .runCommand(input["command"] as? String ?? "")
        case "run_applescript":
            self = .runAppleScript(input["script"] as? String ?? "")
        case "write_file":
            self = .writeFile(path: input["path"] as? String ?? "", content: input["content"] as? String ?? "")
        default:
            return nil
        }
    }

    /// Tools in the power tier need the user's explicit Settings opt-in.
    public var isPower: Bool {
        switch self {
        case .searchFiles, .listFolder, .readFile: false
        case .runCommand, .runAppleScript, .writeFile: true
        }
    }

    /// What goes into the audit log — the verbatim query, path, or command
    /// (capped for the audit row), never silently summarized away.
    public var auditSummary: String {
        let detail: String
        switch self {
        case .searchFiles(let query, _): detail = query
        case .listFolder(let path): detail = path
        case .readFile(let path): detail = path
        case .runCommand(let command): detail = command
        case .runAppleScript(let script): detail = script.replacingOccurrences(of: "\n", with: " ⏎ ")
        case .writeFile(let path, let content): detail = "\(path) (\(content.count) chars)"
        }
        return String(detail.prefix(240))
    }
}

/// Executes the agent's direct-Mac harness tools: Spotlight search, folder
/// listing, bounded file reads, and — power tier only — shell commands,
/// AppleScript, and file writes. These resolve in-process like `use_skill`
/// (no screenshot round-trip), which is what makes "search my desktop" or
/// "edit 500 cells in Numbers" instant instead of a click marathon.
///
/// This is a guardrail, not a sandbox: the power tier is an explicit user
/// opt-in, every call is audited, and the deny-list below blocks the
/// obviously destructive shapes — it does not try to outwit a hostile model.
public enum AgentHarness {
    public static let readOnlyTools = ["search_files", "list_folder", "read_file"]
    public static let powerTools = ["run_command", "run_applescript", "write_file"]

    public static func isHarnessTool(_ name: String) -> Bool {
        readOnlyTools.contains(name) || powerTools.contains(name)
    }

    /// App names an AppleScript source (or an osascript-bearing shell command)
    /// drives via `tell application "X"` / `tell app "X"` / `tell application id
    /// "com.vendor.X"`. Bundle-id targets yield their last dot component
    /// ("com.apple.Keynote" → "Keynote"). Callers use this to enforce one lane
    /// per artifact: scripting an app whose UI the task is already working on
    /// screen abandons work the user is watching.
    public static func scriptedAppTargets(in source: String) -> [String] {
        let pattern = #"(?i)\btell\s+app(?:lication)?\s+(id\s+)?"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var targets: [String] = []
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 2), in: source) else { return }
            var name = String(source[nameRange])
            if match.range(at: 1).location != NSNotFound, let tail = name.split(separator: ".").last {
                name = String(tail)  // bundle id → app name component
            }
            if !targets.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                targets.append(name)
            }
        }
        return targets
    }

    public static func perform(_ call: HarnessCall, powerEnabled: Bool) async -> String {
        if call.isPower, !powerEnabled {
            return "The Power harness is OFF in Cascade's Settings, so this tool is disabled. "
                + "Either do this on screen with the computer tool, or tell the user they can "
                + "enable Settings → Agent harness → Power harness to let you run it directly."
        }
        switch call {
        case .searchFiles(let query, let folder):
            return await searchFiles(query: query, folder: folder)
        case .listFolder(let path):
            return listFolder(path: path)
        case .readFile(let path):
            return readFile(path: path)
        case .runCommand(let command):
            return await runCommand(command)
        case .runAppleScript(let script):
            return await runAppleScript(script)
        case .writeFile(let path, let content):
            return writeFile(path: path, content: content)
        }
    }

    // MARK: - Read-only tier

    private static func searchFiles(query: String, folder: String?) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "search_files needs a query." }
        guard !PrivacyRules.isSensitiveText(trimmed) else {
            return privacyRefusal("search query")
        }
        let scope = expand(folder?.isEmpty == false ? folder! : NSHomeDirectory())
        if let reason = sensitivePathReason(scope) { return reason }
        // Plain mdfind matches content + metadata; if nothing hits, retry as a
        // filename-only search — "find my resume" usually means the file name.
        var result = await run("/usr/bin/mdfind", ["-onlyin", scope, trimmed], timeout: 10)
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = await run("/usr/bin/mdfind", ["-onlyin", scope, "-name", trimmed], timeout: 10)
        }
        let paths = result.output.split(separator: "\n").map(String.init)
        let visible = paths.filter { sensitivePathReason($0) == nil }
        guard !paths.isEmpty else { return "No files matched “\(trimmed)” under \(scope)." }
        guard !visible.isEmpty else {
            return "Matches were only in privacy-protected locations, so their paths stay local."
        }
        let shown = visible.prefix(40)
        var text = shown.joined(separator: "\n")
        if visible.count > shown.count { text += "\n…and \(visible.count - shown.count) more." }
        return text
    }

    private static func listFolder(path: String) -> String {
        let expanded = expand(path)
        if let reason = sensitivePathReason(expanded) { return reason }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return "No such folder: \(expanded)"
        }
        guard isDirectory.boolValue else { return "\(expanded) is a file, not a folder — use read_file." }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
            return "Couldn't list \(expanded) (no permission?)."
        }
        let entries = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { name in
                let full = (expanded as NSString).appendingPathComponent(name)
                return sensitivePathReason(full) == nil
            }
            .map { name -> String in
                var isDir: ObjCBool = false
                let full = (expanded as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                return isDir.boolValue ? name + "/" : name
            }
        guard !entries.isEmpty else { return "\(expanded) is empty." }
        let shown = entries.prefix(200)
        var text = shown.joined(separator: "\n")
        if entries.count > shown.count { text += "\n…and \(entries.count - shown.count) more." }
        return text
    }

    /// Bounded, privacy-gated read. The same exclude-list that drops recorded
    /// frames refuses file content here — the harness must not become a side
    /// door around the user's privacy rules.
    static let readCap = 24_000

    private static func readFile(path: String) -> String {
        let expanded = expand(path)
        if let reason = sensitivePathReason(expanded) { return reason }
        guard FileManager.default.fileExists(atPath: expanded) else { return "No such file: \(expanded)" }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            return "Couldn't read \(expanded) (no permission?)."
        }
        guard let text = String(data: data.prefix(readCap * 4), encoding: .utf8) else {
            return "\(expanded) is binary (\(data.count) bytes) — read_file only reads text."
        }
        if PrivacyRules.isSensitiveText(expanded) || PrivacyRules.isSensitiveText(text) {
            return privacyRefusal("file")
        }
        if text.count > readCap {
            return String(text.prefix(readCap)) + "\n…[truncated — \(data.count) bytes total]"
        }
        return text
    }

    // MARK: - Power tier

    /// Destructive command shapes refused outright, opt-in or not. Patterns are
    /// matched against the whitespace-collapsed lowercased command.
    private static let denyPatterns: [String] = [
        #"(^|[;&|`(]\s*)sudo\b"#,                           // privilege escalation
        #"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf][a-z]*\s+(--?\S+\s+)*["']?(/|~|\$home)["']?(\s|$|[;&|])"#,  // rm -rf / or ~ itself
        #"\|\s*(sh|bash|zsh)\b"#,                           // curl … | sh
        #"\bmkfs\b"#,
        #"\bdiskutil\s+(erase|partition|reformat)"#,
        #"\bdd\s+(if|of)="#,
        #"\b(shutdown|reboot|halt)\b"#,
        #"\bsecurity\s+(find|dump|export)"#,                // keychain extraction
        #"\bcsrutil\b"#,
        #">\s*/dev/(disk|rdisk)"#,
        #":\(\)\s*\{"#,                                     // fork bomb
    ]

    /// Why a command is refused, or nil when it may run.
    public static func denialReason(for command: String) -> String? {
        let normalized = command.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if PrivacyRules.isSensitiveText(normalized) {
            return privacyRefusal("command")
        }
        if commandMentionsProtectedPath(normalized) {
            return "That command references a protected local credential or Cascade data path, so it will not run."
        }
        for pattern in denyPatterns where normalized.range(of: pattern, options: .regularExpression) != nil {
            return "That command matches Cascade's destructive-command deny-list and will not run. "
                + "Pick a narrower, non-destructive command, or do it on screen where the user can watch."
        }
        return nil
    }

    static let outputCap = 12_000

    private static func runCommand(_ command: String) async -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "run_command needs a command." }
        if let denial = denialReason(for: trimmed) { return denial }
        let result = await run("/bin/zsh", ["-c", trimmed], cwd: NSHomeDirectory(), timeout: 25)
        var text = capped(result.output)
        if result.status != 0 {
            text += text.isEmpty ? "(exit \(result.status))" : "\n(exit \(result.status))"
        }
        return text.isEmpty ? "(no output — exit 0)" : text
    }

    private static func runAppleScript(_ script: String) async -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "run_applescript needs a script." }
        if let denial = denialReason(for: trimmed) { return denial }
        let result = await run("/usr/bin/osascript", ["-e", trimmed], timeout: 30)
        let text = capped(result.output)
        if result.status != 0 {
            return text.isEmpty ? "AppleScript failed (exit \(result.status))." : "AppleScript error:\n\(text)"
        }
        return text.isEmpty ? "(script ran — no return value)" : text
    }

    /// Writes only where the user's own files live — home, temp dirs — never
    /// into system paths.
    private static func writeFile(path: String, content: String) -> String {
        let expanded = expand(path)
        if let reason = sensitivePathReason(expanded) { return reason }
        let allowedRoots = [NSHomeDirectory(), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        guard allowedRoots.contains(where: { expanded.hasPrefix($0 + "/") }) else {
            return "write_file only writes inside the user's home folder or temp dirs — not \(expanded)."
        }
        let url = URL(fileURLWithPath: expanded)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(expanded)."
        } catch {
            return "Couldn't write \(expanded): \(error.localizedDescription)"
        }
    }

    // MARK: - Plumbing

    private static func expand(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static let protectedPathComponents: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".gcloud", ".kube", ".docker"
    ]

    private static let protectedSubpaths = [
        "/library/keychains/",
        "/library/application support/cascade/",
        "/library/application support/com.humain.cascade/",
    ]

    private static let protectedCommandFragments = [
        "~/.ssh", "$home/.ssh", ".ssh/",
        "~/.gnupg", "$home/.gnupg", ".gnupg/",
        "~/.aws", "$home/.aws", ".aws/",
        "~/.azure", "$home/.azure", ".azure/",
        "~/.gcloud", "$home/.gcloud", ".gcloud/",
        "~/.kube", "$home/.kube", ".kube/",
        "~/.docker", "$home/.docker", ".docker/",
        "library/keychains",
        "application support/cascade",
        "application support/com.humain.cascade",
    ]

    private static func sensitivePathReason(_ path: String) -> String? {
        let expanded = expand(path)
        if PrivacyRules.isSensitiveText(expanded) {
            return privacyRefusal("path")
        }
        let components = URL(fileURLWithPath: expanded).standardizedFileURL.pathComponents
            .map { $0.lowercased() }
        if components.contains(where: { protectedPathComponents.contains($0) }) {
            return "That path is in a protected local credential directory, so it stays local."
        }
        let lower = expanded.lowercased()
        let slashTerminated = lower.hasSuffix("/") ? lower : lower + "/"
        if protectedSubpaths.contains(where: { slashTerminated.contains($0) }) {
            return "That path is in protected local application data, so it stays local."
        }
        return nil
    }

    private static func commandMentionsProtectedPath(_ command: String) -> Bool {
        protectedCommandFragments.contains { command.contains($0) }
    }

    private static func privacyRefusal(_ noun: String) -> String {
        "That \(noun) matches the user's privacy exclusions — its content stays local. "
            + "Tell the user why if they asked for it directly."
    }

    private static func capped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > outputCap else { return trimmed }
        return String(trimmed.prefix(outputCap)) + "\n…[output truncated]"
    }

    /// Runs a process off the main actor, draining stdout+stderr continuously
    /// (an undrained pipe deadlocks chatty processes), with a watchdog kill.
    private static func run(
        _ launchPath: String, _ arguments: [String], cwd: String? = nil, timeout: Double
    ) async -> (output: String, status: Int32) {
        await Task.detached(priority: .userInitiated) {
            runBlocking(launchPath, arguments, cwd: cwd, timeout: timeout)
        }.value
    }

    private static func runBlocking(
        _ launchPath: String, _ arguments: [String], cwd: String?, timeout: Double
    ) -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ("Couldn't run \(launchPath): \(error.localizedDescription)", -1)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Reading to EOF on this (detached) thread is the continuous drain.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        var output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationReason == .uncaughtSignal {
            // Killed by the watchdog — say so instead of returning silence.
            output += output.isEmpty ? "(timed out after \(Int(timeout))s)" : "\n(timed out after \(Int(timeout))s)"
        }
        return (output, process.terminationStatus)
    }
}
