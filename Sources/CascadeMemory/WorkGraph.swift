import Foundation
import NaturalLanguage
import SQLite3

public enum WorkGraphEntityKind: String, CaseIterable, Codable, Sendable {
    case app
    case window
    case url
    case file
    case folder
    case date
    case person
    case organization
    case project
    case task
    case topic
    case skill
    case recipe
    case subgoalType = "subgoal_type"
    case expectedEffect = "expected_effect"
}

public struct WorkGraphRelationHint: Equatable, Sendable {
    public let targetKind: WorkGraphEntityKind
    public let targetCanonicalValue: String
    public let relation: String
    public let evidence: String
    public let validFrom: Date?
    public let validTo: Date?
    public let confidence: Double
    public let metadataJSON: String?

    public init(
        targetKind: WorkGraphEntityKind,
        targetCanonicalValue: String,
        relation: String,
        evidence: String,
        validFrom: Date? = nil,
        validTo: Date? = nil,
        confidence: Double = 1.0,
        metadataJSON: String? = nil
    ) {
        self.targetKind = targetKind
        self.targetCanonicalValue = targetCanonicalValue
        self.relation = relation
        self.evidence = evidence
        self.validFrom = validFrom
        self.validTo = validTo
        self.confidence = confidence
        self.metadataJSON = metadataJSON
    }
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
    public let confidence: Double
    public let piiClass: String?
    public let metadataJSON: String?
    public let spanStart: Int?
    public let spanEnd: Int?
    public let role: String
    public let relationHints: [WorkGraphRelationHint]

    public init(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        aliases: [String] = [],
        evidence: String,
        source: String,
        validFrom: Date? = nil,
        validTo: Date? = nil,
        confidence: Double = 1.0,
        piiClass: String? = nil,
        metadataJSON: String? = nil,
        spanStart: Int? = nil,
        spanEnd: Int? = nil,
        role: String = "observed",
        relationHints: [WorkGraphRelationHint] = []
    ) {
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.displayName = displayName
        self.aliases = aliases
        self.evidence = evidence
        self.source = source
        self.validFrom = validFrom
        self.validTo = validTo
        self.confidence = confidence
        self.piiClass = piiClass
        self.metadataJSON = metadataJSON
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.role = role
        self.relationHints = relationHints
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
    public let normalizedValue: String?
    public let confidence: Double
    public let source: String
    public let piiClass: String?
    public let metadataJSON: String?

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
        transactionTo: Date?,
        normalizedValue: String? = nil,
        confidence: Double = 1.0,
        source: String = "legacy",
        piiClass: String? = nil,
        metadataJSON: String? = nil
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
        self.normalizedValue = normalizedValue
        self.confidence = confidence
        self.source = source
        self.piiClass = piiClass
        self.metadataJSON = metadataJSON
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
    public let confidence: Double

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
        transactionTo: Date?,
        confidence: Double = 1.0
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
        self.confidence = confidence
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
    public let role: String
    public let extractor: String
    public let confidence: Double

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
        transactionTo: Date?,
        role: String = "observed",
        extractor: String = "legacy",
        confidence: Double = 1.0
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
        self.role = role
        self.extractor = extractor
        self.confidence = confidence
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
    public let confidence: Double
    public let provenanceContextID: Int64?
    public let provenanceInputEventID: Int64?
    public let extractor: String
    public let metadataJSON: String?

    public init(
        id: Int64,
        sourceEntityID: Int64,
        targetEntityID: Int64,
        relation: String,
        evidenceSnippet: String,
        weight: Double,
        firstSeenAt: Date,
        lastSeenAt: Date,
        validFrom: Date,
        validTo: Date?,
        transactionFrom: Date,
        transactionTo: Date?,
        confidence: Double = 1.0,
        provenanceContextID: Int64? = nil,
        provenanceInputEventID: Int64? = nil,
        extractor: String = "legacy",
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.sourceEntityID = sourceEntityID
        self.targetEntityID = targetEntityID
        self.relation = relation
        self.evidenceSnippet = evidenceSnippet
        self.weight = weight
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.validFrom = validFrom
        self.validTo = validTo
        self.transactionFrom = transactionFrom
        self.transactionTo = transactionTo
        self.confidence = confidence
        self.provenanceContextID = provenanceContextID
        self.provenanceInputEventID = provenanceInputEventID
        self.extractor = extractor
        self.metadataJSON = metadataJSON
    }
}

public struct WorkGraphPlanningPrior: Equatable, Sendable {
    public let kind: WorkGraphEntityKind
    public let canonicalValue: String
    public let displayName: String
    public let relation: String
    public let weight: Double
    public let evidenceSnippet: String

    public init(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        relation: String,
        weight: Double,
        evidenceSnippet: String
    ) {
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.displayName = displayName
        self.relation = relation
        self.weight = weight
        self.evidenceSnippet = evidenceSnippet
    }
}

public enum WorkGraphExtractor {
    public static func mentions(in context: RecordedContext) -> [WorkGraphMention] {
        mentions(in: context, includeApp: true)
    }

    /// KG chunk construction calls this with `includeApp: false` after caching the
    /// validated app mention for an unchanged app identity. At 1fps, re-running
    /// the same PII/privacy checks tens of thousands of times is pure duplicate
    /// work; window/document/entity extraction remains per-context.
    internal static func mentions(
        in context: RecordedContext,
        includeApp: Bool
    ) -> [WorkGraphMention] {
        guard !PrivacyRules.isSensitive(context) else { return [] }

        var mentions: [WorkGraphMention] = []
        if includeApp { appendAppMention(context, to: &mentions) }
        appendWindowMention(context, to: &mentions)

        for segment in textSegments(context) {
            appendURLMentions(segment, to: &mentions)
            appendFileMentions(segment, to: &mentions)
            appendDateMentions(segment, to: &mentions)
            appendPersonMentions(segment, to: &mentions)
            appendOrganizationMentions(segment, to: &mentions)
            appendTaskMentions(segment, to: &mentions)
            appendStableTopicMentions(segment, to: &mentions)
        }
        appendMetadataMentions(context.metadataJSON, to: &mentions)

        var seen: Set<String> = []
        return mentions.filter { mention in
            let key = "\(mention.kind.rawValue):\(mention.canonicalValue)"
            return seen.insert(key).inserted
        }
    }

    private struct TextSegment {
        let text: String
        let source: String
        let baseOffset: Int
    }

    private struct TextMatch {
        let value: String
        let range: NSRange
    }

    private static func textSegments(_ context: RecordedContext) -> [TextSegment] {
        var offset = 0
        var segments: [TextSegment] = []
        func append(_ text: String?, source: String) {
            guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return }
            segments.append(TextSegment(text: cleaned, source: source, baseOffset: offset))
            offset += (cleaned as NSString).length + 1
        }
        append(context.windowTitle, source: "window")
        append(context.ocrText, source: "ocr")
        append(context.metadataJSON, source: "metadata")
        return segments
    }

    private static func appendAppMention(_ context: RecordedContext, to mentions: inout [WorkGraphMention]) {
        let appName = context.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty, !PrivacyRules.isSensitiveText(appName) else { return }
        let canonical = context.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? WorkGraphNormalizer.normalizedAlias(appName)
        guard !PIIDetector.containsHighConfidencePII(canonical + " " + appName) else { return }
        mentions.append(WorkGraphMention(
            kind: .app,
            canonicalValue: canonical,
            displayName: appName,
            aliases: [appName],
            evidence: appName,
            source: "app",
            confidence: 1.0,
            metadataJSON: workGraphMetadata(["bundleIdentifier": context.bundleIdentifier ?? canonical])
        ))
    }

    private static func appendWindowMention(_ context: RecordedContext, to mentions: inout [WorkGraphMention]) {
        guard let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              !PrivacyRules.isSensitiveText(title),
              !PIIDetector.containsHighConfidencePII(title) else { return }
        mentions.append(WorkGraphMention(
            kind: .window,
            canonicalValue: WorkGraphNormalizer.normalizedAlias(title),
            displayName: title,
            aliases: [title],
            evidence: title,
            source: "window",
            confidence: 0.95,
            spanStart: 0,
            spanEnd: (title as NSString).length
        ))
    }

    private static func appendURLMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        let nsText = segment.text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        detector?.enumerateMatches(in: segment.text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            if url.isFileURL {
                appendFileURL(url, evidence: nsText.substring(with: match.range), source: segment.source, span: absolute(match.range, in: segment), to: &mentions)
                return
            }
            guard let canonical = WorkGraphNormalizer.canonicalURL(url) else { return }
            let evidence = nsText.substring(with: match.range)
            let display = WorkGraphNormalizer.displayURL(url)
            let host = WorkGraphNormalizer.normalizedDomain(url.host ?? "")
            let project = projectFromIssueKey(in: canonical)
            var hints: [WorkGraphRelationHint] = []
            if let project {
                appendProjectMention(project, evidence: evidence, source: segment.source, span: absolute(match.range, in: segment), to: &mentions)
                hints.append(WorkGraphRelationHint(
                    targetKind: .project,
                    targetCanonicalValue: project,
                    relation: "BELONGS_TO_PROJECT",
                    evidence: evidence,
                    confidence: 0.75,
                    metadataJSON: workGraphMetadata(["source": "issue_key"])
                ))
            }
            mentions.append(WorkGraphMention(
                kind: .url,
                canonicalValue: canonical,
                displayName: display,
                aliases: [canonical, display, host].filter { !$0.isEmpty },
                evidence: evidence,
                source: segment.source,
                confidence: 0.95,
                piiClass: "URL",
                metadataJSON: workGraphMetadata(["host": host]),
                spanStart: absolute(match.range, in: segment).start,
                spanEnd: absolute(match.range, in: segment).end,
                relationHints: hints
            ))
            appendOrganizationFromDomain(host, evidence: evidence, source: segment.source, span: absolute(match.range, in: segment), to: &mentions)
        }
    }

    private static func appendFileMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        for match in regexMatches(#"(?:~|/Users|/Volumes|/private|/var|/tmp)(?:/[^\s"'<>|]+)+"#, in: segment.text) {
            appendFilePath(match.value, evidence: match.value, source: segment.source, span: absolute(match.range, in: segment), to: &mentions)
        }
    }

    private static func appendDateMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        for match in regexMatches(#"\b\d{4}-\d{2}-\d{2}\b"#, in: segment.text) {
            let value = match.value
            guard let date = WorkGraphDateCodec.day(from: value) else { continue }
            mentions.append(WorkGraphMention(
                kind: .date,
                canonicalValue: WorkGraphDateCodec.dayString(from: date),
                displayName: WorkGraphDateCodec.dayString(from: date),
                aliases: [value],
                evidence: value,
                source: segment.source,
                validFrom: date,
                confidence: 0.98,
                spanStart: absolute(match.range, in: segment).start,
                spanEnd: absolute(match.range, in: segment).end
            ))
        }

        let nsText = segment.text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        detector?.enumerateMatches(in: segment.text, options: [], range: range) { match, _, _ in
            guard let match, let date = match.date else { return }
            let day = WorkGraphDateCodec.dayString(from: date)
            let evidence = nsText.substring(with: match.range)
            mentions.append(WorkGraphMention(
                kind: .date,
                canonicalValue: day,
                displayName: day,
                aliases: [evidence],
                evidence: evidence,
                source: segment.source,
                validFrom: WorkGraphDateCodec.day(from: day),
                confidence: 0.9,
                spanStart: absolute(match.range, in: segment).start,
                spanEnd: absolute(match.range, in: segment).end
            ))
        }
    }

    private static func appendPersonMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        for match in regexMatches(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, in: segment.text, options: [.caseInsensitive]) {
            let email = match.value.lowercased()
            let hash = AuditIdentity.hash(email)
            let domain = WorkGraphNormalizer.normalizedDomain(email.split(separator: "@").last.map(String.init) ?? "")
            mentions.append(WorkGraphMention(
                kind: .person,
                canonicalValue: "email:\(hash)",
                displayName: "Person \(hash)",
                aliases: ["Person \(hash)"],
                evidence: email,
                source: "email",
                confidence: 0.98,
                piiClass: "EMAIL",
                metadataJSON: workGraphMetadata(["domain": domain]),
                spanStart: absolute(match.range, in: segment).start,
                spanEnd: absolute(match.range, in: segment).end
            ))
            appendOrganizationFromDomain(domain, evidence: email, source: "email_domain", span: absolute(match.range, in: segment), to: &mentions)
        }

        let namePattern = #"\b(?:Owner|Manager|Assignee|Reviewer|From|To|With|Person):?\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,2})\b"#
        for match in capturedRegexMatches(namePattern, in: segment.text) {
            let name = match.value
            guard !PIIDetector.containsHighConfidencePII(name) else { continue }
            mentions.append(WorkGraphMention(
                kind: .person,
                canonicalValue: WorkGraphNormalizer.normalizedAlias(name),
                displayName: name,
                aliases: [name],
                evidence: name,
                source: segment.source,
                confidence: 0.85,
                piiClass: "PERSON",
                spanStart: absolute(match.range, in: segment).start,
                spanEnd: absolute(match.range, in: segment).end
            ))
        }

        appendNameTypeMentions(segment, tag: .personalName, kind: .person, confidence: 0.55, piiClass: "PERSON", to: &mentions)
    }

    private static func appendOrganizationMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        appendNameTypeMentions(segment, tag: .organizationName, kind: .organization, confidence: 0.65, piiClass: nil, to: &mentions)
    }

    private static func appendTaskMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        let patterns = [
            #"\b(?:todo|to do|follow up|action item|next)\s*[:\-]\s*([^\n.;]{4,140})"#,
            #"\b([^\n.;]{4,120}?\bdue\s+(?:\d{4}-\d{2}-\d{2}|tomorrow|today|next\s+\w+)[^\n.;]{0,80})"#
        ]
        for pattern in patterns {
            for match in capturedRegexMatches(pattern, in: segment.text, options: [.caseInsensitive]) {
                let evidence = match.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard evidence.count >= 4,
                      !PrivacyRules.isSensitiveText(evidence),
                      !PIIDetector.containsHighConfidencePII(evidence) else { continue }
                let canonical = WorkGraphNormalizer.normalizedAlias(evidence)
                var hints: [WorkGraphRelationHint] = []
                for date in dates(in: evidence) {
                    hints.append(WorkGraphRelationHint(
                        targetKind: .date,
                        targetCanonicalValue: date,
                        relation: "DUE_ON",
                        evidence: evidence,
                        validFrom: WorkGraphDateCodec.day(from: date),
                        confidence: 0.85
                    ))
                }
                mentions.append(WorkGraphMention(
                    kind: .task,
                    canonicalValue: canonical,
                    displayName: String(evidence.prefix(80)),
                    aliases: [String(evidence.prefix(80))],
                    evidence: evidence,
                    source: segment.source,
                    confidence: 0.72,
                    spanStart: absolute(match.range, in: segment).start,
                    spanEnd: absolute(match.range, in: segment).end,
                    relationHints: hints
                ))
            }
        }
    }

    private static func appendStableTopicMentions(_ segment: TextSegment, to mentions: inout [WorkGraphMention]) {
        for match in regexMatches(#"(?<!\w)#[A-Za-z][A-Za-z0-9_\-]{1,48}\b"#, in: segment.text) {
            let topic = String(match.value.dropFirst())
            appendTopic(topic, evidence: match.value, source: segment.source, confidence: 0.62, span: absolute(match.range, in: segment), to: &mentions)
        }
        for match in regexMatches(#"\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b"#, in: segment.text) {
            appendTopic(match.value, evidence: match.value, source: segment.source, confidence: 0.78, span: absolute(match.range, in: segment), to: &mentions)
            if let project = projectFromIssueKey(in: match.value) {
                appendProjectMention(project, evidence: match.value, source: segment.source, span: absolute(match.range, in: segment), to: &mentions)
            }
        }
    }

    private static func appendMetadataMentions(_ metadataJSON: String?, to mentions: inout [WorkGraphMention]) {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return }

        func walk(_ value: Any, key: String?) {
            if let dictionary = value as? [String: Any] {
                for (nestedKey, nestedValue) in dictionary {
                    walk(nestedValue, key: nestedKey)
                }
                return
            }
            if let array = value as? [Any] {
                for item in array { walk(item, key: key) }
                return
            }
            guard let string = value as? String else { return }
            let normalizedKey = WorkGraphNormalizer.normalizedAlias(key ?? "")
            switch normalizedKey {
            case "project", "project name", "projectname", "repo", "repository":
                appendProjectMention(string, evidence: string, source: "metadata", span: nil, to: &mentions)
            case "file", "filepath", "file path", "path":
                appendFilePath(string, evidence: string, source: "metadata", span: nil, to: &mentions)
            case "folder", "directory":
                appendFolderPath(string, evidence: string, source: "metadata", span: nil, to: &mentions)
            case "url", "link":
                appendURLMentions(TextSegment(text: string, source: "metadata", baseOffset: 0), to: &mentions)
            case "tag", "tags", "topic", "topics":
                appendTopic(string, evidence: string, source: "metadata", confidence: 0.7, span: nil, to: &mentions)
            default:
                break
            }
        }

        walk(root, key: nil)
    }

    private static func appendFileURL(_ url: URL, evidence: String, source: String, span: (start: Int, end: Int)?, to mentions: inout [WorkGraphMention]) {
        appendFilePath(url.path, evidence: evidence, source: source, span: span, to: &mentions)
    }

    private static func appendFilePath(_ path: String, evidence: String, source: String, span: (start: Int, end: Int)?, to mentions: inout [WorkGraphMention]) {
        let expanded = (path as NSString).expandingTildeInPath
        let canonical = WorkGraphNormalizer.safeFilePath(expanded)
        guard !canonical.isEmpty,
              !PrivacyRules.isSensitiveText(canonical),
              !PIIDetector.containsHighConfidencePII(URL(fileURLWithPath: canonical).lastPathComponent) else { return }
        let folder = URL(fileURLWithPath: canonical).deletingLastPathComponent().path
        let project = projectName(fromFilePath: canonical)
        var hints = [
            WorkGraphRelationHint(
                targetKind: .folder,
                targetCanonicalValue: folder,
                relation: "IN_FOLDER",
                evidence: evidence,
                confidence: 0.95
            )
        ]
        if let project {
            appendProjectMention(project, evidence: evidence, source: source, span: span, to: &mentions)
            hints.append(WorkGraphRelationHint(
                targetKind: .project,
                targetCanonicalValue: project,
                relation: "BELONGS_TO_PROJECT",
                evidence: evidence,
                confidence: 0.75,
                metadataJSON: workGraphMetadata(["source": "folder"])
            ))
        }
        appendFolderPath(folder, evidence: evidence, source: source, span: span, to: &mentions)
        mentions.append(WorkGraphMention(
            kind: .file,
            canonicalValue: canonical,
            displayName: URL(fileURLWithPath: canonical).lastPathComponent,
            aliases: [canonical, URL(fileURLWithPath: canonical).lastPathComponent],
            evidence: evidence,
            source: source,
            confidence: 0.92,
            metadataJSON: workGraphMetadata(["extension": URL(fileURLWithPath: canonical).pathExtension]),
            spanStart: span?.start,
            spanEnd: span?.end,
            relationHints: hints
        ))
    }

    private static func appendFolderPath(_ path: String, evidence: String, source: String, span: (start: Int, end: Int)?, to mentions: inout [WorkGraphMention]) {
        let canonical = WorkGraphNormalizer.safeFilePath(path)
        let display = URL(fileURLWithPath: canonical).lastPathComponent
        guard !canonical.isEmpty, !display.isEmpty, !PrivacyRules.isSensitiveText(canonical) else { return }
        mentions.append(WorkGraphMention(
            kind: .folder,
            canonicalValue: canonical,
            displayName: display,
            aliases: [canonical, display],
            evidence: evidence,
            source: source,
            confidence: 0.9,
            spanStart: span?.start,
            spanEnd: span?.end
        ))
    }

    private static func appendNameTypeMentions(
        _ segment: TextSegment,
        tag targetTag: NLTag,
        kind: WorkGraphEntityKind,
        confidence: Double,
        piiClass: String?,
        to mentions: inout [WorkGraphMention]
    ) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = segment.text
        tagger.enumerateTags(
            in: segment.text.startIndex..<segment.text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard tag == targetTag else { return true }
            let value = String(segment.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count > 2,
                  !PrivacyRules.isSensitiveText(value),
                  !PIIDetector.containsHighConfidencePII(value) else { return true }
            let nsRange = NSRange(range, in: segment.text)
            mentions.append(WorkGraphMention(
                kind: kind,
                canonicalValue: WorkGraphNormalizer.normalizedAlias(value),
                displayName: value,
                aliases: [value],
                evidence: value,
                source: "nltagger",
                confidence: confidence,
                piiClass: piiClass,
                spanStart: absolute(nsRange, in: segment).start,
                spanEnd: absolute(nsRange, in: segment).end
            ))
            return true
        }
    }

    private static func appendOrganizationFromDomain(_ domain: String, evidence: String, source: String, span: (start: Int, end: Int)?, to mentions: inout [WorkGraphMention]) {
        let organization = WorkGraphNormalizer.organizationFromDomain(domain)
        guard !organization.isEmpty else { return }
        mentions.append(WorkGraphMention(
            kind: .organization,
            canonicalValue: organization,
            displayName: organization,
            aliases: [organization, domain].filter { !$0.isEmpty },
            evidence: evidence,
            source: source,
            confidence: 0.78,
            metadataJSON: workGraphMetadata(["domain": domain]),
            spanStart: span?.start,
            spanEnd: span?.end
        ))
    }

    private static func appendProjectMention(_ value: String, evidence: String, source: String, span: (start: Int, end: Int)?, to mentions: inout [WorkGraphMention]) {
        let display = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = WorkGraphNormalizer.normalizedAlias(display)
        guard canonical.count > 1,
              !genericProjectNames.contains(canonical),
              !PrivacyRules.isSensitiveText(display),
              !PIIDetector.containsHighConfidencePII(display) else { return }
        mentions.append(WorkGraphMention(
            kind: .project,
            canonicalValue: canonical,
            displayName: display,
            aliases: [display],
            evidence: evidence,
            source: source,
            confidence: 0.72,
            spanStart: span?.start,
            spanEnd: span?.end
        ))
    }

    private static func appendTopic(_ value: String, evidence: String, source: String, confidence: Double, span: (start: Int, end: Int)?, to mentions: inout [WorkGraphMention]) {
        let display = value.trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t"))
        let canonical = WorkGraphNormalizer.normalizedAlias(display)
        guard canonical.count > 1,
              !PrivacyRules.isSensitiveText(display),
              !PIIDetector.containsHighConfidencePII(display) else { return }
        var hints: [WorkGraphRelationHint] = []
        if let project = projectFromIssueKey(in: display) {
            hints.append(WorkGraphRelationHint(
                targetKind: .project,
                targetCanonicalValue: project,
                relation: "BELONGS_TO_PROJECT",
                evidence: evidence,
                confidence: 0.75
            ))
        }
        mentions.append(WorkGraphMention(
            kind: .topic,
            canonicalValue: canonical,
            displayName: display,
            aliases: [display],
            evidence: evidence,
            source: source,
            confidence: confidence,
            spanStart: span?.start,
            spanEnd: span?.end,
            relationHints: hints
        ))
    }

    private static func regexMatches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [TextMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { TextMatch(value: nsText.substring(with: $0.range), range: $0.range) }
    }

    private static func capturedRegexMatches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [TextMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                let range = match.range(at: 1)
                return TextMatch(value: nsText.substring(with: range), range: range)
            }
    }

    private static func absolute(_ range: NSRange, in segment: TextSegment) -> (start: Int, end: Int) {
        (segment.baseOffset + range.location, segment.baseOffset + range.location + range.length)
    }

    private static func dates(in text: String) -> [String] {
        regexMatches(#"\b\d{4}-\d{2}-\d{2}\b"#, in: text)
            .compactMap { WorkGraphDateCodec.day(from: $0.value).map(WorkGraphDateCodec.dayString(from:)) }
    }

    private static func projectFromIssueKey(in value: String) -> String? {
        guard let match = regexMatches(#"\b([A-Z][A-Z0-9]{1,9})-\d{1,6}\b"#, in: value).first else { return nil }
        let prefix = match.value.split(separator: "-").first.map(String.init) ?? ""
        return prefix.isEmpty ? nil : prefix.lowercased()
    }

    private static func projectName(fromFilePath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents.filter { component in
            let normalized = WorkGraphNormalizer.normalizedAlias(component)
            return !normalized.isEmpty
                && normalized != "/"
                && normalized != "users"
                && normalized != "<user>"
                && !genericProjectNames.contains(normalized)
        }
        return components.dropLast().last
    }

    private static let genericProjectNames: Set<String> = [
        "desktop", "documents", "downloads", "tmp", "temp", "private", "var",
        "users", "volumes", "library", "application support", "src", "sources",
        "tests", "public", "assets", "build", ".build"
    ]
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
        let mentions = WorkGraphExtractor.mentions(in: context)
        var entitiesByKey: [String: WorkGraphEntity] = [:]

        for mention in mentions {
            let entity = try upsertGraphEntity(
                kind: mention.kind,
                canonicalValue: mention.canonicalValue,
                displayName: mention.displayName,
                aliases: mention.aliases,
                observedAt: context.capturedAt,
                validFrom: mention.validFrom,
                validTo: mention.validTo,
                aliasSource: mention.source,
                confidence: mention.confidence,
                source: mention.source,
                piiClass: mention.piiClass,
                metadataJSON: mention.metadataJSON
            )
            entitiesByKey[workGraphEntityKey(kind: mention.kind, canonicalValue: mention.canonicalValue)] = entity
            if let entry = try linkGraphEntity(
                contextID: context.id,
                entityID: entity.id,
                relation: mention.role,
                evidence: mention.evidence,
                observedAt: context.capturedAt,
                validFrom: mention.validFrom,
                validTo: mention.validTo,
                role: mention.role,
                extractor: mention.source,
                spanStart: mention.spanStart,
                spanEnd: mention.spanEnd,
                confidence: mention.confidence
            ) {
                entries.append(entry)
            }
        }

        let contextNodes = [WorkGraphEntityKind.window, .app].compactMap { kind -> WorkGraphEntity? in
            mentions.first { $0.kind == kind }
                .flatMap { entitiesByKey[workGraphEntityKey(kind: $0.kind, canonicalValue: $0.canonicalValue)] }
        }
        for sourceEntity in contextNodes {
            for mention in mentions where mention.kind == .url || mention.kind == .file {
                guard let target = entitiesByKey[workGraphEntityKey(kind: mention.kind, canonicalValue: mention.canonicalValue)] else { continue }
                let relation = mention.kind == .url ? "VISITED_URL" : "OPENED_FILE"
                _ = try upsertGraphEdge(
                    sourceEntityID: sourceEntity.id,
                    targetEntityID: target.id,
                    relation: relation,
                    evidence: mention.evidence,
                    observedAt: context.capturedAt,
                    validFrom: mention.validFrom,
                    validTo: mention.validTo,
                    weight: mention.confidence,
                    confidence: mention.confidence,
                    provenanceContextID: context.id,
                    extractor: mention.source,
                    metadataJSON: workGraphMetadata(["source": "same_context"])
                )
            }
        }

        for mention in mentions {
            guard let source = entitiesByKey[workGraphEntityKey(kind: mention.kind, canonicalValue: mention.canonicalValue)] else { continue }
            for hint in mention.relationHints {
                guard let target = entitiesByKey[workGraphEntityKey(kind: hint.targetKind, canonicalValue: hint.targetCanonicalValue)] else { continue }
                _ = try upsertGraphEdge(
                    sourceEntityID: source.id,
                    targetEntityID: target.id,
                    relation: hint.relation,
                    evidence: hint.evidence,
                    observedAt: context.capturedAt,
                    validFrom: hint.validFrom ?? mention.validFrom,
                    validTo: hint.validTo ?? mention.validTo,
                    weight: hint.confidence,
                    confidence: hint.confidence,
                    provenanceContextID: context.id,
                    extractor: mention.source,
                    metadataJSON: hint.metadataJSON
                )
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
        aliasSource: String = "manual",
        confidence: Double = 1.0,
        source: String? = nil,
        piiClass: String? = nil,
        metadataJSON: String? = nil
    ) throws -> WorkGraphEntity {
        let safe = try WorkGraphPrivacy.safeEntityValues(
            kind: kind,
            canonicalValue: canonicalValue,
            displayName: displayName,
            piiClass: piiClass
        )
        let canonical = safe.canonical
        let display = safe.display
        guard !canonical.isEmpty, !display.isEmpty else {
            throw CascadeStoreError.sqlite("work graph entity cannot be empty")
        }
        guard !PrivacyRules.isSensitiveText(canonical), !PrivacyRules.isSensitiveText(display),
              !PIIDetector.containsHighConfidencePII(canonical),
              !PIIDetector.containsHighConfidencePII(display) else {
            throw CascadeStoreError.sqlite("sensitive work graph entity refused")
        }
        let boundedConfidence = min(max(confidence, 0.0), 1.0)
        let entitySource = (source ?? aliasSource).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSource = entitySource.isEmpty ? "manual" : entitySource
        let normalizedValue = WorkGraphNormalizer.normalizedValue(kind: kind, canonicalValue: canonical)
        let cleanPIIClass = safe.piiClass ?? piiClass

        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)

        let sql = """
        INSERT INTO graph_entity
            (kind, canonical_value, display_name, normalized_value, confidence, source, pii_class, metadata_json,
             first_seen_at, last_seen_at,
             valid_from, valid_to, transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(kind, canonical_value) DO UPDATE SET
            display_name = excluded.display_name,
            normalized_value = excluded.normalized_value,
            confidence = max(graph_entity.confidence, excluded.confidence),
            source = excluded.source,
            pii_class = COALESCE(excluded.pii_class, graph_entity.pii_class),
            metadata_json = COALESCE(excluded.metadata_json, graph_entity.metadata_json),
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
            workGraphBind(normalizedValue, at: 4, in: statement)
            sqlite3_bind_double(statement, 5, boundedConfidence)
            workGraphBind(cleanSource, at: 6, in: statement)
            workGraphBind(cleanPIIClass, at: 7, in: statement)
            workGraphBind(metadataJSON, at: 8, in: statement)
            workGraphBind(observed, at: 9, in: statement)
            workGraphBind(observed, at: 10, in: statement)
            workGraphBind(validStart, at: 11, in: statement)
            workGraphBind(validEnd, at: 12, in: statement)
            workGraphBind(transaction, at: 13, in: statement)
            workGraphBind(transaction, at: 14, in: statement)
            workGraphBind(transaction, at: 15, in: statement)
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
                validTo: validTo,
                confidence: boundedConfidence
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
        validTo: Date? = nil,
        confidence: Double = 1.0
    ) throws -> WorkGraphEntityAlias {
        let cleanAlias = WorkGraphPrivacy.safeAlias(alias)
        let normalized = WorkGraphNormalizer.normalizedAlias(cleanAlias)
        guard entityID > 0, !cleanAlias.isEmpty, !normalized.isEmpty else {
            throw CascadeStoreError.sqlite("work graph alias cannot be empty")
        }
        guard !PrivacyRules.isSensitiveText(cleanAlias), !PIIDetector.containsHighConfidencePII(cleanAlias) else {
            throw CascadeStoreError.sqlite("sensitive work graph alias refused")
        }
        let boundedConfidence = min(max(confidence, 0.0), 1.0)

        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)

        let sql = """
        INSERT INTO graph_entity_alias
            (entity_id, alias, normalized_alias, source, confidence, mention_count, first_seen_at,
             last_seen_at, valid_from, valid_to, transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(entity_id, normalized_alias) DO UPDATE SET
            alias = excluded.alias,
            source = excluded.source,
            confidence = max(graph_entity_alias.confidence, excluded.confidence),
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
            sqlite3_bind_double(statement, 5, boundedConfidence)
            workGraphBind(observed, at: 6, in: statement)
            workGraphBind(observed, at: 7, in: statement)
            workGraphBind(validStart, at: 8, in: statement)
            workGraphBind(validEnd, at: 9, in: statement)
            workGraphBind(transaction, at: 10, in: statement)
            workGraphBind(transaction, at: 11, in: statement)
            workGraphBind(transaction, at: 12, in: statement)
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
        validTo: Date? = nil,
        role: String = "observed",
        extractor: String = "manual",
        spanStart: Int? = nil,
        spanEnd: Int? = nil,
        confidence: Double = 1.0
    ) throws -> WorkGraphTimelineEntry? {
        guard contextID > 0, entityID > 0 else {
            throw CascadeStoreError.sqlite("work graph link requires context and entity ids")
        }
        guard let snippet = WorkGraphEvidence.snippet(from: evidence) else { return nil }
        let boundedConfidence = min(max(confidence, 0.0), 1.0)

        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)
        let trimmedRelation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRelation = trimmedRelation.isEmpty ? "observed" : trimmedRelation
        let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cleanRelation : role
        let cleanExtractor = extractor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "manual" : extractor

        let sql = """
        INSERT INTO context_entity_link
            (context_id, entity_id, relation, role, extractor, evidence_snippet, span_start, span_end,
             confidence, observed_at, valid_from, valid_to,
             transaction_from, transaction_to, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
        ON CONFLICT(context_id, entity_id, relation) DO UPDATE SET
            role = excluded.role,
            extractor = excluded.extractor,
            evidence_snippet = excluded.evidence_snippet,
            span_start = excluded.span_start,
            span_end = excluded.span_end,
            confidence = max(context_entity_link.confidence, excluded.confidence),
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
            workGraphBind(cleanRole, at: 4, in: statement)
            workGraphBind(cleanExtractor, at: 5, in: statement)
            workGraphBind(snippet, at: 6, in: statement)
            bindOptionalInt(spanStart, at: 7, in: statement)
            bindOptionalInt(spanEnd, at: 8, in: statement)
            sqlite3_bind_double(statement, 9, boundedConfidence)
            workGraphBind(observed, at: 10, in: statement)
            workGraphBind(validStart, at: 11, in: statement)
            workGraphBind(validEnd, at: 12, in: statement)
            workGraphBind(transaction, at: 13, in: statement)
            workGraphBind(transaction, at: 14, in: statement)
            workGraphBind(transaction, at: 15, in: statement)
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
               l.transaction_from, l.transaction_to, l.role, l.extractor, l.confidence
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
        weight: Double = 1.0,
        confidence: Double = 1.0,
        provenanceContextID: Int64? = nil,
        provenanceInputEventID: Int64? = nil,
        extractor: String = "manual",
        metadataJSON: String? = nil
    ) throws -> WorkGraphEdge? {
        guard sourceEntityID > 0, targetEntityID > 0 else {
            throw CascadeStoreError.sqlite("work graph edge requires source and target ids")
        }
        guard let snippet = WorkGraphEvidence.snippet(from: evidence) else { return nil }
        let cleanRelation = relation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "related" : relation
        let cleanExtractor = extractor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "manual" : extractor
        let boundedConfidence = min(max(confidence, 0.0), 1.0)
        let now = Date()
        let observed = WorkGraphDateCodec.string(from: observedAt)
        let validStart = WorkGraphDateCodec.string(from: validFrom ?? observedAt)
        let validEnd = validTo.map(WorkGraphDateCodec.string(from:))
        let transaction = WorkGraphDateCodec.string(from: now)
        let supersedesBySource = WorkGraphRelationPolicy.supersedesBySource(cleanRelation)

        try withStatement("""
        UPDATE graph_edge_assertion
        SET transaction_to = ?, updated_at = ?
        WHERE source_entity_id = ? AND relation = ? AND transaction_to IS NULL
          AND (target_entity_id = ? OR (? = 1 AND target_entity_id <> ?));
        """) { statement in
            workGraphBind(transaction, at: 1, in: statement)
            workGraphBind(transaction, at: 2, in: statement)
            sqlite3_bind_int64(statement, 3, sourceEntityID)
            workGraphBind(cleanRelation, at: 4, in: statement)
            sqlite3_bind_int64(statement, 5, targetEntityID)
            sqlite3_bind_int(statement, 6, supersedesBySource ? 1 : 0)
            sqlite3_bind_int64(statement, 7, targetEntityID)
            try stepDone(statement)
        }

        if supersedesBySource {
            try withStatement("""
            UPDATE graph_edge
            SET transaction_to = ?, updated_at = ?
            WHERE source_entity_id = ? AND relation = ? AND target_entity_id <> ? AND transaction_to IS NULL;
            """) { statement in
                workGraphBind(transaction, at: 1, in: statement)
                workGraphBind(transaction, at: 2, in: statement)
                sqlite3_bind_int64(statement, 3, sourceEntityID)
                workGraphBind(cleanRelation, at: 4, in: statement)
                sqlite3_bind_int64(statement, 5, targetEntityID)
                try stepDone(statement)
            }
        }

        try withStatement("""
        INSERT INTO graph_edge_assertion
            (source_entity_id, target_entity_id, relation, evidence_snippet, weight,
             first_seen_at, last_seen_at, valid_from, valid_to, transaction_from, transaction_to,
             confidence, provenance_context_id, provenance_input_event_id, extractor, metadata_json,
             created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            sqlite3_bind_int64(statement, 1, sourceEntityID)
            sqlite3_bind_int64(statement, 2, targetEntityID)
            workGraphBind(cleanRelation, at: 3, in: statement)
            workGraphBind(snippet, at: 4, in: statement)
            sqlite3_bind_double(statement, 5, weight)
            workGraphBind(observed, at: 6, in: statement)
            workGraphBind(observed, at: 7, in: statement)
            workGraphBind(validStart, at: 8, in: statement)
            workGraphBind(validEnd, at: 9, in: statement)
            workGraphBind(transaction, at: 10, in: statement)
            sqlite3_bind_double(statement, 11, boundedConfidence)
            bindOptionalInt64(provenanceContextID, at: 12, in: statement)
            bindOptionalInt64(provenanceInputEventID, at: 13, in: statement)
            workGraphBind(cleanExtractor, at: 14, in: statement)
            workGraphBind(metadataJSON, at: 15, in: statement)
            workGraphBind(transaction, at: 16, in: statement)
            workGraphBind(transaction, at: 17, in: statement)
            try stepDone(statement)
        }

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
            transaction_from = excluded.transaction_from,
            transaction_to = NULL,
            updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, sourceEntityID)
            sqlite3_bind_int64(statement, 2, targetEntityID)
            workGraphBind(cleanRelation, at: 3, in: statement)
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

        try withStatement("""
        UPDATE graph_edge
        SET confidence = ?, provenance_context_id = ?, provenance_input_event_id = ?,
            extractor = ?, metadata_json = ?
        WHERE source_entity_id = ? AND target_entity_id = ? AND relation = ?;
        """) { statement in
            sqlite3_bind_double(statement, 1, boundedConfidence)
            bindOptionalInt64(provenanceContextID, at: 2, in: statement)
            bindOptionalInt64(provenanceInputEventID, at: 3, in: statement)
            workGraphBind(cleanExtractor, at: 4, in: statement)
            workGraphBind(metadataJSON, at: 5, in: statement)
            sqlite3_bind_int64(statement, 6, sourceEntityID)
            sqlite3_bind_int64(statement, 7, targetEntityID)
            workGraphBind(cleanRelation, at: 8, in: statement)
            try stepDone(statement)
        }

        return try graphEdge(sourceEntityID: sourceEntityID, targetEntityID: targetEntityID, relation: cleanRelation)
    }

    @discardableResult
    func indexPlanningSkill(
        name: String,
        appNames: [String] = [],
        useWhen: String = "",
        dangerous: Bool = false
    ) throws -> WorkGraphEntity {
        let skill = try upsertGraphEntity(
            kind: .skill,
            canonicalValue: name,
            displayName: name,
            aliases: [name],
            aliasSource: "app_skill"
        )
        for appName in appNames {
            let clean = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let app = try upsertGraphEntity(kind: .app, canonicalValue: clean, displayName: clean, aliasSource: "app_skill")
            _ = try upsertGraphEdge(
                sourceEntityID: skill.id,
                targetEntityID: app.id,
                relation: "covers_app",
                evidence: "\(name) covers \(clean)",
                weight: 1.0
            )
        }
        let trimmedUseWhen = useWhen.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUseWhen.isEmpty {
            let subgoal = try upsertGraphEntity(
                kind: .subgoalType,
                canonicalValue: trimmedUseWhen,
                displayName: String(trimmedUseWhen.prefix(80)),
                aliases: [trimmedUseWhen],
                aliasSource: "app_skill"
            )
            _ = try upsertGraphEdge(
                sourceEntityID: skill.id,
                targetEntityID: subgoal.id,
                relation: "has_subgoal",
                evidence: trimmedUseWhen,
                weight: 0.75
            )
        }
        if dangerous {
            let effect = try upsertGraphEntity(
                kind: .expectedEffect,
                canonicalValue: "dangerous",
                displayName: "Dangerous action",
                aliases: ["dangerous"],
                aliasSource: "app_skill"
            )
            _ = try upsertGraphEdge(
                sourceEntityID: skill.id,
                targetEntityID: effect.id,
                relation: "dangerous",
                evidence: "\(name) is explicit-ask-only or mutates outside the UI",
                weight: -1.0
            )
        }
        return skill
    }

    @discardableResult
    func indexAgentExperienceOutcome(_ experience: AgentExperienceCase) throws -> WorkGraphEntity {
        let app = try upsertGraphEntity(
            kind: .app,
            canonicalValue: experience.appName,
            displayName: experience.appName,
            aliasSource: "experience"
        )
        let recipe = try upsertGraphEntity(
            kind: .recipe,
            canonicalValue: experience.recipeSignature,
            displayName: experience.goalPattern,
            aliases: [experience.recipeSignature, experience.goalPattern],
            aliasSource: "experience"
        )
        _ = try upsertGraphEdge(
            sourceEntityID: app.id,
            targetEntityID: recipe.id,
            relation: "has_subgoal",
            evidence: "\(experience.outcome.rawValue): \(experience.goalPattern)",
            weight: experience.retainedScore
        )
        if let skillSlug = experience.skillSlug {
            let skill = try upsertGraphEntity(
                kind: .skill,
                canonicalValue: skillSlug,
                displayName: skillSlug,
                aliases: [skillSlug],
                aliasSource: "experience"
            )
            _ = try upsertGraphEdge(
                sourceEntityID: recipe.id,
                targetEntityID: skill.id,
                relation: "uses_skill",
                evidence: "\(experience.goalPattern) used \(skillSlug)",
                weight: max(0.1, experience.retainedScore)
            )
        }
        if let signal = experience.verificationSignal {
            let effect = try upsertGraphEntity(
                kind: .expectedEffect,
                canonicalValue: signal.rawValue,
                displayName: signal.rawValue,
                aliases: [signal.rawValue],
                aliasSource: "experience"
            )
            _ = try upsertGraphEdge(
                sourceEntityID: recipe.id,
                targetEntityID: effect.id,
                relation: "produces_effect",
                evidence: "\(experience.goalPattern) produced \(signal.rawValue)",
                weight: max(0.1, experience.retainedScore)
            )
        }
        if let failure = experience.failureKind {
            let effect = try upsertGraphEntity(
                kind: .expectedEffect,
                canonicalValue: failure.rawValue,
                displayName: failure.rawValue,
                aliases: [failure.rawValue],
                aliasSource: "experience"
            )
            let relation = failure == .loginRequired ? "requires_login" : "produces_effect"
            _ = try upsertGraphEdge(
                sourceEntityID: recipe.id,
                targetEntityID: effect.id,
                relation: relation,
                evidence: "\(experience.goalPattern) failed with \(failure.rawValue)",
                weight: min(-0.1, experience.retainedScore)
            )
        }
        return recipe
    }

    func planningPriors(goal: String, appName: String?, limit: Int = 8) throws -> [WorkGraphPlanningPrior] {
        guard limit > 0 else { return [] }
        let normalizedApp = WorkGraphNormalizer.normalizedAlias(appName ?? "")
        let goalTokens = Set(WorkGraphNormalizer.normalizedAlias(goal).split(separator: " ").map(String.init))
        let sql = """
        SELECT e.kind, e.canonical_value, e.display_name,
               COALESCE(edge.relation, '') AS relation,
               COALESCE(edge.weight, 0.0) AS weight,
               COALESCE(edge.evidence_snippet, '') AS evidence
        FROM graph_entity e
        LEFT JOIN graph_edge edge ON edge.source_entity_id = e.id OR edge.target_entity_id = e.id
        LEFT JOIN graph_entity other ON
             (edge.source_entity_id = e.id AND other.id = edge.target_entity_id)
          OR (edge.target_entity_id = e.id AND other.id = edge.source_entity_id)
        WHERE e.kind IN ('skill', 'recipe', 'subgoal_type', 'expected_effect')
        ORDER BY abs(COALESCE(edge.weight, 0.0)) DESC, e.last_seen_at DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(max(limit * 4, limit)))
            var rows: [WorkGraphPlanningPrior] = []
            var seen: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let kind = WorkGraphEntityKind(rawValue: workGraphText(statement, 0) ?? "") ?? .recipe
                let canonical = workGraphText(statement, 1) ?? ""
                let display = workGraphText(statement, 2) ?? ""
                let relation = workGraphText(statement, 3) ?? ""
                let evidence = workGraphText(statement, 5) ?? ""
                let haystack = WorkGraphNormalizer.normalizedAlias([display, canonical, evidence, relation].joined(separator: " "))
                let appMatches = normalizedApp.isEmpty || haystack.contains(normalizedApp)
                let goalMatches = goalTokens.isEmpty || goalTokens.contains { haystack.contains($0) }
                guard appMatches || goalMatches || relation == "dangerous" else { continue }
                let key = "\(kind.rawValue):\(canonical):\(relation)"
                guard seen.insert(key).inserted else { continue }
                rows.append(WorkGraphPlanningPrior(
                    kind: kind,
                    canonicalValue: canonical,
                    displayName: display,
                    relation: relation.isEmpty ? "prior" : relation,
                    weight: sqlite3_column_double(statement, 4),
                    evidenceSnippet: evidence
                ))
            }
            return Array(rows.sorted {
                if ($0.weight < 0) != ($1.weight < 0) { return $0.weight < 0 }
                if abs($0.weight) == abs($1.weight) { return $0.displayName < $1.displayName }
                return abs($0.weight) > abs($1.weight)
            }.prefix(limit))
        }
    }

    func graphEntity(kind: WorkGraphEntityKind, canonicalValue: String) throws -> WorkGraphEntity {
        let canonical = WorkGraphNormalizer.canonical(kind: kind, value: canonicalValue)
        let sql = """
        SELECT id, kind, canonical_value, display_name, first_seen_at, last_seen_at,
               valid_from, valid_to, transaction_from, transaction_to,
               normalized_value, confidence, source, pii_class, metadata_json
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
               valid_from, valid_to, transaction_from, transaction_to, confidence
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

    func graphTimeline(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        limit: Int = 20,
        newestFirst: Bool = false
    ) throws -> [WorkGraphTimelineEntry] {
        do {
            let entity = try graphEntity(kind: kind, canonicalValue: canonicalValue)
            return try entityTimeline(entityID: entity.id, limit: limit, newestFirst: newestFirst)
        } catch CascadeStoreError.sqlite(let message) where message.contains("work graph entity not found") {
            return []
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
               l.transaction_from, l.transaction_to, l.role, l.extractor, l.confidence
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

    func currentGraphEdges(limit: Int = 100) throws -> [WorkGraphEdge] {
        guard limit > 0 else { return [] }
        let now = WorkGraphDateCodec.string(from: Date())
        let sql = """
        SELECT id, source_entity_id, target_entity_id, relation, evidence_snippet, weight,
               first_seen_at, last_seen_at, valid_from, valid_to, transaction_from, transaction_to,
               confidence, provenance_context_id, provenance_input_event_id, extractor, metadata_json
        FROM graph_edge
        WHERE transaction_to IS NULL AND (valid_to IS NULL OR valid_to > ?)
        ORDER BY last_seen_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            workGraphBind(now, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [WorkGraphEdge] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeGraphEdge(statement))
            }
            return rows
        }
    }

    func graphEdges(asOf asOfDate: Date, limit: Int = 100) throws -> [WorkGraphEdge] {
        guard limit > 0 else { return [] }
        let asOf = WorkGraphDateCodec.string(from: asOfDate)
        let sql = """
        SELECT id, source_entity_id, target_entity_id, relation, evidence_snippet, weight,
               first_seen_at, last_seen_at, valid_from, valid_to, transaction_from, transaction_to,
               confidence, provenance_context_id, provenance_input_event_id, extractor, metadata_json
        FROM graph_edge_assertion
        WHERE transaction_from <= ?
          AND (transaction_to IS NULL OR transaction_to > ?)
          AND valid_from <= ?
          AND (valid_to IS NULL OR valid_to > ?)
        ORDER BY valid_from ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            workGraphBind(asOf, at: 1, in: statement)
            workGraphBind(asOf, at: 2, in: statement)
            workGraphBind(asOf, at: 3, in: statement)
            workGraphBind(asOf, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(limit))
            var rows: [WorkGraphEdge] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeGraphEdge(statement))
            }
            return rows
        }
    }

    private func graphEdge(sourceEntityID: Int64, targetEntityID: Int64, relation: String) throws -> WorkGraphEdge {
        let sql = """
        SELECT id, source_entity_id, target_entity_id, relation, evidence_snippet, weight,
               first_seen_at, last_seen_at, valid_from, valid_to, transaction_from, transaction_to,
               confidence, provenance_context_id, provenance_input_event_id, extractor, metadata_json
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
            return decodeGraphEdge(statement)
        }
    }
}

private enum WorkGraphNormalizer {
    static func canonical(kind: WorkGraphEntityKind, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .app, .window, .organization, .project, .task, .topic, .skill, .recipe, .subgoalType, .expectedEffect:
            return normalizedAlias(trimmed)
        case .person:
            return privacySafePersonCanonical(trimmed)
        case .url:
            if let url = URL(string: trimmed), let canonical = canonicalURL(url) {
                return canonical
            }
            return trimmed.lowercased()
        case .file, .folder:
            return safeFilePath(trimmed)
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

    static func normalizedValue(kind: WorkGraphEntityKind, canonicalValue: String) -> String {
        switch kind {
        case .url:
            return URL(string: canonicalValue)?.host.map(normalizedDomain) ?? normalizedAlias(canonicalValue)
        case .file, .folder:
            return safeFilePath(canonicalValue)
        default:
            return normalizedAlias(canonicalValue)
        }
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

    static func safeFilePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return replacingHomeDirectoryUser(in: standardized)
    }

    static func normalizedDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
            .lowercased()
            .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    }

    static func organizationFromDomain(_ domain: String) -> String {
        let normalized = normalizedDomain(domain)
        let parts = normalized.split(separator: ".").map(String.init)
        guard let candidate = parts.dropLast().last ?? parts.first else { return "" }
        return normalizedAlias(candidate.replacingOccurrences(of: "-", with: " "))
    }

    static func replacingHomeDirectoryUser(in value: String) -> String {
        value.replacingOccurrences(
            of: #"(^|/)(Users|home)/[^/\s]+"#,
            with: "$1$2/<user>",
            options: .regularExpression
        )
    }

    static func privacySafePersonCanonical(_ value: String) -> String {
        let normalized = normalizedAlias(value)
        if normalized.range(of: #"^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil {
            return "email:\(AuditIdentity.hash(normalized))"
        }
        if PIIDetector.containsHighConfidencePII(value) {
            return "pii:\(AuditIdentity.hash(normalized))"
        }
        return normalized
    }
}

private enum WorkGraphEvidence {
    static func snippet(from evidence: String, maxLength: Int = 180) -> String? {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !PrivacyRules.isSensitiveText(trimmed) else { return nil }
        let redacted = redact(trimmed)
        guard !PIIDetector.containsHighConfidencePII(redacted),
              !PrivacyRules.isSensitiveText(redacted) else { return nil }
        if redacted.count <= maxLength { return redacted }
        return String(redacted.prefix(maxLength - 1)) + "..."
    }

    private static func redact(_ value: String) -> String {
        var redacted = PIIDetector.redact(value, includeNames: false, highConfidenceOnly: false).redacted
        redacted = PrivacyRules.redactingSensitiveKeywords(in: redacted)
        redacted = WorkGraphNormalizer.replacingHomeDirectoryUser(in: redacted)
        redacted = replace(#"\?[^#\s]+"#, in: redacted, with: "?<REDACTED_QUERY>")
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
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 9)),
        normalizedValue: workGraphText(statement, 10),
        confidence: sqlite3_column_type(statement, 11) == SQLITE_NULL ? 1.0 : sqlite3_column_double(statement, 11),
        source: workGraphText(statement, 12) ?? "legacy",
        piiClass: workGraphText(statement, 13),
        metadataJSON: workGraphText(statement, 14)
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
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 11)),
        confidence: sqlite3_column_type(statement, 12) == SQLITE_NULL ? 1.0 : sqlite3_column_double(statement, 12)
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
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 12)),
        role: workGraphText(statement, 13) ?? "observed",
        extractor: workGraphText(statement, 14) ?? "legacy",
        confidence: sqlite3_column_type(statement, 15) == SQLITE_NULL ? 1.0 : sqlite3_column_double(statement, 15)
    )
}

private func decodeGraphEdge(_ statement: OpaquePointer) -> WorkGraphEdge {
    WorkGraphEdge(
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
        transactionTo: WorkGraphDateCodec.date(from: workGraphText(statement, 11)),
        confidence: sqlite3_column_type(statement, 12) == SQLITE_NULL ? 1.0 : sqlite3_column_double(statement, 12),
        provenanceContextID: optionalInt64(statement, 13),
        provenanceInputEventID: optionalInt64(statement, 14),
        extractor: workGraphText(statement, 15) ?? "legacy",
        metadataJSON: workGraphText(statement, 16)
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

private func bindOptionalInt(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int(statement, index, Int32(value))
}

private func bindOptionalInt64(_ value: Int64?, at index: Int32, in statement: OpaquePointer) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, value)
}

private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
}

private func workGraphEntityKey(kind: WorkGraphEntityKind, canonicalValue: String) -> String {
    "\(kind.rawValue):\(WorkGraphNormalizer.canonical(kind: kind, value: canonicalValue))"
}

private func workGraphMetadata(_ values: [String: String]) -> String? {
    let clean = values.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !clean.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
}

private enum WorkGraphRelationPolicy {
    static func supersedesBySource(_ relation: String) -> Bool {
        switch relation {
        case "IN_FOLDER", "DUE_ON":
            return true
        default:
            return false
        }
    }
}

private enum WorkGraphPrivacy {
    static func safeEntityValues(
        kind: WorkGraphEntityKind,
        canonicalValue: String,
        displayName: String,
        piiClass: String?
    ) throws -> (canonical: String, display: String, piiClass: String?) {
        let canonical = WorkGraphNormalizer.canonical(kind: kind, value: canonicalValue)
        var display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var effectivePIIClass = piiClass
        if PIIDetector.containsHighConfidencePII(display) {
            effectivePIIClass = effectivePIIClass ?? PIIDetector.findings(in: display).first(where: { $0.type.isHighConfidence })?.type.rawValue
            display = "\(kind.rawValue) \(AuditIdentity.hash(display))"
        }
        display = WorkGraphNormalizer.replacingHomeDirectoryUser(in: display)
        display = PIIDetector.redact(display, includeNames: false, highConfidenceOnly: true).redacted
        display = PrivacyRules.redactingSensitiveKeywords(in: display)
        let cleanDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PIIDetector.containsHighConfidencePII(canonical),
              !PIIDetector.containsHighConfidencePII(cleanDisplay) else {
            throw CascadeStoreError.sqlite("sensitive work graph entity refused")
        }
        return (canonical, cleanDisplay.isEmpty ? canonical : cleanDisplay, effectivePIIClass)
    }

    static func safeAlias(_ alias: String) -> String {
        var clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if PIIDetector.containsHighConfidencePII(clean) {
            clean = "alias \(AuditIdentity.hash(clean.lowercased()))"
        }
        clean = WorkGraphNormalizer.replacingHomeDirectoryUser(in: clean)
        clean = PIIDetector.redact(clean, includeNames: false, highConfidenceOnly: true).redacted
        return PrivacyRules.redactingSensitiveKeywords(in: clean)
    }
}
