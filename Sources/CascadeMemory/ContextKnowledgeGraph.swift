import CryptoKit
import Foundation

public struct ContextKnowledgeGraph: Codable, Equatable, Sendable {
    public struct Range: Codable, Equatable, Sendable {
        public let startMs: Int64
        public let endMs: Int64
        public let cutoffMs: Int64

        public init(startMs: Int64, endMs: Int64, cutoffMs: Int64) {
            self.startMs = startMs
            self.endMs = endMs
            self.cutoffMs = cutoffMs
        }

        private enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
            case cutoffMs = "cutoff_ms"
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let contextCount: Int
        public let maxContextID: Int64

        public init(contextCount: Int, maxContextID: Int64) {
            self.contextCount = contextCount
            self.maxContextID = maxContextID
        }

        private enum CodingKeys: String, CodingKey {
            case contextCount = "context_count"
            case maxContextID = "max_context_id"
        }
    }

    public let schemaVersion: Int
    public let partitionKey: String
    public let day: String
    public let range: Range
    public let source: Source
    public let summary: String
    public let nodes: [ContextKnowledgeGraphNode]
    public let edges: [ContextKnowledgeGraphEdge]
    public let observations: [ContextKnowledgeGraphObservation]

    public init(
        schemaVersion: Int,
        partitionKey: String,
        day: String,
        range: Range,
        source: Source,
        summary: String,
        nodes: [ContextKnowledgeGraphNode],
        edges: [ContextKnowledgeGraphEdge],
        observations: [ContextKnowledgeGraphObservation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.partitionKey = partitionKey
        self.day = day
        self.range = range
        self.source = source
        self.summary = summary
        self.nodes = nodes
        self.edges = edges
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case partitionKey = "partition_key"
        case day
        case range
        case source
        case summary
        case nodes
        case edges
        case observations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            partitionKey: try container.decode(String.self, forKey: .partitionKey),
            day: try container.decode(String.self, forKey: .day),
            range: try container.decode(Range.self, forKey: .range),
            source: try container.decode(Source.self, forKey: .source),
            summary: try container.decode(String.self, forKey: .summary),
            nodes: try container.decode([ContextKnowledgeGraphNode].self, forKey: .nodes),
            edges: try container.decode([ContextKnowledgeGraphEdge].self, forKey: .edges),
            observations: try container.decodeIfPresent(
                [ContextKnowledgeGraphObservation].self,
                forKey: .observations
            ) ?? []
        )
    }
}

/// Timestamped, session-linked source text retained after its recorded-context
/// row expires. Node summaries stay deliberately small for prompt readability;
/// these observations are the complete privacy-scrubbed searchable evidence.
public struct ContextKnowledgeGraphObservation: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let appID: String
    public let capturedAtMs: Int64
    public let text: String

    public init(
        id: String,
        sessionID: String,
        appID: String,
        capturedAtMs: Int64,
        text: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.appID = appID
        self.capturedAtMs = capturedAtMs
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case appID = "app_id"
        case capturedAtMs = "captured_at_ms"
        case text
    }
}

public struct ContextKnowledgeGraphNode: Codable, Equatable, Sendable {
    public enum NodeType: String, Codable, CaseIterable, Sendable {
        case app
        case window
        case document
        case session
        case entity
    }

    public let id: String
    public let type: NodeType
    public let subtype: String?
    public let label: String
    public let canonicalValue: String
    public let firstSeenMs: Int64
    public let lastSeenMs: Int64
    public let mentionCount: Int
    public let aliases: [String]
    public let keywords: [String]
    public let evidenceSnippets: [String]
    public let attributes: [String: String]

    public init(
        id: String,
        type: NodeType,
        subtype: String?,
        label: String,
        canonicalValue: String,
        firstSeenMs: Int64,
        lastSeenMs: Int64,
        mentionCount: Int,
        aliases: [String],
        keywords: [String],
        evidenceSnippets: [String],
        attributes: [String: String]
    ) {
        self.id = id
        self.type = type
        self.subtype = subtype
        self.label = label
        self.canonicalValue = canonicalValue
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
        self.mentionCount = mentionCount
        self.aliases = aliases
        self.keywords = keywords
        self.evidenceSnippets = evidenceSnippets
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case subtype
        case label
        case canonicalValue = "canonical_value"
        case firstSeenMs = "first_seen_ms"
        case lastSeenMs = "last_seen_ms"
        case mentionCount = "mention_count"
        case aliases
        case keywords
        case evidenceSnippets = "evidence_snippets"
        case attributes
    }
}

public struct ContextKnowledgeGraphEdge: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case temporalSuccession = "temporal_succession"
        case sessionMembership = "session_membership"
        case appDocumentCooccurrence = "app_document_cooccurrence"
    }

    public let from: String
    public let to: String
    public let kind: Kind
    public let weight: Int
    public let firstSeenMs: Int64
    public let lastSeenMs: Int64
    /// Exact source observations represented by this aggregated edge. Keeping
    /// these timestamps prevents recall from treating firstSeen...lastSeen as
    /// continuous presence when the same window appears, disappears, and later
    /// returns within one session.
    public let observedAtMs: [Int64]

    public init(
        from: String,
        to: String,
        kind: Kind,
        weight: Int,
        firstSeenMs: Int64,
        lastSeenMs: Int64,
        observedAtMs: [Int64] = []
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.weight = weight
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
        let observations = observedAtMs.isEmpty
            ? [firstSeenMs, lastSeenMs]
            : observedAtMs + [firstSeenMs, lastSeenMs]
        self.observedAtMs = Array(Set(observations)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case from
        case to
        case kind
        case weight
        case firstSeenMs = "first_seen_ms"
        case lastSeenMs = "last_seen_ms"
        case observedAtMs = "observed_at_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let firstSeenMs = try container.decode(Int64.self, forKey: .firstSeenMs)
        let lastSeenMs = try container.decode(Int64.self, forKey: .lastSeenMs)
        self.init(
            from: try container.decode(String.self, forKey: .from),
            to: try container.decode(String.self, forKey: .to),
            kind: try container.decode(Kind.self, forKey: .kind),
            weight: try container.decode(Int.self, forKey: .weight),
            firstSeenMs: firstSeenMs,
            lastSeenMs: lastSeenMs,
            observedAtMs: try container.decodeIfPresent([Int64].self, forKey: .observedAtMs) ?? []
        )
    }
}

public struct ContextKnowledgeGraphSearchHit: Equatable, Sendable {
    public let graph: ContextKnowledgeGraph
    public let snippet: String
    public let rank: Double

    public init(graph: ContextKnowledgeGraph, snippet: String, rank: Double) {
        self.graph = graph
        self.snippet = snippet
        self.rank = rank
    }
}

public struct ContextKnowledgeGraphCompactionResult: Equatable, Sendable {
    public let cutoff: Date
    public let graphsWritten: Int
    public let contextsCovered: Int
    public let frameReferencesCleared: Int
    public let filesDeleted: Int
    public let deletionFailures: Int
    public let isCaughtUp: Bool

    public init(
        cutoff: Date,
        graphsWritten: Int,
        contextsCovered: Int,
        frameReferencesCleared: Int,
        filesDeleted: Int,
        deletionFailures: Int,
        isCaughtUp: Bool
    ) {
        self.cutoff = cutoff
        self.graphsWritten = graphsWritten
        self.contextsCovered = contextsCovered
        self.frameReferencesCleared = frameReferencesCleared
        self.filesDeleted = filesDeleted
        self.deletionFailures = deletionFailures
        self.isCaughtUp = isCaughtUp
    }
}

internal enum ContextKnowledgeGraphBuilder {
    static let schemaVersion = 3
    private static let maxAliases = 12
    private static let maxKeywords = 16
    private static let maxEvidenceSnippets = 8
    private static let maxEvidenceCharacters = 240

    private struct NodeAccumulator {
        let id: String
        let type: ContextKnowledgeGraphNode.NodeType
        let subtype: String?
        var label: String
        var canonicalValue: String
        var firstSeenMs: Int64
        var lastSeenMs: Int64
        var mentionCount: Int
        var aliases: [String]
        var keywords: [String]
        var evidenceSnippets: [String]
        var attributes: [String: String]

        init(
            id: String,
            type: ContextKnowledgeGraphNode.NodeType,
            subtype: String?,
            label: String,
            canonicalValue: String,
            firstSeenMs: Int64,
            lastSeenMs: Int64,
            mentionCount: Int,
            aliases: [String],
            keywords: [String],
            evidenceSnippets: [String],
            attributes: [String: String]
        ) {
            self.id = id
            self.type = type
            self.subtype = subtype
            self.label = label
            self.canonicalValue = canonicalValue
            self.firstSeenMs = firstSeenMs
            self.lastSeenMs = lastSeenMs
            self.mentionCount = max(1, mentionCount)
            self.aliases = []
            self.keywords = []
            self.evidenceSnippets = []
            self.attributes = attributes
            mergeUnique(aliases, into: &self.aliases, limit: maxAliases)
            mergeUnique(keywords, into: &self.keywords, limit: maxKeywords)
            mergeUnique(evidenceSnippets, into: &self.evidenceSnippets, limit: maxEvidenceSnippets)
        }

        mutating func observe(
            label: String,
            aliases: [String],
            keywords: [String],
            evidence: [String],
            at milliseconds: Int64,
            count: Int = 1,
            attributes: [String: String] = [:]
        ) {
            if self.label.isEmpty || (!label.isEmpty && label.localizedStandardCompare(self.label) == .orderedAscending) {
                self.label = label
            }
            firstSeenMs = min(firstSeenMs, milliseconds)
            lastSeenMs = max(lastSeenMs, milliseconds)
            mentionCount += max(1, count)
            mergeUnique(aliases, into: &self.aliases, limit: maxAliases)
            mergeUnique(keywords, into: &self.keywords, limit: maxKeywords)
            mergeUnique(evidence, into: &self.evidenceSnippets, limit: maxEvidenceSnippets)
            for key in attributes.keys.sorted() where self.attributes[key] == nil {
                self.attributes[key] = attributes[key]
            }
        }

        var node: ContextKnowledgeGraphNode {
            ContextKnowledgeGraphNode(
                id: id,
                type: type,
                subtype: subtype,
                label: label,
                canonicalValue: canonicalValue,
                firstSeenMs: firstSeenMs,
                lastSeenMs: lastSeenMs,
                mentionCount: max(1, mentionCount),
                aliases: aliases.sorted(),
                keywords: keywords.sorted(),
                evidenceSnippets: evidenceSnippets.sorted(),
                attributes: attributes
            )
        }
    }

    private struct EdgeKey: Hashable {
        let from: String
        let to: String
        let kind: ContextKnowledgeGraphEdge.Kind
    }

    private struct EdgeAccumulator {
        let key: EdgeKey
        var weight: Int
        var firstSeenMs: Int64
        var lastSeenMs: Int64
        var observedAtMs: [Int64]

        mutating func observe(at milliseconds: Int64, weight: Int = 1) {
            self.weight += max(1, weight)
            firstSeenMs = min(firstSeenMs, milliseconds)
            lastSeenMs = max(lastSeenMs, milliseconds)
            observedAtMs.append(milliseconds)
        }

        var edge: ContextKnowledgeGraphEdge {
            ContextKnowledgeGraphEdge(
                from: key.from,
                to: key.to,
                kind: key.kind,
                weight: max(1, weight),
                firstSeenMs: firstSeenMs,
                lastSeenMs: lastSeenMs,
                observedAtMs: observedAtMs
            )
        }
    }

    static func build(
        day: String,
        contexts: [RecordedContext],
        cutoff: Date,
        partitionKey: String? = nil
    ) -> ContextKnowledgeGraph? {
        let ordered = contexts.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return $0.id < $1.id
        }
        guard let first = ordered.first, let last = ordered.last else { return nil }

        let visible = ordered.filter { !PrivacyRules.isSensitive($0) }
        let episodes = SessionSegmenter.segment(visible)
        let contextsByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        var sessionIDByContext: [Int64: String] = [:]
        var nodes: [String: NodeAccumulator] = [:]
        var edges: [EdgeKey: EdgeAccumulator] = [:]
        var observations: [ContextKnowledgeGraphObservation] = []
        var appMentionCache: [String: [WorkGraphMention]] = [:]

        for episode in episodes {
            let sessionID = "session:\(day):\(episode.id)"
            let sessionContexts = episode.momentIDs.compactMap { contextsByID[$0] }
            for contextID in episode.momentIDs { sessionIDByContext[contextID] = sessionID }
            let startMs = EventStoreLayout.capturedMilliseconds(for: episode.startedAt)
            let endMs = EventStoreLayout.capturedMilliseconds(for: episode.endedAt)
            let evidence = evidenceSnippets(from: sessionContexts)
            let terms = salientTerms(in: sessionContexts.flatMap { [$0.windowTitle, $0.ocrText] }.compactMap { $0 })
            let title = episode.title.map { "\(episode.appName) — \($0)" } ?? episode.appName
            let description = sessionDescription(
                appName: episode.appName,
                title: episode.title,
                startMs: startMs,
                endMs: endMs,
                terms: terms,
                evidence: evidence
            )
            nodes[sessionID] = NodeAccumulator(
                id: sessionID,
                type: .session,
                subtype: nil,
                label: title,
                canonicalValue: "\(day):\(episode.id)",
                firstSeenMs: startMs,
                lastSeenMs: endMs,
                mentionCount: max(1, episode.momentCount),
                aliases: [episode.appName, episode.title].compactMap { $0 },
                keywords: terms,
                evidenceSnippets: evidence,
                attributes: [
                    "app_name": episode.appName,
                    "bundle_identifier": episode.bundleIdentifier ?? "",
                    "context_count": String(episode.momentCount),
                    "description": description,
                    "end_ms": String(endMs),
                    "start_ms": String(startMs),
                ]
            )
        }

        for context in visible {
            let capturedMs = EventStoreLayout.capturedMilliseconds(for: context.capturedAt)
            let appCacheKey = "\(context.bundleIdentifier ?? "")|\(normalized(context.appName))"
            let shouldExtractApp = appMentionCache[appCacheKey] == nil
            var mentions = WorkGraphExtractor.mentions(in: context, includeApp: shouldExtractApp)
            if shouldExtractApp {
                appMentionCache[appCacheKey] = mentions.filter { $0.kind == .app }
            } else {
                mentions.insert(contentsOf: appMentionCache[appCacheKey] ?? [], at: 0)
            }
            let appMention = mentions.first { $0.kind == .app }
            let appCanonical = appMention?.canonicalValue
                ?? context.bundleIdentifier?.lowercased()
                ?? normalized(context.appName)
            let appID = "app:\(AuditIdentity.hash(appCanonical))"
            let sessionID = sessionIDByContext[context.id]
            var observedNodeIDs: Set<String> = []
            var appNodeIDs: Set<String> = []
            var documentNodeIDs: Set<String> = []

            if let sessionID {
                let text = durableEvidence(from: context)
                if !text.isEmpty {
                    observations.append(ContextKnowledgeGraphObservation(
                        id: "observation:\(context.id)",
                        sessionID: sessionID,
                        appID: appID,
                        capturedAtMs: capturedMs,
                        text: text
                    ))
                }
            }

            for mention in mentions {
                let identity = nodeIdentity(for: mention, appID: appID)
                let snippet = cleanEvidence(mention.evidence)
                let terms = salientTerms(in: [mention.displayName, mention.canonicalValue, snippet])
                let attributes = mentionAttributes(mention, context: context)
                if var existing = nodes[identity.id] {
                    existing.observe(
                        label: cleanLabel(mention.displayName),
                        aliases: mention.aliases.map(cleanLabel),
                        keywords: terms,
                        evidence: snippet.isEmpty ? [] : [snippet],
                        at: capturedMs,
                        attributes: attributes
                    )
                    nodes[identity.id] = existing
                } else {
                    nodes[identity.id] = NodeAccumulator(
                        id: identity.id,
                        type: identity.type,
                        subtype: identity.subtype,
                        label: cleanLabel(mention.displayName),
                        canonicalValue: mention.canonicalValue,
                        firstSeenMs: capturedMs,
                        lastSeenMs: capturedMs,
                        mentionCount: 1,
                        aliases: mention.aliases.map(cleanLabel),
                        keywords: terms,
                        evidenceSnippets: snippet.isEmpty ? [] : [snippet],
                        attributes: attributes
                    )
                }
                observedNodeIDs.insert(identity.id)
                if identity.type == .app { appNodeIDs.insert(identity.id) }
                if identity.type == .document { documentNodeIDs.insert(identity.id) }
            }

            if let sessionID {
                for nodeID in observedNodeIDs.sorted() {
                    observeEdge(
                        from: nodeID,
                        to: sessionID,
                        kind: .sessionMembership,
                        at: capturedMs,
                        edges: &edges
                    )
                }
            }
            for source in appNodeIDs.sorted() {
                for target in documentNodeIDs.sorted() {
                    observeEdge(
                        from: source,
                        to: target,
                        kind: .appDocumentCooccurrence,
                        at: capturedMs,
                        edges: &edges
                    )
                }
            }
        }

        let sessionNodes = nodes.values
            .filter { $0.type == .session }
            .sorted {
                if $0.firstSeenMs != $1.firstSeenMs { return $0.firstSeenMs < $1.firstSeenMs }
                return $0.id < $1.id
            }
        for pair in zip(sessionNodes, sessionNodes.dropFirst()) {
            observeEdge(
                from: pair.0.id,
                to: pair.1.id,
                kind: .temporalSuccession,
                at: pair.1.firstSeenMs,
                edges: &edges
            )
        }

        return makeGraph(
            partitionKey: partitionKey ?? "utc-day:\(day)",
            day: day,
            startMs: EventStoreLayout.capturedMilliseconds(for: first.capturedAt),
            endMs: EventStoreLayout.capturedMilliseconds(for: last.capturedAt),
            cutoffMs: EventStoreLayout.capturedMilliseconds(for: cutoff),
            contextCount: ordered.count,
            maxContextID: ordered.map(\.id).max() ?? 0,
            nodes: nodes.values.map(\.node),
            edges: edges.values.map(\.edge),
            observations: observations
        )
    }

    static func canonicalData(for graph: ContextKnowledgeGraph) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(graph)
    }

    static func sha256(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func searchText(for graph: ContextKnowledgeGraph) -> String {
        var summaryParts = [graph.summary]
        for node in graph.nodes {
            summaryParts.append(node.label)
            summaryParts.append(node.canonicalValue)
            summaryParts.append(contentsOf: node.aliases)
            summaryParts.append(contentsOf: node.keywords)
            summaryParts.append(contentsOf: node.evidenceSnippets)
            if node.type == .session, let description = node.attributes["description"] {
                summaryParts.append(description)
            }
        }
        let searchableEvidence = graph.observations.map(\.text).filter { !$0.isEmpty }
        let unique = stableUnique(summaryParts.map(cleanEvidence).filter { !$0.isEmpty } + searchableEvidence)
        return unique.joined(separator: "\n")
    }

    private static func makeGraph(
        partitionKey: String,
        day: String,
        startMs: Int64,
        endMs: Int64,
        cutoffMs: Int64,
        contextCount: Int,
        maxContextID: Int64,
        nodes: [ContextKnowledgeGraphNode],
        edges: [ContextKnowledgeGraphEdge],
        observations: [ContextKnowledgeGraphObservation]
    ) -> ContextKnowledgeGraph {
        let orderedNodes = nodes.sorted {
            if $0.type.rawValue != $1.type.rawValue { return $0.type.rawValue < $1.type.rawValue }
            return $0.id < $1.id
        }
        let orderedEdges = edges.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.to < $1.to
        }
        let orderedObservations = observations.sorted {
            if $0.capturedAtMs != $1.capturedAtMs { return $0.capturedAtMs < $1.capturedAtMs }
            return $0.id < $1.id
        }
        return ContextKnowledgeGraph(
            schemaVersion: schemaVersion,
            partitionKey: partitionKey,
            day: day,
            range: .init(startMs: startMs, endMs: endMs, cutoffMs: cutoffMs),
            source: .init(contextCount: contextCount, maxContextID: maxContextID),
            summary: summary(day: day, contextCount: contextCount, nodes: orderedNodes),
            nodes: orderedNodes,
            edges: orderedEdges,
            observations: orderedObservations
        )
    }

    private static func summary(
        day: String,
        contextCount: Int,
        nodes: [ContextKnowledgeGraphNode]
    ) -> String {
        let sessions = nodes.filter { $0.type == .session }.sorted { $0.firstSeenMs < $1.firstSeenMs }
        let apps = nodes.filter { $0.type == .app }
            .sorted {
                if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
                return $0.label < $1.label
            }
            .prefix(8)
            .map(\.label)
        let sessionDescriptions = sessions.prefix(12).compactMap { $0.attributes["description"] }
        var parts = ["\(day): \(contextCount) contexts across \(sessions.count) sessions."]
        if !apps.isEmpty { parts.append("Apps: \(apps.joined(separator: ", ")).") }
        if !sessionDescriptions.isEmpty { parts.append("Sessions: \(sessionDescriptions.joined(separator: " | "))") }
        return String(parts.joined(separator: " ").prefix(2_000))
    }

    private static func sessionDescription(
        appName: String,
        title: String?,
        startMs: Int64,
        endMs: Int64,
        terms: [String],
        evidence: [String]
    ) -> String {
        var description = "\(utcTime(startMs))–\(utcTime(endMs)) \(appName)"
        if let title, !title.isEmpty { description += " — \(title)" }
        if !terms.isEmpty { description += " · \(terms.prefix(8).joined(separator: ", "))" }
        if let first = evidence.first, !first.isEmpty { description += " · \(first)" }
        return String(description.prefix(560))
    }

    private static func nodeIdentity(
        for mention: WorkGraphMention,
        appID: String
    ) -> (id: String, type: ContextKnowledgeGraphNode.NodeType, subtype: String?) {
        switch mention.kind {
        case .app:
            return ("app:\(AuditIdentity.hash(mention.canonicalValue))", .app, nil)
        case .window:
            return ("window:\(AuditIdentity.hash("\(appID)|\(mention.canonicalValue)"))", .window, nil)
        case .url, .file, .folder:
            return (
                "document:\(mention.kind.rawValue):\(AuditIdentity.hash(mention.canonicalValue))",
                .document,
                mention.kind.rawValue
            )
        default:
            return (
                "entity:\(mention.kind.rawValue):\(AuditIdentity.hash(mention.canonicalValue))",
                .entity,
                mention.kind.rawValue
            )
        }
    }

    private static func mentionAttributes(
        _ mention: WorkGraphMention,
        context: RecordedContext
    ) -> [String: String] {
        var attributes = [
            "extractor": mention.source,
            "confidence": String(format: "%.3f", mention.confidence),
        ]
        if mention.kind == .app, let bundleIdentifier = context.bundleIdentifier {
            attributes["bundle_identifier"] = bundleIdentifier
        }
        if let piiClass = mention.piiClass { attributes["pii_class"] = piiClass }
        return attributes
    }

    private static func observeEdge(
        from: String,
        to: String,
        kind: ContextKnowledgeGraphEdge.Kind,
        at milliseconds: Int64,
        edges: inout [EdgeKey: EdgeAccumulator]
    ) {
        let key = EdgeKey(from: from, to: to, kind: kind)
        if var edge = edges[key] {
            edge.observe(at: milliseconds)
            edges[key] = edge
        } else {
            edges[key] = EdgeAccumulator(
                key: key,
                weight: 1,
                firstSeenMs: milliseconds,
                lastSeenMs: milliseconds,
                observedAtMs: [milliseconds]
            )
        }
    }

    private static func evidenceSnippets(from contexts: [RecordedContext]) -> [String] {
        var snippets: [String] = []
        for context in contexts {
            let candidates = [context.ocrText, context.windowTitle].compactMap { $0 }
            for candidate in candidates {
                let cleaned = cleanEvidence(candidate)
                guard !cleaned.isEmpty, !snippets.contains(cleaned) else { continue }
                snippets.append(cleaned)
                if snippets.count == maxEvidenceSnippets { return snippets }
            }
        }
        return snippets
    }

    private static func salientTerms(in values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values {
            let cleaned = cleanEvidence(value).lowercased()
            let tokens = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
            for token in tokens where token.count >= 3 && !keywordStopwords.contains(token) {
                counts[token, default: 0] += 1
            }
        }
        return counts.keys.sorted {
            if counts[$0] != counts[$1] { return counts[$0, default: 0] > counts[$1, default: 0] }
            return $0 < $1
        }.prefix(maxKeywords).map { $0 }
    }

    private static func cleanLabel(_ value: String) -> String {
        String(cleanEvidence(value).prefix(160))
    }

    private static func cleanEvidence(_ value: String) -> String {
        String(cleanDurableEvidence(value).prefix(maxEvidenceCharacters))
    }

    private static func durableEvidence(from context: RecordedContext) -> String {
        let values = [context.windowTitle, context.ocrText]
            .compactMap { $0 }
            .map(cleanDurableEvidence)
            .filter { !$0.isEmpty }
        return stableUnique(values).joined(separator: " · ")
    }

    private static func cleanDurableEvidence(_ value: String) -> String {
        let redactedPII = PIIDetector.redact(
            value,
            includeNames: false,
            highConfidenceOnly: false
        ).redacted
        let redacted = PrivacyRules.redactingSensitiveKeywords(in: redactedPII)
        let collapsed = redacted
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func utcTime(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: EventStoreLayout.date(fromCapturedMilliseconds: milliseconds))
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func mergeUnique(_ values: [String], into target: inout [String], limit: Int) {
        guard target.count < limit else { return }
        var seen = Set(target)
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            target.append(trimmed)
            if target.count == limit { break }
        }
    }

    private static let keywordStopwords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "before", "being", "between",
        "but", "can", "context", "contexts", "for", "from", "have", "into", "its", "more",
        "not", "only", "screen", "session", "sessions", "that", "the", "their", "then", "there",
        "these", "this", "through", "was", "were", "what", "when", "where", "which", "with", "you",
    ]
}
