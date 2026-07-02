import CascadeMemory
import CoreGraphics
import Foundation

// d10 (AX-first grounding): compressed planner observation (A11y-Compressor).
//
// The planner never sees the raw AX tree. What it saw until now was the flat
// `interactableSummary` line: every harvested control rendered inline with its
// full hint list (container repeated per item, subrole/source/sibling noise),
// which grows linearly with the surface and buries the task-relevant controls.
// This renderer produces the compressed observation the A11y-Compressor paper
// showed planners actually need (≈22% of the tokens, +5.1pp OSWorld): a
// bounded set of TASK-RELEVANT candidates, grouped by their structural
// container so shared hierarchy is stated once, each with a stable id, role,
// name, value, exact frame, supported actions, and an interaction modality.
// Selection is deterministic (goal-word relevance, then screen order), so the
// same screen + goal always renders the same observation.
//
// Default-off behind `cascade.experimentalCompressedObservation`; when the
// flag is off callers keep pushing the legacy summary unchanged. Audit rows
// carry token + candidate COUNTS only — never labels, values, or coordinates.
public enum AXCompressedObservation {
    public static let flagKey = "cascade.experimentalCompressedObservation"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Total candidates the observation may render. The harvest is already
    /// bounded (≤24/40); this trims further so an über-dense window can't
    /// flood the note — the pruned ones are exactly the least task-relevant.
    public static let defaultMaxCandidates = 20

    /// Per-group bound so one table/sidebar can't crowd out the other groups.
    public static let defaultMaxPerGroup = 8

    static let maxNameLength = 60
    static let maxValueLength = 40
    static let maxIdentifierLength = 40
    static let maxGroupLabelLength = 48
    static let shortIDLength = 8

    /// How the planner should interact with a control — derived from its AX
    /// role so the model stops guessing gestures (type into a field, toggle a
    /// checkbox, select a row) from pixels.
    public enum Modality: String, Sendable, Equatable, CaseIterable {
        case click
        case type
        case toggle
        case select
        case adjust
        case disclose
    }

    /// Counts-only accounting — safe to persist to `audit_event` verbatim
    /// (candidate/group/token counts, no labels, no values, no coordinates).
    public struct Metrics: Sendable, Equatable {
        public let inputCandidateCount: Int
        public let renderedCandidateCount: Int
        public let prunedCandidateCount: Int
        public let groupCount: Int
        public let taskRelevantCount: Int
        public let renderedCharacterCount: Int
        public let approximateTokenCount: Int
        public let baselineCharacterCount: Int
        public let baselineApproximateTokenCount: Int

        public init(
            inputCandidateCount: Int,
            renderedCandidateCount: Int,
            prunedCandidateCount: Int,
            groupCount: Int,
            taskRelevantCount: Int,
            renderedCharacterCount: Int,
            baselineCharacterCount: Int
        ) {
            self.inputCandidateCount = max(0, inputCandidateCount)
            self.renderedCandidateCount = max(0, renderedCandidateCount)
            self.prunedCandidateCount = max(0, prunedCandidateCount)
            self.groupCount = max(0, groupCount)
            self.taskRelevantCount = max(0, taskRelevantCount)
            self.renderedCharacterCount = max(0, renderedCharacterCount)
            self.approximateTokenCount = Self.approximateTokens(forCharacters: renderedCharacterCount)
            self.baselineCharacterCount = max(0, baselineCharacterCount)
            self.baselineApproximateTokenCount = Self.approximateTokens(forCharacters: baselineCharacterCount)
        }

        /// Chars/4 is the standard rough LLM-token estimate — good enough to
        /// track compression across turns without a tokenizer dependency.
        public static func approximateTokens(forCharacters count: Int) -> Int {
            count <= 0 ? 0 : (count + 3) / 4
        }

        public var safeAuditDetail: String {
            [
                "axObsCandidates=\(inputCandidateCount)",
                "axObsRendered=\(renderedCandidateCount)",
                "axObsPruned=\(prunedCandidateCount)",
                "axObsGroups=\(groupCount)",
                "axObsTaskRelevant=\(taskRelevantCount)",
                "axObsChars=\(renderedCharacterCount)",
                "axObsApproxTokens=\(approximateTokenCount)",
                "axObsBaselineChars=\(baselineCharacterCount)",
                "axObsBaselineApproxTokens=\(baselineApproximateTokenCount)",
            ].joined(separator: " ")
        }
    }

    public struct Rendering: Sendable, Equatable {
        public let text: String
        public let metrics: Metrics

        public init(text: String, metrics: Metrics) {
            self.text = text
            self.metrics = metrics
        }
    }

    // MARK: - Render

    /// Renders the compressed planner observation from one harvested control
    /// list (the SAME bounded harvest the legacy summary consumes — no extra
    /// AX traffic). `goal` drives task-relevance pruning; `baselineCharacterCount`
    /// is the legacy summary's size so the audit row shows the compression.
    /// nil when there is nothing to show (canvas/Electron surfaces).
    public static func render(
        matches: [AXElementResolver.Match],
        goal: String?,
        maxCandidates: Int = defaultMaxCandidates,
        maxPerGroup: Int = defaultMaxPerGroup,
        baselineCharacterCount: Int = 0
    ) -> Rendering? {
        guard !matches.isEmpty, maxCandidates > 0, maxPerGroup > 0 else { return nil }
        let goalWords = relevanceWords(fromGoal: goal)
        let items = matches.enumerated().map { index, match in
            Item(
                index: index,
                match: match,
                groupKey: groupKey(for: match),
                relevance: relevance(of: match, toGoalWords: goalWords)
            )
        }
        let selected = select(items: items, maxCandidates: maxCandidates, maxPerGroup: maxPerGroup)
        guard !selected.isEmpty else { return nil }

        // Display ids are computed over the RENDER order (grouped), so each
        // line pairs with its own id even when grouping interleaves items.
        let groups = groupedInEncounterOrder(selected)
        let renderOrder = groups.flatMap(\.items)
        let displayIDs = uniqueDisplayIDs(for: renderOrder.map(fullStableID))
        var lines: [String] = [
            "Controls on screen now — a compressed, grouped view of the app's real controls "
                + "(NOT everything; open a menu/panel to reveal more). Act on one by naming its "
                + "quoted name exactly; [ids] are stable references; frames are (x,y,w×h) in screen points:",
        ]
        var cursor = 0
        for group in groups {
            if let header = groupHeader(for: group.key) {
                lines.append(header)
            }
            for item in group.items {
                lines.append(renderLine(for: item, displayID: displayIDs[cursor]))
                cursor += 1
            }
        }
        let groupCount = groups.count
        let text = lines.joined(separator: "\n")
        let metrics = Metrics(
            inputCandidateCount: matches.count,
            renderedCandidateCount: selected.count,
            prunedCandidateCount: matches.count - selected.count,
            groupCount: groupCount,
            taskRelevantCount: items.filter { $0.relevance > 0 }.count,
            renderedCharacterCount: text.count,
            baselineCharacterCount: baselineCharacterCount
        )
        return Rendering(text: text, metrics: metrics)
    }

    // MARK: - Selection (pure, unit-tested)

    struct Item {
        let index: Int
        let match: AXElementResolver.Match
        let groupKey: String
        let relevance: Double
    }

    /// Deterministic task-relevant pruning: within each container keep the
    /// `maxPerGroup` most relevant controls (screen order breaks ties); when
    /// the survivors still exceed `maxCandidates`, keep the globally most
    /// relevant. Output preserves encounter order so the note reads like the
    /// screen. With no goal signal every relevance is 0 and this reduces to
    /// "first N per group, first `maxCandidates` overall" — pure truncation.
    static func select(items: [Item], maxCandidates: Int, maxPerGroup: Int) -> [Item] {
        var byGroup: [String: [Item]] = [:]
        var groupOrder: [String] = []
        for item in items {
            if byGroup[item.groupKey] == nil { groupOrder.append(item.groupKey) }
            byGroup[item.groupKey, default: []].append(item)
        }
        var survivors: [Item] = []
        for key in groupOrder {
            let group = byGroup[key] ?? []
            let kept = group
                .sorted { lhs, rhs in
                    if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
                    return lhs.index < rhs.index
                }
                .prefix(maxPerGroup)
            survivors.append(contentsOf: kept)
        }
        if survivors.count > maxCandidates {
            survivors = Array(
                survivors
                    .sorted { lhs, rhs in
                        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
                        return lhs.index < rhs.index
                    }
                    .prefix(maxCandidates)
            )
        }
        return survivors.sorted { $0.index < $1.index }
    }

    /// Goal words worth matching: normalized (same tolerant normalization the
    /// AX text matcher uses), stopwords and 1–2 letter words dropped.
    static func relevanceWords(fromGoal goal: String?) -> [String] {
        guard let goal, !goal.isEmpty else { return [] }
        return AXElementResolver.normalize(goal)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// Count of goal words that appear in the candidate's own text (label,
    /// value, identifier, container) — exact word match or a ≥4-char prefix
    /// relation so "notes" still hits "note". 0 means "not task-relevant".
    static func relevance(of match: AXElementResolver.Match, toGoalWords goalWords: [String]) -> Double {
        guard !goalWords.isEmpty else { return 0 }
        let descriptor = match.descriptor
        let node = match.actionableNode
        let haystack = [
            descriptor?.label ?? match.title,
            node?.value,
            node?.identifier ?? descriptor?.identifier,
            node?.axDescription,
            descriptor?.container,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let candidateWords = AXElementResolver.normalize(haystack)
            .split(separator: " ")
            .map(String.init)
        guard !candidateWords.isEmpty else { return 0 }
        var hits = 0
        for word in goalWords {
            let matched = candidateWords.contains { candidate in
                if candidate == word { return true }
                guard min(candidate.count, word.count) >= 4 else { return false }
                return candidate.hasPrefix(word) || word.hasPrefix(candidate)
            }
            if matched { hits += 1 }
        }
        return Double(hits)
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "into", "onto", "from", "then", "that",
        "this", "please", "you", "your", "its", "are", "was", "can", "has",
    ]

    // MARK: - Grouping (hierarchy)

    /// One container line per run of same-container controls — the hierarchy
    /// signal, stated once instead of per item like the legacy summary.
    static func groupKey(for match: AXElementResolver.Match) -> String {
        let descriptor = match.descriptor
        let raw = descriptor?.container
            ?? descriptor?.ancestorPath.last
            ?? ""
        return normalizeWhitespace(raw)
    }

    struct Group {
        let key: String
        let items: [Item]
    }

    static func groupedInEncounterOrder(_ items: [Item]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [Item]] = [:]
        for item in items {
            if byKey[item.groupKey] == nil { order.append(item.groupKey) }
            byKey[item.groupKey, default: []].append(item)
        }
        return order.map { Group(key: $0, items: byKey[$0] ?? []) }
    }

    static func groupHeader(for key: String) -> String? {
        guard !key.isEmpty else { return nil }
        return "▸ in \(String(key.prefix(maxGroupLabelLength))):"
    }

    // MARK: - Per-candidate line

    /// `[id] role “name” · modality(actions) · (x,y,w×h) · val “…” · state`
    /// — every field the planner needs to pick and act on a REAL control:
    /// stable id, role, name, value, exact frame, supported actions, modality.
    static func renderLine(for item: Item, displayID: String) -> String {
        let match = item.match
        let descriptor = match.descriptor
        let node = match.actionableNode
        let role = node?.role ?? descriptor?.role ?? match.role
        let name = normalizeWhitespace(descriptor?.label ?? match.title)
        var parts: [String] = []
        parts.append("[\(displayID)] \(shortRole(role)) “\(String(name.prefix(maxNameLength)))”")
        let actions = (node?.supportedActions ?? descriptor?.supportedActions ?? [])
            .prefix(4)
            .map(shortAction)
        let interaction = modality(role: role, supportedActions: node?.supportedActions ?? [])
        parts.append(actions.isEmpty ? interaction.rawValue : "\(interaction.rawValue)(\(actions.joined(separator: "/")))")
        if let frame = frameText(for: item) {
            parts.append(frame)
        }
        if let identifier = node?.identifier ?? descriptor?.identifier, !identifier.isEmpty {
            parts.append("id \(String(identifier.prefix(maxIdentifierLength)))")
        }
        if let value = node?.value.map(normalizeWhitespace), !value.isEmpty, value != name {
            parts.append("val “\(String(value.prefix(maxValueLength)))”")
        }
        if node?.enabled == false || descriptor?.enabled == false { parts.append("disabled") }
        if node?.selected == true || descriptor?.selected == true { parts.append("selected") }
        if node?.focused == true || descriptor?.focused == true { parts.append("focused") }
        return "  - " + parts.joined(separator: " · ")
    }

    public static func modality(role: String, supportedActions: [String]) -> Modality {
        switch role {
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox":
            return .type
        case "AXCheckBox", "AXRadioButton", "AXSwitch":
            return .toggle
        case "AXPopUpButton", "AXTab", "AXRow", "AXCell", "AXOutlineRow", "AXMenuItem", "AXMenuBarItem":
            return .select
        case "AXSlider", "AXIncrementor", "AXScrollBar":
            return .adjust
        case "AXDisclosureTriangle":
            return .disclose
        default:
            if supportedActions.contains("AXShowMenu"), !supportedActions.contains("AXPress") {
                return .select
            }
            return .click
        }
    }

    /// Exact frame as `(x,y,w×h)` integer points; falls back to the recorded
    /// descriptor frame string, then to the click center — never invented.
    static func frameText(for item: Item) -> String? {
        if let frame = item.match.frame {
            return "(\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded()))×\(Int(frame.height.rounded())))"
        }
        if let recorded = item.match.descriptor?.frame {
            let parts = recorded.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                return "(\(parts[0]),\(parts[1]),\(parts[2])×\(parts[3]))"
            }
        }
        let center = item.match.center
        return "(\(Int(center.x.rounded())),\(Int(center.y.rounded())) center)"
    }

    // MARK: - Stable ids

    static func fullStableID(for item: Item) -> String {
        if let node = item.match.actionableNode { return node.stableID }
        if let id = item.match.id, !id.isEmpty { return id }
        // Last-resort synthetic identity (a Match built without the d05
        // actionable-node capture): hash the same structural material the
        // resolver would have used, so the id is still deterministic.
        let material = [
            item.match.role,
            item.match.title,
            item.match.descriptor?.container ?? "",
        ].joined(separator: "|")
        return "ax:\(AuditIdentity.hash(material))"
    }

    /// Shortens `ax:<hash>` ids to 8 hash chars for the note, extending only
    /// the colliding ones — ids stay STABLE (prefix of the stable hash) and
    /// unique within one observation. True duplicates (the same full id twice)
    /// get a `#n` suffix so every rendered line stays addressable.
    static func uniqueDisplayIDs(for fullIDs: [String]) -> [String] {
        var lengths = Array(repeating: shortIDLength, count: fullIDs.count)
        var shortened = fullIDs.indices.map { shorten(fullIDs[$0], hashLength: lengths[$0]) }
        var changed = true
        while changed {
            changed = false
            var groups: [String: [Int]] = [:]
            for (index, id) in shortened.enumerated() {
                groups[id, default: []].append(index)
            }
            for indices in groups.values where indices.count > 1 {
                for index in indices where canExtend(shortened[index], beyond: lengths[index]) {
                    lengths[index] += 4
                    shortened[index] = shorten(fullIDs[index], hashLength: lengths[index])
                    changed = true
                }
            }
        }
        var seen = Set<String>()
        var deduped: [String] = []
        for id in shortened {
            var candidate = id
            var suffix = 2
            while seen.contains(candidate) {
                candidate = "\(id)#\(suffix)"
                suffix += 1
            }
            seen.insert(candidate)
            deduped.append(candidate)
        }
        return deduped
    }

    private static func shorten(_ fullID: String, hashLength: Int) -> String {
        guard fullID.hasPrefix("ax:") else { return String(fullID.prefix(hashLength + 3)) }
        let hash = fullID.dropFirst(3)
        return "ax:\(hash.prefix(hashLength))"
    }

    private static func canExtend(_ shortened: String, beyond length: Int) -> Bool {
        shortened.count >= length + 3
    }

    // MARK: - Small formatting helpers

    static func shortRole(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    }

    static func shortAction(_ action: String) -> String {
        var name = action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
        if name.hasSuffix("Action") {
            name = String(name.dropLast("Action".count))
        }
        return name.lowercased()
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
