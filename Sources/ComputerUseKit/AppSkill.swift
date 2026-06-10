import Foundation

// Ported from milind-soni/tiptour-macos `TipTour/Skills/MarkdownAppSkill.swift`
// (MIT) — see docs/PORT_MAP.md. Cascade divergences: `axUnreliable` hint,
// `cascade-runtime-hints` fence name (the tiptour fence still parses so their
// skill files drop in unmodified), and only `SKILL.md` files are loaded.

/// The small deterministic block a skill may carry in a fenced
/// ```cascade-runtime-hints JSON code block. TipTour-only keys
/// (commandAliases, targetPolicies, plannerInstructions) are intentionally
/// not declared — JSONDecoder ignores them.
public struct AppSkillRuntimeHints: Decodable, Sendable {
    public struct AppMatchers: Decodable, Sendable {
        public let bundleIdentifiers: [String]
        public let names: [String]

        public init(bundleIdentifiers: [String] = [], names: [String] = []) {
            self.bundleIdentifiers = bundleIdentifiers
            self.names = names
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
            names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case bundleIdentifiers, names
        }
    }

    public struct InputPolicy: Decodable, Sendable {
        public let kind: String
        public let delivery: String
        public let maxLength: Int?
        public let characters: String?

        public init(kind: String, delivery: String, maxLength: Int? = nil, characters: String? = nil) {
            self.kind = kind
            self.delivery = delivery
            self.maxLength = maxLength
            self.characters = characters
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
            delivery = try container.decodeIfPresent(String.self, forKey: .delivery) ?? ""
            maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
            characters = try container.decodeIfPresent(String.self, forKey: .characters)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, delivery, maxLength, characters
        }
    }

    public let appMatchers: AppMatchers?
    public let inputPolicies: [InputPolicy]
    /// Cascade extension: the app's AX tree does not reflect its visible UI
    /// (canvas apps like Blender), so AX-based target resolution, AX element
    /// pressing, and fingerprint verification must be skipped for it.
    public let axUnreliable: Bool
    /// Cascade extension: the app routes keyboard shortcuts to the editor
    /// under the physical pointer (Blender). The pointer must stay where the
    /// agent clicks (no cursor restore) and be inside the app's window before
    /// bare key presses, or hotkeys land nowhere.
    public let keysFollowPointer: Bool

    public init(
        appMatchers: AppMatchers? = nil,
        inputPolicies: [InputPolicy] = [],
        axUnreliable: Bool = false,
        keysFollowPointer: Bool = false
    ) {
        self.appMatchers = appMatchers
        self.inputPolicies = inputPolicies
        self.axUnreliable = axUnreliable
        self.keysFollowPointer = keysFollowPointer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appMatchers = try container.decodeIfPresent(AppMatchers.self, forKey: .appMatchers)
        inputPolicies = try container.decodeIfPresent([InputPolicy].self, forKey: .inputPolicies) ?? []
        axUnreliable = try container.decodeIfPresent(Bool.self, forKey: .axUnreliable) ?? false
        keysFollowPointer = try container.decodeIfPresent(Bool.self, forKey: .keysFollowPointer) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case appMatchers, inputPolicies, axUnreliable, keysFollowPointer
    }
}

/// One per-app cheat sheet: markdown instructions for the agent's prompt plus
/// the runtime hints above. Matched against the frontmost app at use time.
public struct AppSkill: Sendable {
    public let name: String
    public let description: String
    /// "user" (App Support/Cascade/Skills) or "bundled" (app resources).
    public let source: String
    public let path: String
    public let markdown: String
    public let hints: AppSkillRuntimeHints
    /// The markdown body with frontmatter and the hints fence stripped — what
    /// gets injected into the agent's prompt.
    public let instructions: String

    public var axUnreliable: Bool { hints.axUnreliable }
    public var keysFollowPointer: Bool { hints.keysFollowPointer }

    public var promptBlock: String {
        "App skill: \(name) — follow these instructions while working in this app:\n\(instructions)"
    }

    public func matches(appName: String?, bundleIdentifier: String?) -> Bool {
        guard let matchers = hints.appMatchers else { return false }
        let normalizedBundle = (bundleIdentifier ?? "").lowercased()
        if !normalizedBundle.isEmpty,
           matchers.bundleIdentifiers.contains(where: { normalizedBundle == $0.lowercased() }) {
            return true
        }
        let normalizedName = Self.normalized(appName ?? "")
        guard !normalizedName.isEmpty else { return false }
        return matchers.names.contains {
            let matcher = Self.normalized($0)
            return !matcher.isEmpty && normalizedName.contains(matcher)
        }
    }

    /// True when an input policy says this text must be delivered as physical
    /// key events (Blender-style modal numeric input that ignores AX insertion
    /// and clipboard paste).
    public func shouldTypePhysicalKeys(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return hints.inputPolicies.contains { policy in
            guard policy.kind == "numericModalText", policy.delivery == "physicalKeys" else { return false }
            if let maxLength = policy.maxLength, trimmed.count > maxLength { return false }
            if let allowed = policy.characters {
                let allowedSet = CharacterSet(charactersIn: allowed)
                guard trimmed.rangeOfCharacter(from: allowedSet.inverted) == nil else { return false }
            }
            return trimmed.rangeOfCharacter(from: .decimalDigits) != nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Loads SKILL.md files once at startup. User skills override bundled ones of
/// the same name. A plain value type — hold it as a `let` and query per use.
public struct AppSkillRegistry: Sendable {
    public let skills: [AppSkill]

    public init(skills: [AppSkill] = []) {
        self.skills = skills
    }

    public static func load(fileManager: FileManager = .default) -> AppSkillRegistry {
        var roots: [(url: URL, source: String)] = []
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        roots.append((
            appSupport.appendingPathComponent("Cascade", isDirectory: true)
                .appendingPathComponent("Skills", isDirectory: true),
            "user"
        ))
        if let bundled = Bundle.module.resourceURL?.appendingPathComponent("Skills", isDirectory: true) {
            roots.append((bundled, "bundled"))
        }
        return load(roots: roots, fileManager: fileManager)
    }

    public func skill(appName: String?, bundleIdentifier: String?) -> AppSkill? {
        skills.first { $0.matches(appName: appName, bundleIdentifier: bundleIdentifier) }
    }

    /// Maps modal numeric text to the key names the actuator's keymap accepts,
    /// one key per character. Returns nil if ANY character is unmappable so a
    /// partially typed value never reaches the app.
    public static func physicalKeySequence(for text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var keys: [String] = []
        for character in trimmed {
            switch character {
            case "0"..."9": keys.append(String(character))
            case ".": keys.append("period")
            case "-": keys.append("minus")
            default: return nil
            }
        }
        return keys
    }

    static func load(roots: [(url: URL, source: String)], fileManager: FileManager) -> AppSkillRegistry {
        var loaded: [AppSkill] = []
        var seenNames = Set<String>()
        for root in roots {
            guard fileManager.fileExists(atPath: root.url.path) else { continue }
            for url in skillFileURLs(in: root.url, fileManager: fileManager) {
                guard let markdown = try? String(contentsOf: url, encoding: .utf8),
                      let skill = parseSkill(markdown: markdown, path: url.path, source: root.source) else { continue }
                guard seenNames.insert(skill.name.lowercased()).inserted else { continue }
                loaded.append(skill)
            }
        }
        return AppSkillRegistry(skills: loaded)
    }

    static func parseSkill(markdown: String, path: String, source: String) -> AppSkill? {
        guard let hintsJSON = fencedRuntimeHints(in: markdown),
              let hintsData = hintsJSON.data(using: .utf8),
              let hints = try? JSONDecoder().decode(AppSkillRuntimeHints.self, from: hintsData) else {
            return nil
        }
        let metadata = frontMatter(in: markdown)
        let fallbackName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return AppSkill(
            name: metadata["name"] ?? fallbackName,
            description: metadata["description"] ?? "",
            source: source,
            path: path,
            markdown: markdown,
            hints: hints,
            instructions: strippedInstructions(from: markdown)
        )
    }

    static func fencedRuntimeHints(in markdown: String) -> String? {
        for fence in ["cascade-runtime-hints", "tiptour-runtime-hints"] {
            if let body = fencedCodeBlock(named: fence, in: markdown) { return body }
        }
        return nil
    }

    static func frontMatter(in markdown: String) -> [String: String] {
        guard markdown.hasPrefix("---\n"),
              let endRange = markdown.range(
                  of: "\n---",
                  range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex
              ) else {
            return [:]
        }
        let block = markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<endRange.lowerBound]
        var metadata: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            metadata[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return metadata
    }

    /// Markdown minus the frontmatter block and the entire hints fence.
    static func strippedInstructions(from markdown: String) -> String {
        var body = markdown
        if body.hasPrefix("---\n"),
           let endRange = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            var cutoff = endRange.upperBound
            if let newline = body.range(of: "\n", range: cutoff..<body.endIndex) {
                cutoff = newline.upperBound
            }
            body = String(body[cutoff...])
        }
        for fence in ["cascade-runtime-hints", "tiptour-runtime-hints"] {
            guard let startRange = body.range(of: "```\(fence)"),
                  let endRange = body.range(of: "\n```", range: startRange.upperBound..<body.endIndex) else { continue }
            body.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fencedCodeBlock(named blockName: String, in markdown: String) -> String? {
        guard let startRange = markdown.range(of: "```\(blockName)"),
              let newlineRange = markdown.range(of: "\n", range: startRange.upperBound..<markdown.endIndex),
              let endRange = markdown.range(of: "\n```", range: newlineRange.upperBound..<markdown.endIndex) else {
            return nil
        }
        return String(markdown[newlineRange.upperBound..<endRange.lowerBound])
    }

    private static func skillFileURLs(in root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.lowercased() == "skill.md" }
            .sorted { $0.path < $1.path }
    }
}
