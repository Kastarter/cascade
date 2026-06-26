import Foundation
import SQLite3

public enum WorkGraphEntityKind: String, CaseIterable, Codable, Sendable {
    case app
    case window
    case url
    case file
    case date
    case person
}

public struct WorkGraphMention: Equatable, Sendable {
    public let kind: WorkGraphEntityKind
    public let canonicalValue: String
    public let displayName: String
    public let aliases: [String]
    public let evidence: String
    public let source: String
    public let validFrom: Date?
    public let validTo: Date?

    public init(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        aliases: [String] = [],
        evidence: String,
        source: String,
        validFrom: Date? = nil,
        validTo: Date? = nil
    ) {
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.displayName = displayName
        self.aliases = aliases
        self.evidence = evidence
        self.source = source
        self.validFrom = validFrom
        self.validTo = validTo
    }
}

public struct WorkGraphEntity: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let kind: WorkGraphEntityKind
    public let canonicalValue: String
    public let displayName: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let validFrom: Date
    public let validTo: Date?
    public let transactionFrom: Date
    public let transactionTo: Date?

    public init(
        id: Int64,
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        validFrom: Date,
        validTo: Date?,
        transactionFrom: Date,
        transactionTo: Date?
    ) {
        self.id = id
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.displayName = displayName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.validFrom = validFrom
        self.validTo = validTo
        self.transactionFrom = transactionFrom
        self.transactionTo = transactionTo
    }
}

public struct WorkGraphEntityAlias: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let entityID: Int64
    public let alias: String
    public let normalizedAlias: String
    public let source: String
    public let mentionCount: Int
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let validFrom: Date
    public let validTo: Date?
    public let transactionFrom: Date
    public let transactionTo: Date?

    public init(
        id: Int64,
        entityID: Int64,
        alias: String,
        normalizedAlias: String,
        source: String,
        mentionCount: Int,
        firstSeenAt: Date,
        lastSeenAt: Date,
        validFrom: Date,
        validTo: Date?,
        transactionFrom: Date,
        transactionTo: Date?
    ) {
        self.id = id
        self.entityID = entityID
        self.alias = alias
        self.normalizedAlias = normalizedAlias
        self.source = source
        self.mentionCount = mentionCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.validFrom = validFrom
        self.validTo = validTo
        self.transactionFrom = transactionFrom
        self.transactionTo = transactionTo
    }
}

public struct WorkGraphTimelineEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let contextID: Int64
    public let entityID: Int64
    public let kind: WorkGraphEntityKind
    public let canonicalValue: String
    public let displayName: String
    public let capturedAt: Date
    public let relation: String
    public let evidenceSnippet: String
    public let validFrom: Date
    public let validTo: Date?
    public let transactionFrom: Date
    public let transactionTo: Date?

    public init(
        id: Int64,
        contextID: Int64,
        entityID: Int64,
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        capturedAt: Date,
        relation: String,
        evidenceSnippet: String,
        validFrom: Date,
        validTo: Date?,
        transactionFrom: Date,
        transactionTo: Date?
    ) {
        self.id = id
        self.contextID = contextID
        self.entityID = entityID
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.displayName = displayName
        self.capturedAt = capturedAt
        self.relation = relation
        self.evidenceSnippet = evidenceSnippet
        self.validFrom = validFrom
        self.validTo = validTo
        self.transactionFrom = transactionFrom
        self.transactionTo = transactionTo
    }
}

public struct WorkGraphEdge: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let sourceEntityID: Int64
    public let targetEntityID: Int64
    public let relation: String
    public let evidenceSnippet: String
    public let weight: Double
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let validFrom: Date
    public let validTo: Date?
    public let transactionFrom: Date
    public let transactionTo: Date?
}

public enum WorkGraphExtractor {
    public static func mentions(in context: RecordedContext) -> [WorkGraphMention] {
        guard !PrivacyRules.isSensitive(context) else { return [] }

        var mentions: [WorkGraphMention] = []
        appendAppMention(context, to: &mentions)
        appendWindowMention(context, to: &mentions)

        let searchableText = [
            context.windowTitle,
            context.ocrText,
            context.metadataJSON
        ].compactMap { $0 }.joined(separator: "\n")

        appendURLMentions(searchableText, to: &mentions)
        appendFileMentions(searchableText, to: &mentions)
        appendDateMentions(searchableText, to: &mentions)
        appendPersonMentions(searchableText, to: &mentions)

        var seen: Set<String> = []
        return mentions.filter { mention in
            let key = "\(mention.kind.rawValue):\(mention.canonicalValue)"
            return seen.insert(key).inserted
        }
    }

    private static func appendAppMention(_ context: RecordedContext, to mentions: inout [WorkGraphMention]) {
        let appName = context.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty, !PrivacyRules.isSensitiveText(appName) else { return }
        let canonical = context.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? WorkGraphNormalizer.normalizedAlias(appName)
        mentions.append(WorkGraphMention(
            kind: .app,
            canonicalValue: canonical,
            displayName: appName,
            aliases: [appName],
            evidence: appName,
            source: "app"
        ))
    }

    private static func appendWindowMention(_ context: RecordedContext, to mentions: inout [WorkGraphMention]) {
        guard let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              !PrivacyRules.isSensitiveText(title) else { return }
        mentions.append(WorkGraphMention(
            kind: .window,
            canonicalValue: WorkGraphNormalizer.normalizedAlias(title),
            displayName: title,
            aliases: [title],
            evidence: title,
            source: "window"
        ))
    }

    private static func appendURLMentions(_ text: String, to mentions: inout [WorkGraphMention]) {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            if url.isFileURL {
                appendFileURL(url, evidence: nsText.substring(with: match.range), to: &mentions)
                return
            }
            guard let canonical = WorkGraphNormalizer.canonicalURL(url) else { return }
            let evidence = nsText.substring(with: match.range)
            mentions.append(WorkGraphMention(
                kind: .url,
                canonicalValue: canonical,
                displayName: WorkGraphNormalizer.displayURL(url),
                aliases: [evidence],
                evidence: evidence,
                source: "text"
            ))
        }
    }

    private static func appendFileMentions(_ text: String, to mentions: inout [WorkGraphMention]) {
        for value in regexMatches(#"(?:~|/Users|/Volumes|/private|/var|/tmp)(?:/[^\s"'<>|]+)+"#, in: text) {
            appendFilePath(value, evidence: value, to: &mentions)
        }
    }

    private static func appendDateMentions(_ text: String, to mentions: inout [WorkGraphMention]) {
        for value in regexMatches(#"\b\d{4}-\d{2}-\d{2}\b"#, in: text) {
            guard let date = WorkGraphDateCodec.day(from: value) else { continue }
            mentions.append(WorkGraphMention(
                kind: .date,
                canonicalValue: WorkGraphDateCodec.dayString(from: date),
                displayName: WorkGraphDateCodec.dayString(from: date),
                aliases: [value],
                evidence: value,
                source: "text",
                validFrom: date
            ))
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let date = match.date else { return }
            let day = WorkGraphDateCodec.dayString(from: date)
            let evidence = nsText.substring(with: match.range)
            mentions.append(WorkGraphMention(
                kind: .date,
                canonicalValue: day,
                displayName: day,
                aliases: [evidence],
                evidence: evidence,
                source: "text",
                validFrom: WorkGraphDateCodec.day(from: day)
            ))
        }
    }

    private static func appendPersonMentions(_ text: String, to mentions: inout [WorkGraphMention]) {
        for email in regexMatches(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, in: text, options: [.caseInsensitive]) {
            let canonical = email.lowercased()
            mentions.append(WorkGraphMention(
                kind: .person,
                canonicalValue: canonical,
                displayName: WorkGraphNormalizer.displayPerson(email),
                aliases: [email],
                evidence: email,
                source: "email"
            ))
        }

        let namePattern = #"\b(?:Owner|Manager|Assignee|Reviewer|From|To|With|Person):?\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,2})\b"#
        for name in capturedRegexMatches(namePattern, in: text) {
            mentions.append(WorkGraphMention(
                kind: .person,
                canonicalValue: WorkGraphNormalizer.normalizedAlias(name),
                displayName: name,
                aliases: [name],
                evidence: name,
                source: "text"
            ))
        }
    }

    private static func appendFileURL(_ url: URL, evidence: String, to mentions: inout [WorkGraphMention]) {
        appendFilePath(url.path, evidence: evidence, to: &mentions)
    }

    private static func appendFilePath(_ path: String, evidence: String, to mentions: inout [WorkGraphMention]) {
        let expanded = (path as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard !canonical.isEmpty, !PrivacyRules.isSensitiveText(canonical) else { return }
        mentions.append(WorkGraphMention(
            kind: .file,
            canonicalValue: canonical,
            displayName: URL(fileURLWithPath: canonical).lastPathComponent,
            aliases: [path],
            evidence: evidence,
            source: "text"
        ))
    }

    private static func regexMatches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    private static func capturedRegexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                return nsText.substring(with: match.range(at: 1))
            }
    }
}

public extension CascadeStore {
    func extractWorkGraphMentions(from context: RecordedContext) -> [WorkGraphMention] {
        WorkGraphExtractor.mentions(in: context)
    }

    @discardableResult
    func linkWorkGraphEntities(for context: RecordedContext) throws -> [WorkGraphTimelineEntry] {
        guard context.id > 0 else {
            throw CascadeStoreError.sqlite("work graph requires a persisted context id")
        }

        var entries: [WorkGraphTimelineEntry] = []
        for mention in WorkGraphExtractor.mentions(in: context) {
            let entity = try upsertGraphEntity(
                kind: mention.kind,
                canonicalValue: mention.canonicalValue,
                displayName: mention.displayName,
                aliases: mention.aliases,
                observedAt: context.capturedAt,
                validFrom: mention.validFrom,
                validTo: mention.validTo,
                aliasSource: mention.source
            )
            if let entry = try linkGraphEntity(
                contextID: context.id,
                entityID: entity.id,
                relation: "observed",
                evidence: mention.evidence,
                observedAt: context.capturedAt,
                validFrom: mention.validFrom,
                validTo: mention.validTo
            ) {
                entries.append(entry)
            }
        }
        return entries
    }

    @discardableResult
    func upsertGraphEntity(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        aliases: [String] = [],
        observedAt: Date = Date(),
        validFrom: Date? = nil,
        validTo: Date? = nil,
        aliasSource: String = "manual"
    ) throws -> WorkGraphEntity {
        let canonical = WorkGraphNormalizer.canonical(kind: kind, value: canonicalValue)
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty, !display.isEmpty else {
            throw CascadeStoreError.sqlite("work graph entity cannot be empty")
        }
        guard !PrivacyRules.isSensitiveText(canonical), !PrivacyRules.isSensitiveText(display) else {
            throw CascadeStoreError.sqlite("sensitive work graph entity refused")
        }

        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)

        let sql = """
        INSERT INTO graph_entity
            (kind, canonical_value, display_name, first_seen_at, last_seen_at,
             valid_from, valid_to, transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(kind, canonical_value) DO UPDATE SET
            display_name = excluded.display_name,
            first_seen_at = min(graph_entity.first_seen_at, excluded.first_seen_at),
            last_seen_at = max(graph_entity.last_seen_at, excluded.last_seen_at),
            valid_from = min(graph_entity.valid_from, excluded.valid_from),
            valid_to = CASE
                WHEN graph_entity.valid_to IS NULL THEN excluded.valid_to
                WHEN excluded.valid_to IS NULL THEN graph_entity.valid_to
                ELSE max(graph_entity.valid_to, excluded.valid_to)
            END,
            transaction_to = NULL,
            updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            workGraphBind(kind.rawValue, at: 1, in: statement)
            workGraphBind(canonical, at: 2, in: statement)
            workGraphBind(display, at: 3, in: statement)
            workGraphBind(observed, at: 4, in: statement)
            workGraphBind(observed, at: 5, in: statement)
            workGraphBind(validStart, at: 6, in: statement)
            workGraphBind(validEnd, at: 7, in: statement)
            workGraphBind(transaction, at: 8, in: statement)
            workGraphBind(transaction, at: 9, in: statement)
            workGraphBind(transaction, at: 10, in: statement)
            try stepDone(statement)
        }

        let entity = try graphEntity(kind: kind, canonicalValue: canonical)
        var seenAliases: Set<String> = []
        for alias in ([display] + aliases) where !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedAlias = WorkGraphNormalizer.normalizedAlias(alias)
            guard seenAliases.insert(normalizedAlias).inserted else { continue }
            try upsertGraphEntityAlias(
                entityID: entity.id,
                alias: alias,
                source: aliasSource,
                observedAt: observedAt,
                validFrom: validFrom,
                validTo: validTo
            )
        }
        return entity
    }

    @discardableResult
    func upsertGraphEntityAlias(
        entityID: Int64,
        alias: String,
        source: String = "manual",
        observedAt: Date = Date(),
        validFrom: Date? = nil,
        validTo: Date? = nil
    ) throws -> WorkGraphEntityAlias {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = WorkGraphNormalizer.normalizedAlias(cleanAlias)
        guard entityID > 0, !cleanAlias.isEmpty, !normalized.isEmpty else {
            throw CascadeStoreError.sqlite("work graph alias cannot be empty")
        }
        guard !PrivacyRules.isSensitiveText(cleanAlias) else {
            throw CascadeStoreError.sqlite("sensitive work graph alias refused")
        }

        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)

        let sql = """
        INSERT INTO graph_entity_alias
            (entity_id, alias, normalized_alias, source, mention_count, first_seen_at,
             last_seen_at, valid_from, valid_to, transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(entity_id, normalized_alias) DO UPDATE SET
            alias = excluded.alias,
            source = excluded.source,
            mention_count = graph_entity_alias.mention_count + 1,
            first_seen_at = min(graph_entity_alias.first_seen_at, excluded.first_seen_at),
            last_seen_at = max(graph_entity_alias.last_seen_at, excluded.last_seen_at),
            valid_from = min(graph_entity_alias.valid_from, excluded.valid_from),
            valid_to = CASE
                WHEN graph_entity_alias.valid_to IS NULL THEN excluded.valid_to
                WHEN excluded.valid_to IS NULL THEN graph_entity_alias.valid_to
                ELSE max(graph_entity_alias.valid_to, excluded.valid_to)
            END,
            transaction_to = NULL,
            updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, entityID)
            workGraphBind(cleanAlias, at: 2, in: statement)
            workGraphBind(normalized, at: 3, in: statement)
            workGraphBind(source, at: 4, in: statement)
            workGraphBind(observed, at: 5, in: statement)
            workGraphBind(observed, at: 6, in: statement)
            workGraphBind(validStart, at: 7, in: statement)
            workGraphBind(validEnd, at: 8, in: statement)
            workGraphBind(transaction, at: 9, in: statement)
            workGraphBind(transaction, at: 10, in: statement)
            workGraphBind(transaction, at: 11, in: statement)
            try stepDone(statement)
        }

        return try graphEntityAlias(entityID: entityID, normalizedAlias: normalized)
    }

    @discardableResult
    func linkGraphEntity(
        contextID: Int64,
        entityID: Int64,
        relation: String = "observed",
        evidence: String,
        observedAt: Date = Date(),
        validFrom: Date? = nil,
        validTo: Date? = nil
    ) throws -> WorkGraphTimelineEntry? {
        guard contextID > 0, entityID > 0 else {
            throw CascadeStoreError.sqlite("work graph link requires context and entity ids")
        }
        guard let snippet = WorkGraphEvidence.snippet(from: evidence) else { return nil }

        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)
        let trimmedRelation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRelation = trimmedRelation.isEmpty ? "observed" : trimmedRelation

        let sql = """
        INSERT INTO context_entity_link
            (context_id, entity_id, relation, evidence_snippet, observed_at, valid_from, valid_to,
             transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(context_id, entity_id, relation) DO UPDATE SET
            evidence_snippet = excluded.evidence_snippet,
            observed_at = excluded.observed_at,
            valid_from = min(context_entity_link.valid_from, excluded.valid_from),
            valid_to = CASE
                WHEN context_entity_link.valid_to IS NULL THEN excluded.valid_to
                WHEN excluded.valid_to IS NULL THEN context_entity_link.valid_to
                ELSE max(context_entity_link.valid_to, excluded.valid_to)
            END,
            transaction_to = NULL,
            updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            sqlite3_bind_int64(statement, 2, entityID)
            workGraphBind(cleanRelation, at: 3, in: statement)
            workGraphBind(snippet, at: 4, in: statement)
            workGraphBind(observed, at: 5, in: statement)
            workGraphBind(validStart, at: 6, in: statement)
            workGraphBind(validEnd, at: 7, in: statement)
            workGraphBind(transaction, at: 8, in: statement)
            workGraphBind(transaction, at: 9, in: statement)
            workGraphBind(transaction, at: 10, in: statement)
            try stepDone(statement)
        }

        return try graphEntityTimelineEntry(contextID: contextID, entityID: entityID, relation: cleanRelation)
    }

    private func graphEntityTimelineEntry(
        contextID: Int64,
        entityID: Int64,
        relation: String
    ) throws -> WorkGraphTimelineEntry? {
        let sql = """
        SELECT l.id, l.context_id, l.entity_id, e.kind, e.canonical_value, e.display_name,
               c.captured_at, l.relation, l.evidence_snippet, l.valid_from, l.valid_to,
               l.transaction_from, l.transaction_to
        FROM context_entity_link l
        JOIN graph_entity e ON e.id = l.entity_id
        JOIN recorded_context c ON c.id = l.context_id
        WHERE l.context_id = ? AND l.entity_id = ? AND l.relation = ?
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            sqlite3_bind_int64(statement, 2, entityID)
            workGraphBind(relation, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeTimelineEntry(statement)
        }
    }

    @discardableResult
    func upsertGraphEdge(
        sourceEntityID: Int64,
        targetEntityID: Int64,
        relation: String,
        evidence: String,
        observedAt: Date = Date(),
        validFrom: Date? = nil,
        validTo: Date? = nil,
        weight: Double = 1.0
    ) throws -> WorkGraphEdge? {
        guard let snippet = WorkGraphEvidence.snippet(from: evidence) else { return nil }
        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)

        let sql = """
        INSERT INTO graph_edge
            (source_entity_id, target_entity_id, relation, evidence_snippet, weight, first_seen_at,
             last_seen_at, valid_from, valid_to, transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(source_entity_id, target_entity_id, relation) DO UPDATE SET
            evidence_snippet = excluded.evidence_snippet,
            weight = excluded.weight,
            first_seen_at = min(graph_edge.first_seen_at, excluded.first_seen_at),
            last_seen_at = max(graph_edge.last_seen_at, excluded.last_seen_at),
            valid_from = min(graph_edge.valid_from, excluded.valid_from),
            valid_to = CASE
                WHEN graph_edge.valid_to IS NULL THEN excluded.valid_to
                WHEN excluded.valid_to IS NULL THEN graph_edge.valid_to
                ELSE max(graph_edge.valid_to, excluded.valid_to)
            END,
            transaction_to = NULL,
            updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, sourceEntityID)
            sqlite3_bind_int64(statement, 2, targetEntityID)
            workGraphBind(relation, at: 3, in: statement)
            workGraphBind(snippet, at: 4, in: statement)
            sqlite3_bind_double(statement, 5, weight)
            workGraphBind(observed, at: 6, in: statement)
            workGraphBind(observed, at: 7, in: statement)
            workGraphBind(validStart, at: 8, in: statement)
            workGraphBind(validEnd, at: 9, in: statement)
            workGraphBind(transaction, at: 10, in: statement)
            workGraphBind(transaction, at: 11, in: statement)
            workGraphBind(transaction, at: 12, in: statement)
            try stepDone(statement)
        }

        return try graphEdge(sourceEntityID: sourceEntityID, targetEntityID: targetEntityID, relation: relation)
    }

    func graphEntity(kind: WorkGraphEntityKind, canonicalValue: String) throws -> WorkGraphEntity {
        let canonical = WorkGraphNormalizer.canonical(kind: kind, value: canonicalValue)
        let sql = """
        SELECT id, kind, canonical_value, display_name, first_seen_at, last_seen_at,
               valid_from, valid_to, transaction_from, transaction_to
        FROM graph_entity
        WHERE kind = ? AND canonical_value = ?;
        """
        return try withStatement(sql) { statement in
            workGraphBind(kind.rawValue, at: 1, in: statement)
            workGraphBind(canonical, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw CascadeStoreError.sqlite("work graph entity not found")
            }
            return decodeGraphEntity(statement)
        }
    }

    func graphEntityAlias(entityID: Int64, normalizedAlias: String) throws -> WorkGraphEntityAlias {
        let sql = """
        SELECT id, entity_id, alias, normalized_alias, source, mention_count, first_seen_at, last_seen_at,
               valid_from, valid_to, transaction_from, transaction_to
        FROM graph_entity_alias
        WHERE entity_id = ? AND normalized_alias = ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, entityID)
            workGraphBind(normalizedAlias, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw CascadeStoreError.sqlite("work graph alias not found")
            }
            return decodeGraphAlias(statement)
        }
    }

    func entityTimeline(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        limit: Int = 20
    ) throws -> [WorkGraphTimelineEntry] {
        let entity = try graphEntity(kind: kind, canonicalValue: canonicalValue)
        return try entityTimeline(entityID: entity.id, limit: limit)
    }

    func entityTimeline(
        entityID: Int64,
        limit: Int = 20,
        newestFirst: Bool = false
    ) throws -> [WorkGraphTimelineEntry] {
        guard limit > 0 else { return [] }
        let direction = newestFirst ? "DESC" : "ASC"
        let sql = """
        SELECT l.id, l.context_id, l.entity_id, e.kind, e.canonical_value, e.display_name,
               c.captured_at, l.relation, l.evidence_snippet, l.valid_from, l.valid_to,
               l.transaction_from, l.transaction_to
        FROM context_entity_link l
        JOIN graph_entity e ON e.id = l.entity_id
        JOIN recorded_context c ON c.id = l.context_id
        WHERE l.entity_id = ?
        ORDER BY c.captured_at \(direction), l.context_id \(direction)
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, entityID)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [WorkGraphTimelineEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeTimelineEntry(statement))
            }
            return rows
        }
    }

    private func graphEdge(sourceEntityID: Int64, targetEntityID: Int64, relation: String) throws -> WorkGraphEdge {
        let sql = """
        SELECT id, source_entity_id, target_entity_id, relation, evidence_snippet, weight,
               first_seen_at, last_seen_at, valid_from, valid_to, transaction_from, transaction_to
        FROM graph_edge
        WHERE source_entity_id = ? AND target_entity_id = ? AND relation = ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, sourceEntityID)
            sqlite3_bind_int64(statement, 2, targetEntityID)
            workGraphBind(relation, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw CascadeStoreError.sqlite("work graph edge not found")
            }
            return WorkGraphEdge(
                id: sqlite3_column_int64(statement, 0),
                sourceEntityID: sqlite3_column_int64(statement, 1),
                targetEntityID: sqlite3_column_int64(statement, 2),
                relation: workGraphText(statement, 3) ?? "related",
                evidenceSnippet: workGraphText(statement, 4) ?? "",
                weight: sqlite3_column_double(statement, 5),
                firstSeenAt: WorkGraphDateCodec.date(from: workGraphText(statement, 6)) ?? Date(),
                lastSeenAt: WorkGraphDateCodec.date(from: workGraphText(statement, 7)) ?? Date(),
                validFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 8)) ?? Date(),
                validTo: WorkGraphDateCodec.date(from: workGraphText(statement, 9)),
                transactionFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 10)) ?? Date(),
                transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 11))
            )
        }
    }
}

private enum WorkGraphNormalizer {
    static func canonical(kind: WorkGraphEntityKind, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .app, .window, .person:
            return normalizedAlias(trimmed)
        case .url:
            if let url = URL(string: trimmed), let canonical = canonicalURL(url) {
                return canonical
            }
            return trimmed.lowercased()
        case .file:
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        case .date:
            if let date = WorkGraphDateCodec.day(from: trimmed) {
                return WorkGraphDateCodec.dayString(from: date)
            }
            return trimmed
        }
    }

    static func normalizedAlias(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func canonicalURL(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        let path = url.path.isEmpty ? "/" : url.path
        components.path = path == "/" ? "" : path
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func displayURL(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let path = url.path == "/" ? "" : url.path
        return "\(host)\(path)"
    }

    static func displayPerson(_ email: String) -> String {
        email.split(separator: "@").first.map(String.init) ?? email
    }
}

private enum WorkGraphEvidence {
    static func snippet(from evidence: String, maxLength: Int = 180) -> String? {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !PrivacyRules.isSensitiveText(trimmed) else { return nil }
        let redacted = redact(trimmed)
        if redacted.count <= maxLength { return redacted }
        return String(redacted.prefix(maxLength - 1)) + "..."
    }

    private static func redact(_ value: String) -> String {
        var redacted = replace(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, in: value, with: "[email]", options: [.caseInsensitive])
        redacted = replace(#"\?[^#\s]+"#, in: redacted, with: "?[redacted]")
        redacted = replace(#"/Users/[^/\s]+/"#, in: redacted, with: "/Users/[user]/")
        redacted = replace(#"\b\d{4,}\b"#, in: redacted, with: "[number]")
        return redacted
    }

    private static func replace(
        _ pattern: String,
        in value: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length),
            withTemplate: replacement
        )
    }
}

private enum WorkGraphDateCodec {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return formatter().date(from: string) ?? day(from: string)
    }

    static func day(from string: String) -> Date? {
        dayFormatter().date(from: string)
    }

    static func dayString(from date: Date) -> String {
        dayFormatter().string(from: date)
    }
}

private func decodeGraphEntity(_ statement: OpaquePointer) -> WorkGraphEntity {
    WorkGraphEntity(
        id: sqlite3_column_int64(statement, 0),
        kind: WorkGraphEntityKind(rawValue: workGraphText(statement, 1) ?? "") ?? .window,
        canonicalValue: workGraphText(statement, 2) ?? "",
        displayName: workGraphText(statement, 3) ?? "",
        firstSeenAt: WorkGraphDateCodec.date(from: workGraphText(statement, 4)) ?? Date(),
        lastSeenAt: WorkGraphDateCodec.date(from: workGraphText(statement, 5)) ?? Date(),
        validFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 6)) ?? Date(),
        validTo: WorkGraphDateCodec.date(from: workGraphText(statement, 7)),
        transactionFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 8)) ?? Date(),
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 9))
    )
}

private func decodeGraphAlias(_ statement: OpaquePointer) -> WorkGraphEntityAlias {
    WorkGraphEntityAlias(
        id: sqlite3_column_int64(statement, 0),
        entityID: sqlite3_column_int64(statement, 1),
        alias: workGraphText(statement, 2) ?? "",
        normalizedAlias: workGraphText(statement, 3) ?? "",
        source: workGraphText(statement, 4) ?? "manual",
        mentionCount: Int(sqlite3_column_int(statement, 5)),
        firstSeenAt: WorkGraphDateCodec.date(from: workGraphText(statement, 6)) ?? Date(),
        lastSeenAt: WorkGraphDateCodec.date(from: workGraphText(statement, 7)) ?? Date(),
        validFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 8)) ?? Date(),
        validTo: WorkGraphDateCodec.date(from: workGraphText(statement, 9)),
        transactionFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 10)) ?? Date(),
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 11))
    )
}

private func decodeTimelineEntry(_ statement: OpaquePointer) -> WorkGraphTimelineEntry {
    WorkGraphTimelineEntry(
        id: sqlite3_column_int64(statement, 0),
        contextID: sqlite3_column_int64(statement, 1),
        entityID: sqlite3_column_int64(statement, 2),
        kind: WorkGraphEntityKind(rawValue: workGraphText(statement, 3) ?? "") ?? .window,
        canonicalValue: workGraphText(statement, 4) ?? "",
        displayName: workGraphText(statement, 5) ?? "",
        capturedAt: WorkGraphDateCodec.date(from: workGraphText(statement, 6)) ?? Date(),
        relation: workGraphText(statement, 7) ?? "observed",
        evidenceSnippet: workGraphText(statement, 8) ?? "",
        validFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 9)) ?? Date(),
        validTo: WorkGraphDateCodec.date(from: workGraphText(statement, 10)),
        transactionFrom: WorkGraphDateCodec.date(from: workGraphText(statement, 11)) ?? Date(),
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 12))
    )
}

private func workGraphBind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private func workGraphText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
}
