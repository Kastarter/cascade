import CascadeMemory
import Foundation

public enum SourceIntent: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case locateVisible = "locate_visible"
    case answerRecord = "answer_record"
    case findFile = "find_file"
    case webFact = "web_fact"
    case instructionalWithRecordDependency = "instructional_with_record_dependency"
    case action
    case mixed
    case ambiguous
    case noSearch = "no_search"

    public static func normalized(_ raw: String?) -> SourceIntent? {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch value {
        case "locatevisible", "locate_visible", "onscreen", "on_screen", "screen", "visible", "current_screen":
            return .locateVisible
        case "answerrecord", "answer_record", "recordedmemory", "recorded_memory", "memory", "recall", "record":
            return .answerRecord
        case "findfile", "find_file", "localfiles", "local_files", "files", "file", "folder", "spotlight":
            return .findFile
        case "webfact", "web_fact", "web", "internet", "browser", "online":
            return .webFact
        case "instructionalwithrecorddependency", "instructional_with_record_dependency", "instructional_record", "record_instructional":
            return .instructionalWithRecordDependency
        case "action", "act", "do", "execute":
            return .action
        case "mixed", "multi", "multiple", "multi_source", "multi-source":
            return .mixed
        case "ambiguous", "unknown", "unclear":
            return .ambiguous
        case "none", "no_search", "nosearch", "no_retrieval":
            return .noSearch
        default:
            return nil
        }
    }
}

public extension SourceIntent {
    static let onScreen: SourceIntent = .locateVisible
    static let recordedMemory: SourceIntent = .answerRecord
    static let localFiles: SourceIntent = .findFile
    static let web: SourceIntent = .webFact
    static let multi: SourceIntent = .mixed
}

public enum SourceID: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case onScreen
    case recordedMemory
    case localFiles
    case web
    case action

    public static func normalized(_ raw: String?) -> SourceID? {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch value {
        case "onscreen", "on_screen", "screen", "visible", "current_screen":
            return .onScreen
        case "recordedmemory", "recorded_memory", "memory", "recall", "record":
            return .recordedMemory
        case "localfiles", "local_files", "files", "file", "folder", "spotlight":
            return .localFiles
        case "web", "internet", "browser", "online":
            return .web
        case "action", "computer", "mac", "act":
            return .action
        default:
            return nil
        }
    }
}

public enum SourceEscalationPolicy: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case none
    case ordered
    case webIfUnsupported = "web_if_unsupported"
    case askUser = "ask_user"

    public static func normalized(_ raw: String?) -> SourceEscalationPolicy? {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch value {
        case "none", "no", "never":
            return .none
        case "ordered", "next", "fallback":
            return .ordered
        case "web_if_unsupported", "webifunsupported", "web", "escalate_web":
            return .webIfUnsupported
        case "ask_user", "ask", "confirm":
            return .askUser
        default:
            return nil
        }
    }
}

public enum SourceStopPolicy: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case firstSupported = "first_supported"
    case requireRequiredSource = "require_required_source"
    case checkAll = "check_all"

    public static func normalized(_ raw: String?) -> SourceStopPolicy? {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch value {
        case "first_supported", "firstsupported", "first", "supported":
            return .firstSupported
        case "require_required_source", "required", "require_required", "must_check_required":
            return .requireRequiredSource
        case "check_all", "all", "exhaustive":
            return .checkAll
        default:
            return nil
        }
    }
}

public struct SourcePlan: Sendable, Equatable, Codable {
    public let routingIntent: SourceIntent
    public let candidateSources: [SourceID]
    public let cleanQuery: String
    public let reason: String
    public let requiredSource: SourceID?
    public let escalationPolicy: SourceEscalationPolicy
    public let stopPolicy: SourceStopPolicy

    public init(
        routingIntent: SourceIntent,
        candidateSources: [SourceID],
        cleanQuery: String,
        reason: String = "",
        requiredSource: SourceID? = nil,
        escalationPolicy: SourceEscalationPolicy = .ordered,
        stopPolicy: SourceStopPolicy = .firstSupported
    ) {
        self.routingIntent = routingIntent
        self.candidateSources = Self.dedup(candidateSources)
        self.cleanQuery = cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requiredSource = requiredSource
        self.escalationPolicy = escalationPolicy
        self.stopPolicy = stopPolicy
    }

    public var allowsWeb: Bool {
        candidateSources.contains(.web) || routingIntent == .webFact || routingIntent == .mixed
    }

    public var usesCheapLocalSources: Bool {
        candidateSources.contains(.recordedMemory) || candidateSources.contains(.localFiles)
    }

    private static func dedup(_ sources: [SourceID]) -> [SourceID] {
        var seen = Set<SourceID>()
        var output: [SourceID] = []
        for source in sources where seen.insert(source).inserted {
            output.append(source)
        }
        return output
    }

    private enum CodingKeys: String, CodingKey {
        case routingIntent
        case candidateSources
        case cleanQuery
        case reason
        case requiredSource
        case escalationPolicy
        case stopPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawIntent = try container.decodeIfPresent(String.self, forKey: .routingIntent)
        let routingIntent = SourceIntent.normalized(rawIntent) ?? .ambiguous
        let rawSources = try container.decodeIfPresent([String].self, forKey: .candidateSources) ?? []
        let candidateSources = rawSources.compactMap(SourceID.normalized)
        let cleanQuery = try container.decodeIfPresent(String.self, forKey: .cleanQuery) ?? ""
        let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        let requiredSource = SourceID.normalized(try container.decodeIfPresent(String.self, forKey: .requiredSource))
        let escalationPolicy = SourceEscalationPolicy.normalized(try container.decodeIfPresent(String.self, forKey: .escalationPolicy)) ?? .ordered
        let stopPolicy = SourceStopPolicy.normalized(try container.decodeIfPresent(String.self, forKey: .stopPolicy)) ?? .firstSupported
        self.init(
            routingIntent: routingIntent,
            candidateSources: candidateSources,
            cleanQuery: cleanQuery,
            reason: reason,
            requiredSource: requiredSource,
            escalationPolicy: escalationPolicy,
            stopPolicy: stopPolicy
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routingIntent.rawValue, forKey: .routingIntent)
        try container.encode(candidateSources.map(\.rawValue), forKey: .candidateSources)
        try container.encode(cleanQuery, forKey: .cleanQuery)
        if !reason.isEmpty { try container.encode(reason, forKey: .reason) }
        try container.encodeIfPresent(requiredSource?.rawValue, forKey: .requiredSource)
        try container.encode(escalationPolicy.rawValue, forKey: .escalationPolicy)
        try container.encode(stopPolicy.rawValue, forKey: .stopPolicy)
    }
}

public enum EvidenceState: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case notChecked = "not_checked"
    case checkedNoEvidence = "checked_no_evidence"
    case checkedSupported = "checked_supported"
    case checkedInsufficient = "checked_insufficient"
    case unavailable
    case refused

    public var hasSupport: Bool { self == .checkedSupported }
}

public struct SourceEvidence: Sendable, Equatable, Codable {
    public let source: SourceID
    public let state: EvidenceState
    public let tool: String?
    public let resultCount: Int
    public let citationIDs: [String]
    public let statusKind: String?
    public let contentHash: String
    public let contentCharCount: Int

    public init(
        source: SourceID,
        state: EvidenceState,
        tool: String? = nil,
        resultCount: Int = 0,
        citationIDs: [String] = [],
        statusKind: String? = nil,
        contentHash: String = AuditIdentity.hash(nil),
        contentCharCount: Int = 0
    ) {
        self.source = source
        self.state = state
        self.tool = tool
        self.resultCount = max(0, resultCount)
        self.citationIDs = citationIDs
        self.statusKind = statusKind
        self.contentHash = contentHash
        self.contentCharCount = max(0, contentCharCount)
    }

    public var hasEvidence: Bool { state.hasSupport }

    public var auditDescriptor: String {
        var parts = [
            "source=\(AuditIdentity.safeToken(source.rawValue))",
            "state=\(AuditIdentity.safeToken(state.rawValue))",
            "tool=\(AuditIdentity.safeToken(tool ?? "none"))",
            "resultCount=\(resultCount)",
            "citationCount=\(citationIDs.count)",
            "contentHash=\(contentHash)",
            "contentChars=\(contentCharCount)",
        ]
        if let statusKind {
            parts.append("statusKind=\(AuditIdentity.safeToken(statusKind))")
        }
        return parts.joined(separator: " ")
    }

    public static func notChecked(source: SourceID, tool: String? = nil) -> SourceEvidence {
        SourceEvidence(source: source, state: .notChecked, tool: tool)
    }

    public static func unavailable(source: SourceID, tool: String? = nil, statusKind: String? = nil) -> SourceEvidence {
        SourceEvidence(source: source, state: .unavailable, tool: tool, statusKind: statusKind)
    }

    public static func fromToolResult(
        _ result: String,
        source: SourceID,
        defaultTool: String? = nil
    ) -> SourceEvidence {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = ToolResultStatusEnvelope.parse(trimmed) {
            let state: EvidenceState
            switch parsed.status {
            case .noResult:
                state = .checkedNoEvidence
            case .refused:
                state = .refused
            case .error:
                state = .checkedInsufficient
            }
            return SourceEvidence(
                source: source,
                state: state,
                tool: parsed.tool ?? defaultTool,
                statusKind: parsed.kind,
                contentHash: AuditIdentity.hash(parsed.message),
                contentCharCount: parsed.message.count
            )
        }
        if let envelope = observationEnvelope(from: trimmed) {
            let citations = citationIDs(in: envelope.payload)
            return SourceEvidence(
                source: source,
                state: .checkedSupported,
                tool: defaultTool ?? envelope.acquiredByTool,
                resultCount: supportedItemCount(in: envelope.payload, citations: citations),
                citationIDs: citations,
                contentHash: AuditIdentity.hash(envelope.payload),
                contentCharCount: envelope.payload.count
            )
        }
        guard !trimmed.isEmpty else {
            return SourceEvidence(
                source: source,
                state: .checkedInsufficient,
                tool: defaultTool,
                statusKind: "empty_result"
            )
        }
        let citations = citationIDs(in: trimmed)
        return SourceEvidence(
            source: source,
            state: .checkedSupported,
            tool: defaultTool,
            resultCount: supportedItemCount(in: trimmed, citations: citations),
            citationIDs: citations,
            contentHash: AuditIdentity.hash(trimmed),
            contentCharCount: trimmed.count
        )
    }

    private static func observationEnvelope(from text: String) -> ObservationEnvelope? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ObservationEnvelope.self, from: data)
    }

    private static func citationIDs(in text: String) -> [String] {
        let pattern = #"\[#([0-9A-Za-z_-]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var ids: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let idRange = Range(match.range(at: 1), in: text) else { return }
            let id = String(text[idRange])
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    private static func supportedItemCount(in text: String, citations: [String]) -> Int {
        if !citations.isEmpty { return citations.count }
        let lines = text.split(whereSeparator: \.isNewline).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("…") && trimmed != "[truncated]"
        }
        return max(lines.count, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
    }
}

public enum SourceAvailability: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case available
    case unavailable
    case disabled
    case requiresOptIn = "requires_opt_in"
    case refused

    public var isUsable: Bool { self == .available }
}

public struct SourceCard: Sendable, Equatable, Codable {
    public let source: SourceID
    public let title: String
    public let scope: String
    public let freshness: String
    public let privacy: String
    public let cost: String
    public let toolNames: [String]
    public let evidenceSemantics: String
    public let failureModes: [String]
    public let positiveExamples: [String]
    public let negativeExamples: [String]
    public let availability: SourceAvailability

    public init(
        source: SourceID,
        title: String,
        scope: String,
        freshness: String,
        privacy: String,
        cost: String,
        toolNames: [String],
        evidenceSemantics: String,
        failureModes: [String],
        positiveExamples: [String],
        negativeExamples: [String],
        availability: SourceAvailability = .available
    ) {
        self.source = source
        self.title = title
        self.scope = scope
        self.freshness = freshness
        self.privacy = privacy
        self.cost = cost
        self.toolNames = toolNames
        self.evidenceSemantics = evidenceSemantics
        self.failureModes = failureModes
        self.positiveExamples = positiveExamples
        self.negativeExamples = negativeExamples
        self.availability = availability
    }

    public func withAvailability(_ availability: SourceAvailability) -> SourceCard {
        SourceCard(
            source: source,
            title: title,
            scope: scope,
            freshness: freshness,
            privacy: privacy,
            cost: cost,
            toolNames: toolNames,
            evidenceSemantics: evidenceSemantics,
            failureModes: failureModes,
            positiveExamples: positiveExamples,
            negativeExamples: negativeExamples,
            availability: availability
        )
    }
}

public enum SourceCardRegistry {
    public static let baseCards: [SourceCard] = [
        SourceCard(
            source: .onScreen,
            title: "On-screen state",
            scope: "What is visible or interactable in the current macOS session.",
            freshness: "Live at the moment the agent observes the screen.",
            privacy: "Screen-derived content remains local unless the user sends it to a model-backed tool.",
            cost: "Requires visual/AX observation and may require computer-use turns.",
            toolNames: ["computer", "observe_screen"],
            evidenceSemantics: "Supported only when the current UI contains the requested fact or target.",
            failureModes: ["The relevant item is hidden, scrolled away, or in another space.", "Visible text may be stale after navigation."],
            positiveExamples: ["What does this dialog say?", "Click the visible Export button."],
            negativeExamples: ["What did I read yesterday?", "Find a file by name on disk."]
        ),
        SourceCard(
            source: .recordedMemory,
            title: "Recorded memory",
            scope: "OCR, app, window, structured content, and sessions already captured by Cascade.",
            freshness: "Historical local record up to the last captured moment.",
            privacy: "Sensitive moments are filtered before recall returns any payload.",
            cost: "Cheap local lookup.",
            toolNames: ["search_record", "get_timeframe", "inspect_moment", "list_sessions"],
            evidenceSemantics: "No-result envelopes mean the record was checked and did not support the answer; cited [#id] rows mean support.",
            failureModes: ["Recording may have been paused.", "OCR may miss text or privacy rules may filter moments."],
            positiveExamples: ["What was the invoice I looked at this morning?", "Summarize the page I had open earlier."],
            negativeExamples: ["What is the current exchange rate?", "List files in Downloads."]
        ),
        SourceCard(
            source: .localFiles,
            title: "Local files",
            scope: "Files and folders reachable through the direct-Mac read-only harness.",
            freshness: "Current filesystem state.",
            privacy: "Protected paths and sensitive text are refused before content is returned.",
            cost: "Cheap local lookup; file reads are bounded.",
            toolNames: ["search_files", "list_folder", "read_file"],
            evidenceSemantics: "Paths or file envelopes mean support; no-match/missing/empty status envelopes mean checked without evidence.",
            failureModes: ["Spotlight may not index the file.", "Matches may be only in privacy-protected locations."],
            positiveExamples: ["Find the budget spreadsheet on my Mac.", "Read the README in this folder."],
            negativeExamples: ["What is visible in the current dialog?", "Who won today's game?"]
        ),
        SourceCard(
            source: .web,
            title: "Web",
            scope: "Public or account-accessible web pages through the browser sandbox.",
            freshness: "Current to the browser session and reachable sites.",
            privacy: "Web results may involve external network access.",
            cost: "More expensive and may require navigation/login.",
            toolNames: ["web_search", "browser"],
            evidenceSemantics: "Supported only by retrieved web page/search evidence, not by prior local no-result text.",
            failureModes: ["Network unavailable.", "Login, paywall, or robots restrictions block access."],
            positiveExamples: ["What is the latest release date?", "Check the current price online."],
            negativeExamples: ["What did I see earlier in Mail?", "Read a local private file."]
        ),
        SourceCard(
            source: .action,
            title: "Action",
            scope: "Tasks that change state or operate the user's Mac rather than search for evidence.",
            freshness: "Live at execution time.",
            privacy: "Action details must be audited with hashes/counts only.",
            cost: "May require supervised computer-use or power-harness approval.",
            toolNames: ["computer", "run_command", "run_applescript", "write_file"],
            evidenceSemantics: "Action sources produce completion/verification evidence, not answer evidence.",
            failureModes: ["Requires user confirmation.", "The target app or page may not be available."],
            positiveExamples: ["Create a calendar event.", "Rename these files."],
            negativeExamples: ["What did a past page say?", "Find a public fact online."]
        ),
    ]

    public static func card(for source: SourceID) -> SourceCard? {
        baseCards.first { $0.source == source }
    }

    public static func cards(
        harnessTier: HarnessTier = .readOnly,
        recallEnabled: Bool = true,
        includeWeb: Bool = true
    ) -> [SourceCard] {
        baseCards.compactMap { card in
            switch card.source {
            case .recordedMemory:
                return card.withAvailability(recallEnabled ? .available : .disabled)
            case .localFiles:
                return card.withAvailability(harnessTier == .off ? .disabled : .available)
            case .web:
                return includeWeb ? card : nil
            case .action:
                return card.withAvailability(harnessTier == .full ? .available : .requiresOptIn)
            case .onScreen:
                return card
            }
        }
    }

    public static func renderCatalog(
        harnessTier: HarnessTier = .readOnly,
        recallEnabled: Bool = true,
        includeWeb: Bool = true
    ) -> String {
        cards(harnessTier: harnessTier, recallEnabled: recallEnabled, includeWeb: includeWeb)
            .map { card in
                let tools = card.toolNames.isEmpty ? "none" : card.toolNames.joined(separator: ", ")
                return """
                - \(card.title) (\(card.source.rawValue)) [\(card.availability.rawValue)]: \(card.scope)
                  freshness: \(card.freshness)
                  privacy: \(card.privacy)
                  cost: \(card.cost)
                  tools: \(tools)
                  evidence: \(card.evidenceSemantics)
                  failure modes: \(card.failureModes.joined(separator: " | "))
                """
            }
            .joined(separator: "\n")
    }
}

public struct SourceRouter: Sendable {
    public enum Environment: String, Sendable, Equatable, Codable {
        case onScreen
        case webSandbox
    }

    public init() {}

    public func route(
        _ task: String,
        environment: Environment = .onScreen,
        conversationContext: String = "",
        availableSources: [SourceID]? = nil
    ) -> SourcePlan {
        let cleanQuery = Self.cleanSearchQuery(task)
        let haystack = " \(task.lowercased()) \(conversationContext.lowercased()) "
        let available = availableSources.map(Set.init) ?? Set(Self.defaultAvailableSources(for: environment))

        var sources: [SourceID] = []
        if Self.containsAny(Self.screenMarkers, in: haystack), available.contains(.onScreen) { sources.append(.onScreen) }
        if Self.containsAny(Self.recordMarkers, in: haystack), available.contains(.recordedMemory) { sources.append(.recordedMemory) }
        if Self.containsAny(Self.localFileMarkers, in: haystack), available.contains(.localFiles) { sources.append(.localFiles) }
        if Self.containsAny(Self.webMarkers, in: haystack) || environment == .webSandbox {
            if available.contains(.web) { sources.append(.web) }
        }
        if Self.containsAny(Self.actionMarkers, in: haystack), available.contains(.action) { sources.append(.action) }
        if sources.isEmpty {
            sources = Self.defaultAvailableSources(for: environment).filter { available.contains($0) && $0 != .action }
        }

        let intent: SourceIntent
        if sources.isEmpty {
            intent = .noSearch
        } else if sources.contains(.action) {
            intent = .action
        } else if sources.count > 1 {
            intent = .mixed
        } else {
            switch sources.first {
            case .onScreen:
                intent = .locateVisible
            case .recordedMemory:
                intent = .answerRecord
            case .localFiles:
                intent = .findFile
            case .web:
                intent = .webFact
            case .action:
                intent = .action
            case nil:
                intent = .noSearch
            }
        }

        let required = sources.count == 1 ? sources.first : nil
        return SourcePlan(
            routingIntent: intent,
            candidateSources: sources,
            cleanQuery: cleanQuery,
            reason: "heuristic",
            requiredSource: required,
            escalationPolicy: sources.contains(.web) ? .ordered : .webIfUnsupported,
            stopPolicy: .firstSupported
        )
    }

    public static func cleanSearchQuery(_ task: String) -> String {
        var query = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "find ", "look up ", "search for ", "search ", "show me ", "tell me ",
            "what is ", "what are ", "where is ", "where are ",
        ]
        let lower = query.lowercased()
        if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
            query.removeFirst(prefix.count)
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultAvailableSources(for environment: Environment) -> [SourceID] {
        switch environment {
        case .webSandbox:
            [.web, .recordedMemory, .localFiles]
        case .onScreen:
            [.onScreen, .recordedMemory, .localFiles, .web]
        }
    }

    private static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static let screenMarkers = [
        "on screen", "this screen", "this page", "visible", "what does this say",
        "summarize this", "read this",
    ]
    private static let recordMarkers = [
        " earlier", "this morning", "yesterday", "last week", "last time", "i had open",
        "i was reading", "i saw", "we saw", "remember", "history", "recorded", "timeline",
    ]
    private static let localFileMarkers = [
        " file", "folder", "desktop", "downloads", "documents", "finder", "on my mac",
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".csv", ".txt", ".md",
    ]
    private static let webMarkers = [
        "latest", "current", "today", "news", "weather", "stock", "price", "online",
        "internet", "website", "web", "google", "who is", "what is", "when is",
    ]
    private static let actionMarkers = [
        "click", "type", "open", "create", "send", "delete", "rename", "move", "update",
        "change", "schedule", "book", "fill", "submit",
    ]
}

public typealias SearchRoutingIntent = SourceIntent
public typealias SearchResource = SourceID
public typealias SearchRouteHint = SourcePlan
