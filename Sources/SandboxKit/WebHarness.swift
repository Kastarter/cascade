import Foundation
import ProviderKit

@MainActor
public final class WebHarnessPolicyContext {
    private let trustedTokens: Set<String>
    private var latestListedLabels: Set<String> = []

    public init(originalTask: String, subtask: String? = nil) {
        let combined = [originalTask, subtask].compactMap { $0 }.joined(separator: " ")
        self.trustedTokens = Set(Self.tokens(in: combined))
    }

    func rememberListedLabels(_ labels: [String]) {
        latestListedLabels = Set(labels.map(Self.normalizedLabel).filter { !$0.isEmpty })
    }

    func relevantTokens() -> Set<String> {
        trustedTokens
    }

    func validationFailure(forTarget target: String, kind: String, allowsNavigationField: Bool = false) -> String? {
        let cleaned = Self.sanitizedVisibleText(target)
        guard !cleaned.isEmpty else { return "\(kind) needs a non-empty target." }
        if Self.isControlHeavy(target) {
            return "\(kind) target contains hidden/control characters, so it was refused."
        }
        let analysis = InjectionGuard.analyze(cleaned)
        guard analysis.score == 0 else {
            return "\(kind) target was refused because it looks like page-provided instructions, not a safe element label."
        }
        let normalized = Self.normalizedLabel(cleaned)
        if latestListedLabels.contains(normalized) || latestListedLabels.contains(where: { $0.contains(normalized) || normalized.contains($0) }) {
            return nil
        }
        if allowsNavigationField, Self.isNavigationOrSearchField(normalized) {
            return nil
        }
        if trustedTokens.contains(where: { normalized.contains($0) }) {
            return nil
        }
        return "\(kind) target must match a recently listed page label or the trusted task wording. Call list_interactives again and use an exact label."
    }

    func validationFailure(forValue value: String, kind: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "\(kind) needs a non-empty value." }
        if Self.isControlHeavy(value) {
            return "\(kind) value contains hidden/control characters, so it was refused."
        }
        let analysis = InjectionGuard.analyze(cleaned)
        guard analysis.score == 0 else {
            return "\(kind) value was refused because it looks like instructions for the agent rather than form data."
        }
        return nil
    }

    static func tokens(in text: String) -> [String] {
        InjectionGuard.normalizedForDetection(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    static func normalizedLabel(_ text: String) -> String {
        sanitizedVisibleText(text)
            .replacingOccurrences(of: #"^\d+\.\s*\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func sanitizedVisibleText(_ text: String, limit: Int = 160) -> String {
        let cleaned = text.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
                return " "
            }
            if CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}").contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(limit))
    }

    static func isControlHeavy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let suspicious = text.unicodeScalars.filter { scalar in
            CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}").contains(scalar)
                || (CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t")
        }.count
        return suspicious >= 2 || (suspicious > 0 && text.unicodeScalars.count < 12)
    }

    private static func isNavigationOrSearchField(_ normalized: String) -> Bool {
        ["search", "query", "find", "url", "address", "location"].contains { normalized.contains($0) }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "onto", "what",
        "where", "when", "how", "use", "get", "find", "open", "click", "fill", "type"
    ]
}

/// The web analog of the Mac `AgentHarness`: instant DOM tools the background web
/// agent calls instead of poking pixel coordinates. They resolve in-process (no
/// screenshot round-trip), so reading content and clicking/filling named controls
/// is fast + reliable — the "harnessed like the cursor agent" half for the sandbox.
public enum WebHarness {
    /// Tool definitions handed to `ComputerUseAgent(extraTools:)`. Routed back to
    /// `run(_:_:sandbox:)` via the agent's `harnessProvider`. A func (not a stored
    /// static) because `[[String: Any]]` isn't Sendable.
    public static func toolDefinitions() -> [[String: Any]] {[
        StableToolDefinition.strict([
            "name": "read_page",
            "description": "Read the current page's title, URL, and visible text instantly — no screenshot. Use this to read content (prices, names, results, confirmations) rather than relying on the screenshot.",
            "input_schema": ["type": "object", "properties": [:]] as [String: Any],
        ], examples: [[:]]),
        StableToolDefinition.strict([
            "name": "list_interactives",
            "description": "List the page's visible clickable + fillable elements (links, buttons, inputs) with their labels, instantly. Use it to discover what you can click or fill, then act with click_text / fill_field.",
            "input_schema": ["type": "object", "properties": [:]] as [String: Any],
        ], examples: [[:]]),
        StableToolDefinition.strict([
            "name": "click_text",
            "description": "Click the element whose visible label best matches `text` (a link, button, or control). Instant + reliable — PREFER this over clicking pixel coordinates.",
            "input_schema": [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "the element's visible text / label"]],
                "required": ["text"],
            ] as [String: Any],
        ], examples: [["text": "Sign in"]]),
        StableToolDefinition.strict([
            "name": "fill_field",
            "description": "Type `value` into the input or textarea whose label, placeholder, or name best matches `field` (or the only field on the page). Instant — PREFER over clicking then typing.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "field": ["type": "string", "description": "the field's label / placeholder / name"],
                    "value": ["type": "string", "description": "what to type"],
                ],
                "required": ["field", "value"],
            ] as [String: Any],
        ], examples: [["field": "Search", "value": "Cascade"]]),
    ]}

    public static let toolNames: Set<String> = ["read_page", "list_interactives", "click_text", "fill_field"]

    /// Executes one DOM tool against `sandbox`, returning the result text the model
    /// sees as the tool_result.
    @MainActor
    public static func run(
        _ name: String,
        _ input: [String: Any],
        sandbox: WebSandbox,
        policyContext: WebHarnessPolicyContext? = nil
    ) async -> String {
        switch name {
        case "read_page":
            let raw = await sandbox.readPageText()
            guard !raw.hasPrefix("Couldn't read") else {
                return status(.error, tool: "read_page", kind: "read_failed", message: raw)
            }
            let minimized = minimizedPageText(raw, currentURL: sandbox.currentURL, title: sandbox.title, policyContext: policyContext)
            return InjectionGuard.renderEnvelope(
                trust: .untrustedWebDOM,
                source: sandbox.currentURL.isEmpty ? "web sandbox" : sandbox.currentURL,
                acquiredByTool: "read_page",
                payload: minimized
            )
        case "list_interactives":
            let raw = await sandbox.listInteractives()
            let minimized = minimizedInteractives(raw, policyContext: policyContext)
            return InjectionGuard.renderEnvelope(
                trust: .untrustedWebDOM,
                source: sandbox.currentURL.isEmpty ? "web sandbox" : sandbox.currentURL,
                acquiredByTool: "list_interactives",
                payload: minimized
            )
        case "click_text":
            guard let text = input["text"] as? String, !text.isEmpty else {
                return status(.error, tool: "click_text", kind: "validation_error", message: "click_text needs a non-empty \"text\".")
            }
            if let failure = policyContext?.validationFailure(forTarget: text, kind: "click_text") {
                return status(.refused, tool: "click_text", kind: "policy_refusal", message: failure)
            }
            return await sandbox.clickByText(text)
        case "fill_field":
            guard let field = input["field"] as? String, let value = input["value"] as? String else {
                return status(.error, tool: "fill_field", kind: "validation_error", message: "fill_field needs \"field\" and \"value\".")
            }
            if let failure = policyContext?.validationFailure(forTarget: field, kind: "fill_field", allowsNavigationField: true) {
                return status(.refused, tool: "fill_field", kind: "policy_refusal", message: failure)
            }
            if let failure = policyContext?.validationFailure(forValue: value, kind: "fill_field") {
                return status(.refused, tool: "fill_field", kind: "policy_refusal", message: failure)
            }
            return await sandbox.fillField(field, value: value)
        default:
            return status(.error, tool: name, kind: "unknown_tool", message: "Unknown web tool \(name).")
        }
    }

    @MainActor
    static func minimizedPageText(
        _ raw: String,
        currentURL: String,
        title: String,
        policyContext: WebHarnessPolicyContext?
    ) -> String {
        let lines = raw.components(separatedBy: .newlines)
        let parsedTitle = lines.first { $0.hasPrefix("TITLE: ") }?.dropFirst("TITLE: ".count)
        let parsedURL = lines.first { $0.hasPrefix("URL: ") }?.dropFirst("URL: ".count)
        let visible = lines.dropFirst(2)
            .map { WebHarnessPolicyContext.sanitizedVisibleText(String($0), limit: 500) }
            .filter { !$0.isEmpty && !isBoilerplate($0) }
        let deduped = dedupeAdjacent(visible)
        let tokens = policyContext?.relevantTokens() ?? []
        let relevant = tokens.isEmpty ? [] : deduped.filter { line in
            let normalized = InjectionGuard.normalizedForDetection(line)
            return tokens.contains(where: { normalized.contains($0) })
        }
        let body = boundedLines(relevant.isEmpty ? deduped : relevant, maxLines: relevant.isEmpty ? 28 : 36, maxChars: 3_200)
        return [
            "TITLE: \(parsedTitle.map(String.init) ?? title)",
            "URL: \(parsedURL.map(String.init) ?? currentURL)",
            "",
            "VISIBLE_TEXT:",
            body.isEmpty ? "(no visible text)" : body,
        ].joined(separator: "\n")
    }

    @MainActor
    static func minimizedInteractives(_ raw: String, policyContext: WebHarnessPolicyContext?) -> String {
        guard !raw.hasPrefix("Couldn't"), !raw.hasPrefix("No interactive") else {
            policyContext?.rememberListedLabels([])
            return raw
        }
        let limits = ["field": 24, "button": 24, "link": 32]
        var counts: [String: Int] = [:]
        var output: [String] = []
        var safeLabels: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            guard let item = parseInteractiveLine(line) else { continue }
            let role = item.role
            let limit = limits[role] ?? 16
            guard (counts[role] ?? 0) < limit else { continue }
            counts[role, default: 0] += 1
            let label = WebHarnessPolicyContext.sanitizedVisibleText(item.label, limit: 96)
            let analysis = InjectionGuard.analyze(label)
            let prefix = "\(output.count + 1). [\(role)] "
            if analysis.score >= 4 {
                output.append(prefix + "[label suppressed: suspicious page text]")
                continue
            }
            if analysis.score > 0 {
                output.append(prefix + "\(label) [suspicious label]")
                continue
            }
            let rendered = label.isEmpty ? "(unlabeled \(role))" : label
            output.append(prefix + rendered)
            safeLabels.append(rendered)
        }
        policyContext?.rememberListedLabels(safeLabels)
        return output.isEmpty ? "No safe interactive elements found." : output.joined(separator: "\n")
    }

    private static func parseInteractiveLine(_ line: String) -> (role: String, label: String)? {
        guard let match = line.range(of: #"^\s*\d+\.\s*\[(field|link|button)\]\s*(.*)$"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(line[match])
        guard let roleRange = matched.range(of: #"\[(field|link|button)\]"#, options: .regularExpression) else {
            return nil
        }
        let role = matched[roleRange].dropFirst().dropLast()
        let label = matched[roleRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(role), label)
    }

    private static func dedupeAdjacent(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines where result.last != line {
            result.append(line)
        }
        return result
    }

    private static func boundedLines(_ lines: [String], maxLines: Int, maxChars: Int) -> String {
        var output: [String] = []
        var total = 0
        for line in lines.prefix(maxLines) {
            let next = total + line.count + 1
            if next > maxChars { break }
            output.append(line)
            total = next
        }
        if output.count < lines.count { output.append("...[truncated]") }
        return output.joined(separator: "\n")
    }

    private static func isBoilerplate(_ line: String) -> Bool {
        let normalized = InjectionGuard.normalizedForDetection(line)
        let phrases = [
            "accept cookies", "privacy policy", "terms of service", "all rights reserved",
            "subscribe to our newsletter", "advertisement", "skip to content"
        ]
        return normalized.count < 2 || phrases.contains { normalized.contains($0) }
    }

    private static func status(
        _ status: ToolResultStatusEnvelope.Status,
        tool: String,
        kind: String,
        message: String
    ) -> String {
        ToolResultStatusEnvelope.render(status, kind: kind, message: message, tool: tool)
    }
}
