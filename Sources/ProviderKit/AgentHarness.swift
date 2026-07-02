import CascadeMemory
import CryptoKit
import Darwin
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
    case readFileSnippet(path: String, options: ReadFileOptions)
    case runCommand(String)
    case runAppleScript(String)
    case writeFile(path: String, content: String)

    public struct ReadFileOptions: Sendable, Equatable {
        public let query: String?
        public let startLine: Int?
        public let lineCount: Int?
        public let maxChars: Int?

        public init(query: String? = nil, startLine: Int? = nil, lineCount: Int? = nil, maxChars: Int? = nil) {
            let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.query = trimmedQuery.isEmpty ? nil : trimmedQuery
            self.startLine = startLine
            self.lineCount = lineCount
            self.maxChars = maxChars
        }

        var hasControls: Bool {
            query != nil || startLine != nil || lineCount != nil || maxChars != nil
        }

        static func from(input: [String: Any]) -> ReadFileOptions {
            ReadFileOptions(
                query: input["query"] as? String,
                startLine: Self.int(input["startLine"] ?? input["start_line"]),
                lineCount: Self.int(input["lineCount"] ?? input["line_count"]),
                maxChars: Self.int(input["maxChars"] ?? input["max_chars"])
            )
        }

        private static func int(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }
    }

    public init?(name: String, input: [String: Any]) {
        switch name {
        case "search_files":
            self = .searchFiles(query: input["query"] as? String ?? "", folder: input["folder"] as? String)
        case "list_folder":
            self = .listFolder(path: input["path"] as? String ?? "")
        case "read_file":
            let path = input["path"] as? String ?? ""
            let options = ReadFileOptions.from(input: input)
            self = options.hasControls ? .readFileSnippet(path: path, options: options) : .readFile(path: path)
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
        case .searchFiles, .listFolder, .readFile, .readFileSnippet: false
        case .runCommand, .runAppleScript, .writeFile: true
        }
    }

    public var toolName: String {
        switch self {
        case .searchFiles: "search_files"
        case .listFolder: "list_folder"
        case .readFile, .readFileSnippet: "read_file"
        case .runCommand: "run_command"
        case .runAppleScript: "run_applescript"
        case .writeFile: "write_file"
        }
    }

    /// What the audit log stores: stable descriptors only, never raw queries,
    /// paths, commands, script bodies, or file contents.
    public var auditDescriptor: String {
        var fields = ["tool=\(toolName)"]
        switch self {
        case .searchFiles(let query, let folder):
            fields.append("queryHash=\(Self.hash(query))")
            fields.append("folderHash=\(folder.map(Self.hash) ?? "none")")
        case .listFolder(let path), .readFile(let path):
            fields.append("pathHash=\(Self.hash(path))")
        case .readFileSnippet(let path, let options):
            fields.append("pathHash=\(Self.hash(path))")
            fields.append("scoped=true")
            if let query = options.query { fields.append("queryHash=\(Self.hash(query))") }
            if let startLine = options.startLine { fields.append("startLine=\(max(1, startLine))") }
            if let lineCount = options.lineCount { fields.append("lineCount=\(max(1, lineCount))") }
            if let maxChars = options.maxChars { fields.append("maxChars=\(max(1, maxChars))") }
        case .runCommand(let command):
            fields.append("commandHash=\(Self.hash(command))")
        case .runAppleScript(let script):
            fields.append("scriptHash=\(Self.hash(script))")
        case .writeFile(let path, let content):
            fields.append("pathHash=\(Self.hash(path))")
            fields.append("contentBytes=\(content.utf8.count)")
        }
        return fields.joined(separator: " ")
    }

    /// User-visible supervision text may include the concrete local value; callers
    /// must not persist this in audit rows.
    public var displaySummary: String {
        let detail: String
        switch self {
        case .searchFiles(let query, let folder):
            detail = folder.map { "\(query) in \($0)" } ?? query
        case .listFolder(let path), .readFile(let path):
            detail = path
        case .readFileSnippet(let path, let options):
            var parts = [path]
            if let query = options.query { parts.append("query: \(query)") }
            if let startLine = options.startLine { parts.append("start line: \(startLine)") }
            if let lineCount = options.lineCount { parts.append("lines: \(lineCount)") }
            detail = parts.joined(separator: " · ")
        case .runCommand(let command):
            detail = command
        case .runAppleScript(let script):
            detail = script.replacingOccurrences(of: "\n", with: " | ")
        case .writeFile(let path, let content):
            detail = "\(path) (\(content.utf8.count) bytes)"
        }
        return String(detail.prefix(160))
    }

    public static func auditDescriptor(name: String, input: [String: Any]) -> String {
        if let call = HarnessCall(name: name, input: input) {
            return call.auditDescriptor
        }
        let keys = input.keys.sorted()
        let canonical = keys.map { key in "\(key)=\(String(describing: input[key] ?? ""))" }
            .joined(separator: "\u{1f}")
        let inputKeys = keys.map(Self.safeToken).filter { !$0.isEmpty }.joined(separator: ",")
        return "tool=\(Self.safeToken(name)) inputHash=\(Self.hash(canonical)) inputKeys=\(inputKeys)"
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeToken(_ value: String) -> String {
        let token = value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
        return token.isEmpty ? "unknown" : token
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

    public static func isReadOnlyTool(_ name: String) -> Bool {
        readOnlyTools.contains(name)
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
            return status(.refused, tool: call.toolName, kind: "power_harness_disabled", message: "The Power harness is OFF in Cascade's Settings, so this tool is disabled. Either do this on screen with the computer tool, or tell the user they can enable Settings → Agent harness → Power harness to let you run it directly.")
        }
        switch call {
        case .searchFiles(let query, let folder):
            return await searchFiles(query: query, folder: folder)
        case .listFolder(let path):
            return listFolder(path: path)
        case .readFile(let path):
            return readFile(path: path, options: nil)
        case .readFileSnippet(let path, let options):
            return readFile(path: path, options: options)
        case .runCommand(let command):
            return await runCommand(command)
        case .runAppleScript(let script):
            return await runAppleScript(script)
        case .writeFile(let path, let content):
            return writeFile(path: path, content: content)
        }
    }

    public static func performEvidence(_ call: HarnessCall, powerEnabled: Bool) async -> SourceEvidence {
        let result = await perform(call, powerEnabled: powerEnabled)
        return SourceEvidence.fromToolResult(
            result,
            source: call.isPower ? .action : .localFiles,
            defaultTool: call.toolName
        )
    }

    // MARK: - Read-only tier

    private static func searchFiles(query: String, folder: String?) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return status(.error, tool: "search_files", kind: "validation_error", message: "search_files needs a query.") }
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
        guard !paths.isEmpty else { return status(.noResult, tool: "search_files", kind: "no_matches", message: "No files matched “\(trimmed)” under \(scope).") }
        guard !visible.isEmpty else {
            return status(.refused, tool: "search_files", kind: "privacy_refusal", message: "Matches were only in privacy-protected locations, so their paths stay local.")
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
            return status(.noResult, tool: "list_folder", kind: "missing_folder", message: "No such folder: \(expanded)")
        }
        guard isDirectory.boolValue else { return status(.error, tool: "list_folder", kind: "not_a_folder", message: "\(expanded) is a file, not a folder — use read_file.") }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
            return status(.error, tool: "list_folder", kind: "read_failed", message: "Couldn't list \(expanded) (no permission?).")
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
        guard !entries.isEmpty else { return status(.noResult, tool: "list_folder", kind: "empty_folder", message: "\(expanded) is empty.") }
        let shown = entries.prefix(200)
        var text = shown.joined(separator: "\n")
        if entries.count > shown.count { text += "\n…and \(entries.count - shown.count) more." }
        return text
    }

    /// Bounded, privacy-gated read. The same exclude-list that drops recorded
    /// frames refuses file content here — the harness must not become a side
    /// door around the user's privacy rules.
    static let readCap = 24_000

    private static func readFile(path: String, options: HarnessCall.ReadFileOptions?) -> String {
        let expanded = expand(path)
        if let reason = sensitivePathReason(expanded) { return reason }
        guard FileManager.default.fileExists(atPath: expanded) else { return status(.noResult, tool: "read_file", kind: "missing_file", message: "No such file: \(expanded)") }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            return status(.error, tool: "read_file", kind: "read_failed", message: "Couldn't read \(expanded) (no permission?).")
        }
        guard let text = String(data: data.prefix(readCap * 4), encoding: .utf8) else {
            return status(.refused, tool: "read_file", kind: "binary_file", message: "\(expanded) is binary (\(data.count) bytes) — read_file only reads text.")
        }
        if PrivacyRules.isSensitiveText(expanded) || PrivacyRules.isSensitiveText(text) {
            return privacyRefusal("file")
        }
        let scoped = scopedFileContent(text, options: options)
        let cap = max(256, min(options?.maxChars ?? readCap, readCap))
        let content = scoped.count > cap
            ? String(scoped.prefix(cap)) + "\n...[truncated - \(data.count) bytes total]"
            : scoped
        return InjectionGuard.renderEnvelope(
            trust: .untrustedFile,
            source: canonicalize(expanded),
            acquiredByTool: "read_file",
            payload: content
        )
    }

    private static func scopedFileContent(_ text: String, options: HarnessCall.ReadFileOptions?) -> String {
        guard let options, options.hasControls else { return text }
        let allLines = text.components(separatedBy: .newlines)
        var selected: [(lineNumber: Int, text: String)]
        if let startLine = options.startLine {
            let start = max(1, startLine) - 1
            let count = max(1, min(options.lineCount ?? 120, 500))
            selected = Array(allLines.enumerated().dropFirst(start).prefix(count))
                .map { (lineNumber: $0.offset + 1, text: $0.element) }
        } else {
            selected = allLines.enumerated().map { (lineNumber: $0.offset + 1, text: $0.element) }
        }
        if let query = options.query {
            let tokens = queryTokens(query)
            if !tokens.isEmpty {
                let matches = selected.enumerated().filter { _, line in
                    let normalized = InjectionGuard.normalizedForDetection(line.text)
                    return tokens.allSatisfy { normalized.contains($0) }
                }
                if !matches.isEmpty {
                    var keep = Set<Int>()
                    for (index, _) in matches {
                        for offset in -2...2 {
                            let candidate = index + offset
                            if selected.indices.contains(candidate) { keep.insert(candidate) }
                        }
                    }
                    selected = keep.sorted().map { selected[$0] }
                }
            }
        }
        let rendered = selected.map { line in
            "\(line.lineNumber): \(line.text)"
        }.joined(separator: "\n")
        return rendered.isEmpty ? "(no matching text in requested snippet)" : rendered
    }

    private static func queryTokens(_ query: String) -> [String] {
        InjectionGuard.normalizedForDetection(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
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
        // Network egress / remote transfer — an autonomous harness must not
        // exfiltrate local data or pull remote payloads. On-screen `open_url`
        // exists for legitimate fetches the user can watch.
        #"\b(curl|wget)\b"#,
        #"\b(scp|sftp|rsync|ssh|telnet)\b"#,
        #"\b(nc|ncat|netcat)\b"#,
        // Persistence / privilege & automation escalation.
        #"\blaunchctl\b"#,
        #"\bosascript\b"#,                                  // TCC/automation escalation via shell
        // Inline-interpreter network egress — the obvious way around the named
        // network-tool blocks above. Bounded look-ahead, defense-in-depth only:
        // the deny-list is a guardrail, not a sandbox (see the type doc).
        #"\bpython[0-9.]*\s+-c\b.{0,200}(urllib|requests|socket|http\.client|httplib|smtplib|ftplib)"#,
        #"\b(node|nodejs|deno|bun)\s+-e\b.{0,200}(https?|net|fetch|require\()"#,
        #"\b(perl|ruby)\s+-e\b.{0,200}(socket|net::http|net/http|lwp|open-uri|httparty)"#,
    ]

    /// Why a command is refused, or nil when it may run.
    public static func denialReason(for command: String) -> String? {
        if let refusal = guardrailDenialReason(for: command) { return refusal }
        if let refusal = structuredCommand(for: command).refusal { return refusal }
        return nil
    }

    private static func guardrailDenialReason(for command: String) -> String? {
        let normalized = command.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if PrivacyRules.isSensitiveText(normalized) {
            return privacyRefusal("command")
        }
        if commandMentionsProtectedPath(normalized) {
            return status(.refused, tool: "run_command", kind: "protected_path", message: "That command references a protected local credential or Cascade data path, so it will not run.")
        }
        for pattern in denyPatterns where normalized.range(of: pattern, options: .regularExpression) != nil {
            return status(.refused, tool: "run_command", kind: "deny_list", message: "That command matches Cascade's destructive-command deny-list and will not run. Pick a narrower, non-destructive command, or do it on screen where the user can watch.")
        }
        return nil
    }

    static let outputCap = 12_000

    private static func runCommand(_ command: String) async -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return status(.error, tool: "run_command", kind: "validation_error", message: "run_command needs a command.") }
        if let denial = denialReason(for: trimmed) { return denial }
        guard let parsed = structuredCommand(for: trimmed).command else {
            return status(.refused, tool: "run_command", kind: "shell_syntax_refused", message: "run_command only accepts an allowlisted executable plus literal argv; shell syntax is refused.")
        }
        let result = await run(parsed.executable, parsed.arguments, cwd: NSHomeDirectory(), timeout: 25)
        var text = capped(result.output)
        if result.status != 0 {
            text += text.isEmpty ? "(exit \(result.status))" : "\n(exit \(result.status))"
        }
        return text.isEmpty ? "(no output — exit 0)" : text
    }

    private static func runAppleScript(_ script: String) async -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return status(.error, tool: "run_applescript", kind: "validation_error", message: "run_applescript needs a script.") }
        if let denial = guardrailDenialReason(for: trimmed) { return denial }
        let result = await run("/usr/bin/osascript", ["-e", trimmed], timeout: 30)
        let text = capped(result.output)
        if result.status != 0 {
            return text.isEmpty ? "AppleScript failed (exit \(result.status))." : "AppleScript error:\n\(text)"
        }
        return text.isEmpty ? "(script ran — no return value)" : text
    }

    public static func allowedWorkspaceRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = base.appendingPathComponent("Cascade/HarnessWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return canonicalize(root.path)
    }

    public static func allowedSessionScratchRoot() -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CascadeHarnessScratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return canonicalize(root.path)
    }

    private static var writeRoots: [String] {
        [allowedWorkspaceRoot(), allowedSessionScratchRoot()]
    }

    /// Writes only where the user's own files live — home, temp dirs — never
    /// into system paths or through a symlink that escapes them.
    private static func writeFile(path: String, content: String) -> String {
        let expanded = expand(path)
        let destination = URL(fileURLWithPath: expanded)
        if let reason = sensitivePathReason(expanded) { return reason }
        guard let prepared = prepareWriteDestination(destination.path) else {
            return status(.refused, tool: "write_file", kind: "outside_write_root", message: "write_file only writes inside Cascade's harness workspace or session scratch root — not \(expanded).")
        }
        if let reason = sensitivePathReason(prepared.path) { return reason }
        do {
            try atomicWrite(content: content, to: prepared)
            return "Wrote \(content.utf8.count) bytes to \(prepared.path)."
        } catch {
            return status(.error, tool: "write_file", kind: "write_failed", message: "Couldn't write \(prepared.path): \(error.localizedDescription)")
        }
    }

    private struct StructuredCommand {
        let executable: String
        let arguments: [String]
    }

    private static let allowedExecutables: [String: String] = [
        "echo": "/bin/echo",
        "printf": "/usr/bin/printf",
        "pwd": "/bin/pwd",
        "ls": "/bin/ls",
        "grep": "/usr/bin/grep",
        "find": "/usr/bin/find",
        "wc": "/usr/bin/wc",
        "shasum": "/usr/bin/shasum",
        "true": "/usr/bin/true",
        "false": "/usr/bin/false",
        "stat": "/usr/bin/stat",
    ]

    private static func structuredCommand(for command: String) -> (command: StructuredCommand?, refusal: String?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "run_command needs a command.") }
        guard let tokens = tokenizeStructuredCommand(trimmed) else {
            return (nil, "run_command only accepts a single allowlisted executable plus literal argv; pipes, redirects, substitutions, globs, variables, aliases, and inline shell syntax are refused.")
        }
        guard let executableToken = tokens.first else { return (nil, "run_command needs a command.") }
        let executable: String?
        if executableToken.contains("/") {
            let canonical = canonicalize(executableToken)
            executable = allowedExecutables.values.contains(canonical) ? canonical : nil
        } else {
            executable = allowedExecutables[executableToken]
        }
        guard let executable else {
            return (nil, "run_command executable is not allowlisted. Use one of: \(allowedExecutables.keys.sorted().joined(separator: ", ")).")
        }
        for argument in tokens.dropFirst() {
            if let refusal = commandArgumentRefusal(argument) { return (nil, refusal) }
        }
        return (StructuredCommand(executable: executable, arguments: Array(tokens.dropFirst())), nil)
    }

    private static func tokenizeStructuredCommand(_ command: String) -> [String]? {
        let refused = CharacterSet(charactersIn: "|&;<>()$`\\\n\r*?[]{}")
        if command.rangeOfCharacter(from: refused) != nil { return nil }
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in command {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        if !current.isEmpty { tokens.append(current) }
        return tokens.isEmpty ? nil : tokens
    }

    private static func commandArgumentRefusal(_ argument: String) -> String? {
        if PrivacyRules.isSensitiveText(argument) {
            return privacyRefusal("command argument")
        }
        guard looksPathLike(argument) else { return nil }
        let expanded = expand(argument)
        return sensitivePathReason(expanded)
    }

    private static func looksPathLike(_ argument: String) -> Bool {
        argument.hasPrefix("/")
            || argument.hasPrefix("~")
            || argument.hasPrefix("./")
            || argument.hasPrefix("../")
            || argument.contains("/")
    }

    private struct PreparedWriteDestination {
        let path: String
        let directory: String
        let fileName: String
    }

    private static func prepareWriteDestination(_ path: String) -> PreparedWriteDestination? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parentURL = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty, fileName != "." && fileName != ".." else { return nil }
        guard let parent = prepareCanonicalDirectory(parentURL.path) else { return nil }
        let destination = (parent as NSString).appendingPathComponent(fileName)
        guard isInsideAllowedRoot(destination, writeRoots) else { return nil }
        guard !isSymlink(path: destination) else { return nil }
        return PreparedWriteDestination(path: destination, directory: parent, fileName: fileName)
    }

    private static func prepareCanonicalDirectory(_ directory: String) -> String? {
        let expanded = expand(directory)
        let fm = FileManager.default
        if fm.fileExists(atPath: expanded) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let canonical = canonicalize(expanded)
            guard isInsideAllowedRoot(canonical, writeRoots) else { return nil }
            return canonical
        }

        var existing = expanded
        var tail: [String] = []
        while existing != "/", !existing.isEmpty, !fm.fileExists(atPath: existing) {
            let url = URL(fileURLWithPath: existing)
            let component = url.lastPathComponent
            guard !component.isEmpty, component != "." && component != ".." else { return nil }
            tail.insert(component, at: 0)
            let parent = url.deletingLastPathComponent().path
            if parent == existing { break }
            existing = parent
        }
        let canonicalExisting = canonicalize(existing)
        guard isInsideAllowedRoot(canonicalExisting, writeRoots) else { return nil }
        var candidate = canonicalExisting
        for component in tail {
            candidate = (candidate as NSString).appendingPathComponent(component)
            if isSymlink(path: candidate) { return nil }
        }
        do {
            try fm.createDirectory(atPath: expanded, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let canonical = canonicalize(expanded)
        guard isInsideAllowedRoot(canonical, writeRoots) else { return nil }
        return canonical
    }

    private static func atomicWrite(content: String, to destination: PreparedWriteDestination) throws {
        let tempName = ".\(destination.fileName).\(UUID().uuidString).tmp"
        let tempPath = (destination.directory as NSString).appendingPathComponent(tempName)
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let fd = open(tempPath, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var closeNeeded = true
        defer {
            if closeNeeded { close(fd) }
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        let data = Data(content.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, base, remaining)
                guard written > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
        fsync(fd)
        guard close(fd) == 0 else {
            closeNeeded = false
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        closeNeeded = false
        guard rename(tempPath, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard isInsideAllowedRoot(canonicalize(destination.path), writeRoots), !isSymlink(path: destination.path) else {
            try? FileManager.default.removeItem(atPath: destination.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
    }

    private static func isSymlink(path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Plumbing

    private static func expand(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Best-effort real on-disk path. Resolves symlinks on the nearest existing
    /// ancestor via POSIX `realpath` and re-appends the not-yet-created tail, so
    /// a symlinked parent can't disguise the true destination of a read or write.
    /// Lexical `..`/`~` are already collapsed by `expand`. Falls back to the
    /// expanded path if `realpath` is unavailable.
    static func canonicalize(_ path: String) -> String {
        let expanded = expand(path)
        let fm = FileManager.default
        var existing = expanded
        var tail: [String] = []
        while existing != "/", !existing.isEmpty, !fm.fileExists(atPath: existing) {
            let url = URL(fileURLWithPath: existing)
            tail.insert(url.lastPathComponent, at: 0)
            let parent = url.deletingLastPathComponent().path
            if parent == existing { break }
            existing = parent
        }
        guard let resolved = existing.withCString({ ptr -> String? in
            guard let r = realpath(ptr, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }) else { return expanded }
        var result = resolved
        for component in tail { result = (result as NSString).appendingPathComponent(component) }
        return result
    }

    /// True when `canonical` is genuinely inside one of `roots` (compared on
    /// canonical paths, with a trailing slash so `/home-evil` can't match `/home`).
    private static func isInsideAllowedRoot(_ canonical: String, _ roots: [String]) -> Bool {
        let withSlash = canonical.hasSuffix("/") ? canonical : canonical + "/"
        return roots.map(canonicalize).contains { root in
            let rootSlash = root.hasSuffix("/") ? root : root + "/"
            return canonical == root || withSlash.hasPrefix(rootSlash)
        }
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
        // Canonicalize first: a symlink must not hide a protected component
        // (e.g. `~/work/k -> ~/.ssh` would otherwise read as `…/k`, not `.ssh`).
        let expanded = canonicalize(path)
        if PrivacyRules.isSensitiveText(expanded) {
            return privacyRefusal("path")
        }
        let components = URL(fileURLWithPath: expanded).standardizedFileURL.pathComponents
            .map { $0.lowercased() }
        if components.contains(where: { protectedPathComponents.contains($0) }) {
            return status(.refused, tool: nil, kind: "protected_path", message: "That path is in a protected local credential directory, so it stays local.")
        }
        let lower = expanded.lowercased()
        let slashTerminated = lower.hasSuffix("/") ? lower : lower + "/"
        if protectedSubpaths.contains(where: { slashTerminated.contains($0) }) {
            return status(.refused, tool: nil, kind: "protected_path", message: "That path is in protected local application data, so it stays local.")
        }
        return nil
    }

    private static func commandMentionsProtectedPath(_ command: String) -> Bool {
        protectedCommandFragments.contains { command.contains($0) }
    }

    private static func privacyRefusal(_ noun: String) -> String {
        status(.refused, tool: nil, kind: "privacy_refusal", message: "That \(noun) matches the user's privacy exclusions — its content stays local. Tell the user why if they asked for it directly.")
    }

    private static func status(
        _ status: ToolResultStatusEnvelope.Status,
        tool: String?,
        kind: String,
        message: String
    ) -> String {
        ToolResultStatusEnvelope.render(status, kind: kind, message: message, tool: tool)
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
