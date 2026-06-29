import Foundation
import SQLite3

public enum ContextSource: String, Codable, Sendable {
    case screen
    case app
    case accessibility
    case input
    case system
}

public struct RecordedContext: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let capturedAt: Date
    public let source: ContextSource
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let ocrText: String?
    public let imagePath: String?
    public let metadataJSON: String?
    /// Perceptual fingerprint of the captured frame, used to dedupe near-identical
    /// moments across restarts. `nil` for rows without a frame (e.g. app-only ticks).
    public let frameHash: Int64?
    public let sourceTrust: String
    public let rawTrustLabel: String?
    public let injectionScore: Int
    public let injectionReasonsJSON: String?
    public let userConfirmed: Bool
    public let safeToShow: Bool
    public let safeToSummarize: Bool
    public let safeForControl: Bool

    public init(
        id: Int64 = 0,
        capturedAt: Date = Date(),
        source: ContextSource,
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        ocrText: String? = nil,
        imagePath: String? = nil,
        metadataJSON: String? = nil,
        frameHash: Int64? = nil,
        sourceTrust: String? = nil,
        rawTrustLabel: String? = nil,
        injectionScore: Int = 0,
        injectionReasonsJSON: String? = nil,
        userConfirmed: Bool = false,
        safeToShow: Bool = true,
        safeToSummarize: Bool = true,
        safeForControl: Bool? = nil
    ) {
        let defaults = Self.trustDefaults(for: source)
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.imagePath = imagePath
        self.metadataJSON = metadataJSON
        self.frameHash = frameHash
        self.sourceTrust = sourceTrust ?? defaults.trust
        self.rawTrustLabel = rawTrustLabel
        self.injectionScore = max(0, injectionScore)
        self.injectionReasonsJSON = injectionReasonsJSON
        self.userConfirmed = userConfirmed
        self.safeToShow = safeToShow
        self.safeToSummarize = safeToSummarize
        self.safeForControl = safeForControl ?? defaults.safeForControl
    }

    private static func trustDefaults(for source: ContextSource) -> (trust: String, safeForControl: Bool) {
        switch source {
        case .input:
            return ("trustedUserInstruction", true)
        case .system:
            return ("trustedRuntimePolicy", true)
        case .app:
            return ("trustedLocalMetadata", false)
        case .screen, .accessibility:
            return ("untrustedScreen", false)
        }
    }
}

public struct PrivacyDataScope: Codable, Equatable, Sendable {
    public var source: ContextSource?
    public var appName: String?
    public var bundleIdentifier: String?
    public var start: Date?
    public var end: Date?

    public init(
        source: ContextSource? = nil,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        start: Date? = nil,
        end: Date? = nil
    ) {
        self.source = source
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.start = start
        self.end = end
    }
}

public struct PrivacySummaryBucket: Codable, Equatable, Sendable {
    public let source: ContextSource
    public let appName: String
    public let bundleIdentifier: String?
    public let count: Int
    public let firstCapturedAt: Date
    public let lastCapturedAt: Date
    public let estimatedFrameBytes: Int64

    public init(
        source: ContextSource,
        appName: String,
        bundleIdentifier: String?,
        count: Int,
        firstCapturedAt: Date,
        lastCapturedAt: Date,
        estimatedFrameBytes: Int64
    ) {
        self.source = source
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.count = count
        self.firstCapturedAt = firstCapturedAt
        self.lastCapturedAt = lastCapturedAt
        self.estimatedFrameBytes = estimatedFrameBytes
    }
}

public struct PrivacySummary: Codable, Equatable, Sendable {
    public let scope: PrivacyDataScope
    public let totalContexts: Int
    public let firstCapturedAt: Date?
    public let lastCapturedAt: Date?
    public let estimatedFrameBytes: Int64
    public let buckets: [PrivacySummaryBucket]
    public let policyVersion: String
    public let retentionByDataClass: [String: CaptureRetentionPolicy]

    public init(
        scope: PrivacyDataScope,
        totalContexts: Int,
        firstCapturedAt: Date?,
        lastCapturedAt: Date?,
        estimatedFrameBytes: Int64,
        buckets: [PrivacySummaryBucket],
        policyVersion: String,
        retentionByDataClass: [String: CaptureRetentionPolicy]
    ) {
        self.scope = scope
        self.totalContexts = totalContexts
        self.firstCapturedAt = firstCapturedAt
        self.lastCapturedAt = lastCapturedAt
        self.estimatedFrameBytes = estimatedFrameBytes
        self.buckets = buckets
        self.policyVersion = policyVersion
        self.retentionByDataClass = retentionByDataClass
    }
}

public struct PrivacyExportManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let summary: PrivacySummary
    public let omittedFields: [String]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        summary: PrivacySummary,
        omittedFields: [String] = ["ocr_text", "image_path", "metadata_json", "input_event.text", "input_event.target_descriptor"]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.summary = summary
        self.omittedFields = omittedFields
    }
}

public struct PrivacyDeletionResult: Codable, Equatable, Sendable {
    public let deletedContextCount: Int
    public let deletedInputEventCount: Int
    public let backingImagePaths: [String]

    public init(deletedContextCount: Int, deletedInputEventCount: Int, backingImagePaths: [String]) {
        self.deletedContextCount = deletedContextCount
        self.deletedInputEventCount = deletedInputEventCount
        self.backingImagePaths = backingImagePaths
    }
}

public struct HybridContextCandidate: Equatable, Sendable {
    public let candidate: RankFusion.FusedCandidate
    public let context: RecordedContext

    public init(candidate: RankFusion.FusedCandidate, context: RecordedContext) {
        self.candidate = candidate
        self.context = context
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let actor: String
    public let action: String
    public let detail: String

    public init(id: Int64 = 0, createdAt: Date = Date(), actor: String, action: String, detail: String) {
        self.id = id
        self.createdAt = createdAt
        self.actor = actor
        self.action = action
        self.detail = detail
    }
}

public enum PreferenceEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case agentProposed = "agent.proposed"
    case agentApproved = "agent.approved"
    case agentDeclined = "agent.declined"
    case agentRunCompleted = "agent.run.completed"
    case agentScheduleSet = "agent.schedule.set"
    case agentScheduleCleared = "agent.schedule.cleared"
    case agentEnabled = "agent.enabled"
    case agentDisabled = "agent.disabled"
    case agentDeleted = "agent.deleted"
    case proactiveAccepted = "proactive.accept"
    case proactiveSnoozed = "proactive.snooze"
    case proactiveDismissed = "proactive.dismiss"
    case proactiveOfferShown = "proactive.offer.shown"
    case proactiveOfferSuppressed = "proactive.offer.suppressed"
    case coldStartSet = "cold_start.set"
    case personalizationCleared = "personalization.cleared"
    case personalizationDisabled = "personalization.disabled"
}

public struct PreferenceEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let kind: PreferenceEventKind
    public let reward: Double
    public let surface: String?
    public let appName: String?
    public let workflowSignature: String?
    public let agentID: Int64?
    public let featureJSON: String
    public let evidenceJSON: String?

    public init(
        id: Int64 = 0,
        createdAt: Date = Date(),
        kind: PreferenceEventKind,
        reward: Double,
        surface: String? = nil,
        appName: String? = nil,
        workflowSignature: String? = nil,
        agentID: Int64? = nil,
        featureJSON: String = "{}",
        evidenceJSON: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.reward = max(-1, min(1, reward))
        self.surface = surface
        self.appName = appName
        self.workflowSignature = workflowSignature
        self.agentID = agentID
        self.featureJSON = featureJSON.isEmpty ? "{}" : featureJSON
        self.evidenceJSON = evidenceJSON
    }
}

public struct RoutineProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let appName: String
    public let surface: String
    public let weekday: Int
    public let hourBucket: Int
    public let workflowSignature: String?
    public let shown: Int
    public let accepted: Int
    public let dismissedSnoozed: Int
    public let completed: Int
    public let scheduled: Int
    public let disabledDeleted: Int
    public let lastSeenAt: Date
    public let metadataJSON: String

    public init(
        id: Int64 = 0,
        appName: String,
        surface: String,
        weekday: Int,
        hourBucket: Int,
        workflowSignature: String? = nil,
        shown: Int = 0,
        accepted: Int = 0,
        dismissedSnoozed: Int = 0,
        completed: Int = 0,
        scheduled: Int = 0,
        disabledDeleted: Int = 0,
        lastSeenAt: Date = Date(),
        metadataJSON: String = "{}"
    ) {
        self.id = id
        self.appName = appName
        self.surface = surface
        self.weekday = weekday
        self.hourBucket = hourBucket
        self.workflowSignature = workflowSignature
        self.shown = shown
        self.accepted = accepted
        self.dismissedSnoozed = dismissedSnoozed
        self.completed = completed
        self.scheduled = scheduled
        self.disabledDeleted = disabledDeleted
        self.lastSeenAt = lastSeenAt
        self.metadataJSON = metadataJSON
    }
}

public struct PersonalizationSnapshot: Codable, Equatable, Sendable {
    public let eventCount: Int
    public let routineProfileCount: Int
    public let disabledSignatureCount: Int
    public let disabledAppCount: Int
    public let lastEventAt: Date?

    public init(
        eventCount: Int,
        routineProfileCount: Int,
        disabledSignatureCount: Int,
        disabledAppCount: Int,
        lastEventAt: Date?
    ) {
        self.eventCount = eventCount
        self.routineProfileCount = routineProfileCount
        self.disabledSignatureCount = disabledSignatureCount
        self.disabledAppCount = disabledAppCount
        self.lastEventAt = lastEventAt
    }
}

// MARK: - Input events (the user's actual clicks/keys, recorded for workflow learning)

public enum InputEventKind: String, Codable, Sendable {
    case click
    case doubleClick
    case rightClick
    case type
    case key
    case scroll
}

/// One recorded user action. Local-only; written only when the privacy gate
/// passes (see `InputRecorder`). Coordinates are global screen points.
public struct InputEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let capturedAt: Date
    public let kind: InputEventKind
    public let x: Double?
    public let y: Double?
    public let text: String?
    public let key: String?
    public let modifiers: [String]
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    /// For clicks: a stable AX descriptor of the clicked element (encoded
    /// `role`+`identifier` via `AXTargetDescriptor`), captured live at record time.
    /// `text` carries the human label; this carries the locator the replay cascade
    /// ranks on so a moved/renamed control is still re-found. `nil` for keys/scrolls
    /// and for clicks whose element exposed neither a role nor an identifier.
    public let targetDescriptor: String?

    public init(
        id: Int64 = 0,
        capturedAt: Date = Date(),
        kind: InputEventKind,
        x: Double? = nil,
        y: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String] = [],
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        targetDescriptor: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.targetDescriptor = targetDescriptor
    }
}

public enum InputEventSanitizer {
    public static func typedShape(for text: String) -> String {
        "typed \(text.count) chars"
    }

    public static func sanitize(text: String?, kind: InputEventKind) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if kind == .type {
            if text.range(of: #"^typed \d+ chars$"#, options: .regularExpression) != nil {
                return text
            }
            return typedShape(for: text)
        }
        if PrivacyRules.isSensitiveText(text) { return nil }
        let redacted = PIIDetector.redact(text, includeNames: false, highConfidenceOnly: false).redacted
        let keywordRedacted = PrivacyRules.redactingSensitiveKeywords(in: redacted)
        return keywordRedacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : keywordRedacted
    }

    public static func sanitize(descriptor: String?) -> String? {
        guard let descriptor, !descriptor.isEmpty else { return nil }
        if PrivacyRules.isSensitiveText(descriptor) { return nil }
        let redacted = PIIDetector.redact(descriptor, includeNames: false, highConfidenceOnly: false).redacted
        return PrivacyRules.redactingSensitiveKeywords(in: redacted)
    }
}

public enum RecipeActionIdentity {
    public static func key(for step: RecipeStep) -> String {
        key(
            kind: step.kind.rawValue,
            appSurface: step.appName,
            bundleIdentifier: step.bundleIdentifier,
            windowTitle: step.windowTitleHint,
            targetDescriptor: step.targetDescriptor,
            label: step.kind == .type ? nil : (step.ocrAnchor ?? step.text),
            key: step.kind == .key ? step.key : nil,
            modifiers: step.kind == .key ? step.modifiers : [],
            isParameter: step.isParameter,
            parameterKey: step.parameterKey,
            parameterKind: step.parameterKind?.rawValue
        )
    }

    public static func key(for event: InputEvent, surface: String? = nil) -> String {
        key(
            kind: recipeKind(for: event.kind),
            appSurface: surface ?? event.appName,
            bundleIdentifier: event.bundleIdentifier,
            windowTitle: event.windowTitle,
            targetDescriptor: event.targetDescriptor,
            label: event.kind == .type ? nil : event.text,
            key: event.kind == .key ? event.key : nil,
            modifiers: event.kind == .key ? event.modifiers : [],
            isParameter: false,
            parameterKey: nil,
            parameterKind: nil
        )
    }

    public static func hash(_ key: String) -> String {
        AuditIdentity.hash(key)
    }

    public static func normalizedComponent(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let parts = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private static func key(
        kind: String,
        appSurface: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        targetDescriptor: String?,
        label: String?,
        key: String?,
        modifiers: [String],
        isParameter: Bool,
        parameterKey: String?,
        parameterKind: String?
    ) -> String {
        let modifierKey = modifiers.map { normalizedComponent($0) }.filter { !$0.isEmpty }.sorted().joined(separator: "+")
        let parts = [
            "v1",
            "kind=\(normalizedComponent(kind))",
            "surface=\(normalizedComponent(appSurface))",
            "bundle=\(normalizedComponent(bundleIdentifier))",
            "window=\(normalizedComponent(windowTitle))",
            "target=\(normalizedComponent(targetDescriptor))",
            "label=\(normalizedComponent(label))",
            "key=\(normalizedComponent(key))",
            "modifiers=\(modifierKey)",
            "parameter=\(isParameter ? "1" : "0")",
            "parameterKey=\(normalizedComponent(parameterKey))",
            "parameterKind=\(normalizedComponent(parameterKind))",
        ]
        return parts.joined(separator: "|")
    }

    private static func recipeKind(for kind: InputEventKind) -> String {
        switch kind {
        case .click: RecipeStepKind.click.rawValue
        case .doubleClick: RecipeStepKind.doubleClick.rawValue
        case .rightClick: RecipeStepKind.rightClick.rawValue
        case .type: RecipeStepKind.type.rawValue
        case .key: RecipeStepKind.key.rawValue
        case .scroll: RecipeStepKind.scroll.rawValue
        }
    }
}

public extension InputEvent {
    func idempotentActionKey(surface: String? = nil) -> String {
        RecipeActionIdentity.key(for: self, surface: surface)
    }

    func idempotentActionKeyHash(surface: String? = nil) -> String {
        RecipeActionIdentity.hash(idempotentActionKey(surface: surface))
    }
}

public struct OCRLine: Codable, Equatable, Sendable {
    public let contextID: Int64
    public let lineIndex: Int
    public let source: String
    public let text: String
    public let x: Double?
    public let y: Double?
    public let width: Double?
    public let height: Double?
    public let confidence: Double?

    public init(
        contextID: Int64,
        lineIndex: Int,
        source: String,
        text: String,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        confidence: Double? = nil
    ) {
        self.contextID = contextID
        self.lineIndex = lineIndex
        self.source = source
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}

public struct StoredOCRStructure: Codable, Equatable, Sendable {
    public let contextID: Int64
    public let version: Int
    public let json: String
    public let searchableText: String

    public init(contextID: Int64, version: Int, json: String, searchableText: String) {
        self.contextID = contextID
        self.version = version
        self.json = json
        self.searchableText = searchableText
    }
}

public struct StoredFrameSignature: Codable, Equatable, Sendable {
    public let contextID: Int64
    public let dHash: Int64
    public let combinedGridHash: Int64
    public let gridHashes: [Int64]
    public let blockHash: Int64
    public let changedCellsMask: UInt16
    public let textDigest: Int64?

    public init(
        contextID: Int64,
        dHash: Int64,
        combinedGridHash: Int64,
        gridHashes: [Int64],
        blockHash: Int64,
        changedCellsMask: UInt16,
        textDigest: Int64? = nil
    ) {
        self.contextID = contextID
        self.dHash = dHash
        self.combinedGridHash = combinedGridHash
        self.gridHashes = gridHashes
        self.blockHash = blockHash
        self.changedCellsMask = changedCellsMask
        self.textDigest = textDigest
    }
}

public struct TimelineEpisode: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let startAt: Date
    public let endAt: Date
    public let bundleIdentifier: String?
    public let appName: String
    public let windowTitleHint: String?
    public let contextCount: Int
    public let representativeContextID: Int64
    public let summaryText: String?

    public init(
        id: Int64,
        startAt: Date,
        endAt: Date,
        bundleIdentifier: String?,
        appName: String,
        windowTitleHint: String?,
        contextCount: Int,
        representativeContextID: Int64,
        summaryText: String?
    ) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitleHint = windowTitleHint
        self.contextCount = contextCount
        self.representativeContextID = representativeContextID
        self.summaryText = summaryText
    }
}

/// Canonical encoding for the stable AX locator recorded with a click — `role`,
/// `identifier`, and the structural `container` (parent role+title) packed into one
/// string so the replay cascade can rank candidates by identity (XCUIAutomation-style:
/// identifier most stable, role disambiguates equal labels) and, when labels are
/// identical (grid cells, repeated buttons), by their structural container
/// (Healenium-style). One source of truth shared by the recorder (write) and the
/// replay path (read); pure and unit-pinned. Backward compatible: a string without
/// the separator decodes to all-`nil`, a 2-field (pre-B2) string yields a `nil`
/// container, and old rows are simply `nil`.
public enum AXTargetDescriptor {
    /// U+001F UNIT SEPARATOR — a control char that never appears in a UI label.
    static let separator = "\u{1F}"

    /// Packs role+identifier+container; `nil` when all are empty (nothing to record).
    public static func encode(role: String?, identifier: String?, container: String? = nil) -> String? {
        let r = (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let i = (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let c = (container ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty || !i.isEmpty || !c.isEmpty else { return nil }
        return [r, i, c].joined(separator: separator)
    }

    /// Canonical "role: title" container string — the single shared shape so a
    /// recorder-captured container (MacContextKit) and a replay-read one (ComputerUseKit)
    /// compare equal after normalization. `nil` when both parts are empty.
    public static func container(role: String, title: String) -> String? {
        let r = role.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty || !t.isEmpty else { return nil }
        return "\(r): \(String(t.prefix(60)))"
    }

    /// Unpacks an encoded descriptor; tolerant of `nil`/legacy unseparated/2-field strings.
    public static func decode(_ encoded: String?) -> (role: String?, identifier: String?, container: String?) {
        if let descriptor = AXTargetDescriptorV2.decodeJSON(encoded) {
            return (descriptor.role, descriptor.identifier, descriptor.container ?? descriptor.ancestorPath.last)
        }
        guard let encoded, encoded.contains(separator) else { return (nil, nil, nil) }
        let parts = encoded.components(separatedBy: separator)
        func field(_ i: Int) -> String? {
            guard parts.indices.contains(i) else { return nil }
            let v = parts[i]
            return v.isEmpty ? nil : v
        }
        return (field(0), field(1), field(2))
    }
}

/// JSON locator for recorded AX targets. V2 keeps the legacy role/identifier/container
/// signals, then adds structural and semantic features used by the replay resolver's
/// candidate ranking. It is stored in the existing string column and decodes legacy
/// `AXTargetDescriptor` separator payloads so old recipes continue to replay.
public struct AXTargetDescriptorV2: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let label: String
    public let role: String?
    public let identifier: String?
    public let container: String?
    public let ancestorPath: [String]
    public let siblingIndex: Int?
    public let neighborLabels: [String]
    public let frameBucket: String?
    public let frame: String?
    public let valueHash: String?
    public let enabled: Bool?
    public let selected: Bool?
    public let focused: Bool?
    public let pathHash: String?
    public let subtree: String?
    public let subtreeHash: String?
    public let semanticHash: String?

    public init(
        schemaVersion: Int = 2,
        label: String,
        role: String? = nil,
        identifier: String? = nil,
        container: String? = nil,
        ancestorPath: [String] = [],
        siblingIndex: Int? = nil,
        neighborLabels: [String] = [],
        frameBucket: String? = nil,
        frame: String? = nil,
        valueHash: String? = nil,
        enabled: Bool? = nil,
        selected: Bool? = nil,
        focused: Bool? = nil,
        pathHash: String? = nil,
        subtree: String? = nil,
        subtreeHash: String? = nil,
        semanticHash: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = Self.cleaned(role)
        self.identifier = Self.cleaned(identifier)
        self.container = Self.cleaned(container)
        self.ancestorPath = ancestorPath.compactMap(Self.cleaned)
        self.siblingIndex = siblingIndex
        self.neighborLabels = neighborLabels.compactMap(Self.cleaned)
        self.frameBucket = Self.cleaned(frameBucket)
        self.frame = Self.cleaned(frame)
        self.valueHash = Self.cleaned(valueHash)
        self.enabled = enabled
        self.selected = selected
        self.focused = focused
        self.pathHash = Self.cleaned(pathHash)
        self.subtree = Self.cleaned(subtree)
        self.subtreeHash = Self.cleaned(subtreeHash)
        self.semanticHash = Self.cleaned(semanticHash)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case label
        case role
        case identifier
        case container
        case ancestorPath
        case siblingIndex
        case neighborLabels
        case frameBucket
        case frame
        case valueHash
        case enabled
        case selected
        case focused
        case pathHash
        case subtree
        case subtreeHash
        case semanticHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2,
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            role: try container.decodeIfPresent(String.self, forKey: .role),
            identifier: try container.decodeIfPresent(String.self, forKey: .identifier),
            container: try container.decodeIfPresent(String.self, forKey: .container),
            ancestorPath: try container.decodeIfPresent([String].self, forKey: .ancestorPath) ?? [],
            siblingIndex: try container.decodeIfPresent(Int.self, forKey: .siblingIndex),
            neighborLabels: try container.decodeIfPresent([String].self, forKey: .neighborLabels) ?? [],
            frameBucket: try container.decodeIfPresent(String.self, forKey: .frameBucket),
            frame: try container.decodeIfPresent(String.self, forKey: .frame),
            valueHash: try container.decodeIfPresent(String.self, forKey: .valueHash),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled),
            selected: try container.decodeIfPresent(Bool.self, forKey: .selected),
            focused: try container.decodeIfPresent(Bool.self, forKey: .focused),
            pathHash: try container.decodeIfPresent(String.self, forKey: .pathHash),
            subtree: try container.decodeIfPresent(String.self, forKey: .subtree),
            subtreeHash: try container.decodeIfPresent(String.self, forKey: .subtreeHash),
            semanticHash: try container.decodeIfPresent(String.self, forKey: .semanticHash)
        )
    }

    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func encode(
        label: String,
        role: String? = nil,
        identifier: String? = nil,
        container: String? = nil,
        ancestorPath: [String] = [],
        siblingIndex: Int? = nil,
        neighborLabels: [String] = [],
        frameBucket: String? = nil,
        frame: String? = nil,
        valueHash: String? = nil,
        enabled: Bool? = nil,
        selected: Bool? = nil,
        focused: Bool? = nil,
        pathHash: String? = nil,
        subtree: String? = nil,
        subtreeHash: String? = nil,
        semanticHash: String? = nil
    ) -> String? {
        let descriptor = AXTargetDescriptorV2(
            label: label,
            role: role,
            identifier: identifier,
            container: container,
            ancestorPath: ancestorPath,
            siblingIndex: siblingIndex,
            neighborLabels: neighborLabels,
            frameBucket: frameBucket,
            frame: frame,
            valueHash: valueHash,
            enabled: enabled,
            selected: selected,
            focused: focused,
            pathHash: pathHash,
            subtree: subtree,
            subtreeHash: subtreeHash,
            semanticHash: semanticHash
        )
        guard descriptor.hasSignal else { return nil }
        return descriptor.encodedJSON()
    }

    public static func decode(_ encoded: String?, fallbackLabel: String = "") -> AXTargetDescriptorV2? {
        if let descriptor = decodeJSON(encoded) {
            if descriptor.label.isEmpty, !fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AXTargetDescriptorV2(
                    schemaVersion: descriptor.schemaVersion,
                    label: fallbackLabel,
                    role: descriptor.role,
                    identifier: descriptor.identifier,
                    container: descriptor.container,
                    ancestorPath: descriptor.ancestorPath,
                    siblingIndex: descriptor.siblingIndex,
                    neighborLabels: descriptor.neighborLabels,
                    frameBucket: descriptor.frameBucket,
                    frame: descriptor.frame,
                    valueHash: descriptor.valueHash,
                    enabled: descriptor.enabled,
                    selected: descriptor.selected,
                    focused: descriptor.focused,
                    pathHash: descriptor.pathHash,
                    subtree: descriptor.subtree,
                    subtreeHash: descriptor.subtreeHash,
                    semanticHash: descriptor.semanticHash
                )
            }
            return descriptor
        }
        guard let encoded, encoded.contains(AXTargetDescriptor.separator) else { return nil }
        let parts = encoded.components(separatedBy: AXTargetDescriptor.separator)
        func field(_ index: Int) -> String? {
            guard parts.indices.contains(index) else { return nil }
            return cleaned(parts[index])
        }
        let role = field(0)
        let identifier = field(1)
        let container = field(2)
        guard role != nil || identifier != nil || container != nil else { return nil }
        return AXTargetDescriptorV2(
            label: fallbackLabel,
            role: role,
            identifier: identifier,
            container: container,
            ancestorPath: container.map { [$0] } ?? []
        )
    }

    static func decodeJSON(_ encoded: String?) -> AXTargetDescriptorV2? {
        guard let encoded,
              encoded.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let data = encoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AXTargetDescriptorV2.self, from: data)
    }

    public var hasSignal: Bool {
        !label.isEmpty
            || role != nil
            || identifier != nil
            || container != nil
            || !ancestorPath.isEmpty
            || siblingIndex != nil
            || !neighborLabels.isEmpty
            || frameBucket != nil
            || frame != nil
            || valueHash != nil
            || enabled != nil
            || selected != nil
            || focused != nil
            || pathHash != nil
            || subtree != nil
            || subtreeHash != nil
            || semanticHash != nil
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Agents (a Cascade built from a recorded, repeated workflow)

public enum RecipeStepKind: String, Codable, Sendable {
    case activateApp
    case click
    case doubleClick
    case rightClick
    case type
    case key
    case scroll
}

public enum RecipeParameterKind: String, Codable, Sendable {
    case date
    case currency
    case number
    case email
    case url
    case filePath
    case personName
    case freeText
}

/// One step of an agent recipe, derived from the user's recorded actions. The
/// `ocrAnchor` is text seen near a click so the deploy loop can re-locate the
/// target instead of trusting a stale coordinate.
public struct RecipeStep: Codable, Equatable, Sendable {
    public let order: Int
    public let kind: RecipeStepKind
    public let x: Double?
    public let y: Double?
    public let text: String?
    public let key: String?
    public let modifiers: [String]
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitleHint: String?
    public let ocrAnchor: String?
    /// Stable AX locator of a click target (encoded `role`+`identifier` via
    /// `AXTargetDescriptor`), carried from the recorded `InputEvent`. The replay
    /// cascade ranks live candidates on this before falling back to the `ocrAnchor`
    /// label and finally the recorded pixel. Optional — old recipes decode without it.
    public let targetDescriptor: String?
    /// A `.type` step whose recorded value VARIED across the workflow's occurrences —
    /// i.e. a parameter (the order number that changes each run), not fixed content
    /// (AWM-style placeholder abstraction). The deployed agent must supply the
    /// CURRENT value, never blindly retype the recorded one; the curator goal is
    /// written parameter-aware so it does. `false` for fixed steps and old recipes.
    public let isParameter: Bool
    /// Stable field key for a parameterized step, e.g. `invoice_number`.
    /// Additive and optional so old recipes decode without migration.
    public let parameterKey: String?
    public let parameterKind: RecipeParameterKind?
    /// Privacy-safe value shapes/examples, never raw typed values.
    public let valueExamples: [String]
    /// Short stable hashes of raw values for equivalence without disclosure.
    public let valueHashes: [String]
    /// Recipe step orders that supplied or selected this value before it was typed.
    public let sourceStepIDs: [Int]
    /// Simple data transform evidence when known, e.g. `trim`.
    public let transform: String?

    private enum CodingKeys: String, CodingKey {
        case order, kind, x, y, text, key, modifiers, appName, bundleIdentifier
        case windowTitleHint, ocrAnchor, targetDescriptor, isParameter
        case parameterKey, parameterKind, valueExamples, valueHashes, sourceStepIDs, transform
    }

    public init(
        order: Int,
        kind: RecipeStepKind,
        x: Double? = nil,
        y: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String] = [],
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitleHint: String? = nil,
        ocrAnchor: String? = nil,
        targetDescriptor: String? = nil,
        isParameter: Bool = false,
        parameterKey: String? = nil,
        parameterKind: RecipeParameterKind? = nil,
        valueExamples: [String] = [],
        valueHashes: [String] = [],
        sourceStepIDs: [Int] = [],
        transform: String? = nil
    ) {
        self.order = order
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitleHint = windowTitleHint
        self.ocrAnchor = ocrAnchor
        self.targetDescriptor = targetDescriptor
        self.isParameter = isParameter
        self.parameterKey = parameterKey
        self.parameterKind = parameterKind
        self.valueExamples = valueExamples
        self.valueHashes = valueHashes
        self.sourceStepIDs = sourceStepIDs
        self.transform = transform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.order = try container.decode(Int.self, forKey: .order)
        self.kind = try container.decode(RecipeStepKind.self, forKey: .kind)
        self.x = try container.decodeIfPresent(Double.self, forKey: .x)
        self.y = try container.decodeIfPresent(Double.self, forKey: .y)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        self.modifiers = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        self.appName = try container.decode(String.self, forKey: .appName)
        self.bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        self.windowTitleHint = try container.decodeIfPresent(String.self, forKey: .windowTitleHint)
        self.ocrAnchor = try container.decodeIfPresent(String.self, forKey: .ocrAnchor)
        self.targetDescriptor = try container.decodeIfPresent(String.self, forKey: .targetDescriptor)
        self.isParameter = try container.decodeIfPresent(Bool.self, forKey: .isParameter) ?? false
        self.parameterKey = try container.decodeIfPresent(String.self, forKey: .parameterKey)
        self.parameterKind = try container.decodeIfPresent(RecipeParameterKind.self, forKey: .parameterKind)
        self.valueExamples = try container.decodeIfPresent([String].self, forKey: .valueExamples) ?? []
        self.valueHashes = try container.decodeIfPresent([String].self, forKey: .valueHashes) ?? []
        self.sourceStepIDs = try container.decodeIfPresent([Int].self, forKey: .sourceStepIDs) ?? []
        self.transform = try container.decodeIfPresent(String.self, forKey: .transform)
    }
}

public extension RecipeStep {
    /// The step as a person would say it — "click “Send Message”", "⌘C",
    /// "switch to Numbers" — built from the recorded AX anchor and shortcut.
    /// Typed content is summarized, never quoted (cards promise step *shape*,
    /// not keystrokes).
    var humanLabel: String {
        switch kind {
        case .activateApp:
            return "switch to \(appName)"
        case .click:
            return anchored("click")
        case .doubleClick:
            return anchored("double-click")
        case .rightClick:
            return anchored("right-click")
        case .type:
            return "type"
        case .key:
            let symbols = modifiers.map(Self.symbol).joined()
            let keyName = (key ?? "").count == 1 ? (key ?? "").uppercased() : (key ?? "").capitalized
            return symbols.isEmpty ? keyName : symbols + keyName
        case .scroll:
            return "scroll"
        }
    }

    var idempotentActionKey: String {
        RecipeActionIdentity.key(for: self)
    }

    var idempotentActionKeyHash: String {
        RecipeActionIdentity.hash(idempotentActionKey)
    }

    private func anchored(_ verb: String) -> String {
        guard let anchor = ocrAnchor?.trimmingCharacters(in: .whitespacesAndNewlines), !anchor.isEmpty else {
            return verb
        }
        return "\(verb) “\(String(anchor.prefix(28)))”"
    }

    private static func symbol(_ modifier: String) -> String {
        switch modifier.lowercased() {
        case "command", "cmd": "⌘"
        case "shift": "⇧"
        case "option", "alt": "⌥"
        case "control", "ctrl": "⌃"
        case "fn", "function": "fn"
        default: modifier
        }
    }
}

public struct AgentRecipe: Codable, Equatable, Sendable {
    public var steps: [RecipeStep]
    public init(steps: [RecipeStep]) { self.steps = steps }

    /// Ordered human-readable step labels — what will actually happen on deploy.
    public var humanSteps: [String] {
        steps.sorted { $0.order < $1.order }.map(\.humanLabel)
    }
}

public enum AgentSource: String, Codable, Sendable {
    /// Every agent now originates from a detected, manager-approved workflow —
    /// the one creation path. (Decoding tolerates legacy rows via the `.detected`
    /// fallback at the read site.)
    case detected
}

public struct AgentDemoSketch: Codable, Equatable, Sendable {
    public let id: String
    public let appName: String
    public let windowTitle: String?
    public let normalizedGoalTokens: [String]
    public let promptText: String
    public let actionCount: Int
    public let anchorCount: Int
    public let checkCount: Int

    public init(
        id: String,
        appName: String,
        windowTitle: String? = nil,
        normalizedGoalTokens: [String],
        promptText: String,
        actionCount: Int,
        anchorCount: Int,
        checkCount: Int
    ) {
        self.id = id
        self.appName = appName
        self.windowTitle = windowTitle
        self.normalizedGoalTokens = normalizedGoalTokens
        self.promptText = String(promptText.prefix(1_200))
        self.actionCount = actionCount
        self.anchorCount = anchorCount
        self.checkCount = checkCount
    }

    public func relevanceScore(appName queryAppName: String?, goalTokens queryTokens: Set<String>) -> Double {
        var score = 0.0
        let queryApp = queryAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let queryApp, !queryApp.isEmpty {
            let sketchApp = appName.lowercased()
            if sketchApp == queryApp {
                score += 2.0
            } else if sketchApp.contains(queryApp) || queryApp.contains(sketchApp) {
                score += 1.0
            }
        }

        let sketchTokens = Set(normalizedGoalTokens)
        let overlap = sketchTokens.intersection(queryTokens).count
        let union = sketchTokens.union(queryTokens).count
        if union > 0 {
            score += Double(overlap) / Double(union)
        }
        score += Double(overlap) * 0.05
        return score
    }
}

/// A saved Cascade: a named, re-runnable agent built from a recorded workflow.
public struct CascadeAgent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let source: AgentSource
    /// Stable key (e.g. the app sequence) used to dedupe re-detected workflows.
    public let signature: String
    public let recipe: AgentRecipe
    public let apps: [String]
    public let estimatedSeconds: Int
    /// Seconds ONE deploy gives back (from the detection math) — multiplied by
    /// `runCount` this is the honest "time actually reclaimed", as opposed to
    /// `estimatedSeconds`, which is the potential observed at detection time.
    public let estimatedSecondsPerRun: Int
    public let evidenceCount: Int
    /// Raw recorded-context IDs that supported the manager-approved workflow.
    /// These stay attached to the saved agent so later learning can cite source
    /// cases instead of inventing skill evidence from memory.
    public let evidenceIDs: [Int64]
    /// How many times this agent has actually been deployed to completion.
    public let runCount: Int
    public let createdAt: Date
    public let lastRunAt: Date?
    public let enabled: Bool
    /// "daily@HH:mm" for a scheduled agent, nil for manual-only.
    public let schedule: String?
    /// The curator's intent instruction — what a deployed agent should accomplish,
    /// in plain language ("Copy the latest invoice totals into the Numbers tracker").
    /// Drives background-sandbox deploys (intent, not recorded pixels); nil for
    /// agents created before curation or without a goal.
    public let goal: String?
    /// Prompt-safe teach-once demo sketches available before the agent has any
    /// successful deployment experience rows. Stored as CascadeMemory DTOs to avoid a
    /// CascadeMemory -> AgentOrchestrator dependency.
    public let demoSketches: [AgentDemoSketch]

    private enum CodingKeys: String, CodingKey {
        case id, name, source, signature, recipe, apps, estimatedSeconds
        case estimatedSecondsPerRun, evidenceCount, evidenceIDs, runCount
        case createdAt, lastRunAt, enabled, schedule, goal, demoSketches
    }

    public init(
        id: Int64 = 0,
        name: String,
        source: AgentSource,
        signature: String,
        recipe: AgentRecipe,
        apps: [String] = [],
        estimatedSeconds: Int = 0,
        estimatedSecondsPerRun: Int = 0,
        evidenceCount: Int = 0,
        evidenceIDs: [Int64] = [],
        runCount: Int = 0,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        enabled: Bool = true,
        schedule: String? = nil,
        goal: String? = nil,
        demoSketches: [AgentDemoSketch] = []
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.signature = signature
        self.recipe = recipe
        self.apps = apps
        self.estimatedSeconds = estimatedSeconds
        self.estimatedSecondsPerRun = estimatedSecondsPerRun
        self.evidenceCount = evidenceCount
        self.evidenceIDs = evidenceIDs
        self.runCount = runCount
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.enabled = enabled
        self.schedule = schedule
        self.goal = goal
        self.demoSketches = demoSketches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        self.name = try container.decode(String.self, forKey: .name)
        self.source = try container.decode(AgentSource.self, forKey: .source)
        self.signature = try container.decode(String.self, forKey: .signature)
        self.recipe = try container.decode(AgentRecipe.self, forKey: .recipe)
        self.apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
        self.estimatedSeconds = try container.decodeIfPresent(Int.self, forKey: .estimatedSeconds) ?? 0
        self.estimatedSecondsPerRun = try container.decodeIfPresent(Int.self, forKey: .estimatedSecondsPerRun) ?? 0
        self.evidenceCount = try container.decodeIfPresent(Int.self, forKey: .evidenceCount) ?? 0
        self.evidenceIDs = try container.decodeIfPresent([Int64].self, forKey: .evidenceIDs) ?? []
        self.runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        self.goal = try container.decodeIfPresent(String.self, forKey: .goal)
        self.demoSketches = try container.decodeIfPresent([AgentDemoSketch].self, forKey: .demoSketches) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
        try container.encode(signature, forKey: .signature)
        try container.encode(recipe, forKey: .recipe)
        try container.encode(apps, forKey: .apps)
        try container.encode(estimatedSeconds, forKey: .estimatedSeconds)
        try container.encode(estimatedSecondsPerRun, forKey: .estimatedSecondsPerRun)
        try container.encode(evidenceCount, forKey: .evidenceCount)
        try container.encode(evidenceIDs, forKey: .evidenceIDs)
        try container.encode(runCount, forKey: .runCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(goal, forKey: .goal)
        try container.encode(demoSketches, forKey: .demoSketches)
    }
}

public enum CascadeStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Open database: \(message)"
        case .sqlite(let message): "SQLite error: \(message)"
        case .prepareFailed(let message): "Prepare statement: \(message)"
        }
    }
}

public enum CascadeStoreMaintenanceReason: String, Sendable, Equatable {
    case idle
    case quit
    case admin
}

internal enum CascadeBatchInsertTable: Sendable {
    case recordedContext
    case inputEvent
}

internal typealias CascadeBatchBindFailureInjector = @Sendable (CascadeBatchInsertTable, Int) throws -> Void

public actor CascadeStore {
    private let connection: SQLiteConnection
    private let path: String
    private let auditAnchor: AuditAnchorStore
    private let auditSigner: AuditSigner
    private var batchBindFailureInjector: CascadeBatchBindFailureInjector?

    public init(
        path: String? = nil,
        auditAnchor: AuditAnchorStore = NullAuditAnchor(),
        auditSigner: AuditSigner = NullAuditSigner()
    ) throws {
        self.path = path ?? Self.defaultDatabasePath()
        self.auditAnchor = auditAnchor
        self.auditSigner = auditSigner
        try Self.ensureParentDirectory(for: self.path)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(self.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let handle {
                sqlite3_close(handle)
            }
            throw CascadeStoreError.openFailed(message)
        }

        connection = SQLiteConnection(handle)
        try Self.migrate(handle)
        try Self.configureConnection(handle)
    }

    public static func defaultDatabasePath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Cascade", isDirectory: true)
            .appendingPathComponent("Cascade.sqlite", isDirectory: false)
            .path
    }

    internal func setBatchBindFailureInjector(_ injector: CascadeBatchBindFailureInjector?) {
        batchBindFailureInjector = injector
    }

    public func insert(_ context: RecordedContext, indexWorkGraph: Bool = false) throws -> RecordedContext {
        try insertContexts([context], indexWorkGraph: indexWorkGraph)[0]
    }

    /// Batch-inserts recorded moments in one transaction, reusing the prepared INSERT
    /// statement across rows so recorder flushes don't pay prepare/finalize per frame.
    public func insertContexts(_ contexts: [RecordedContext], indexWorkGraph: Bool = false) throws -> [RecordedContext] {
        guard !contexts.isEmpty else { return [] }
        let sql = """
        INSERT INTO recorded_context
            (captured_at, captured_ms, source, app_name, bundle_identifier, window_title, ocr_text, image_path, metadata_json, frame_hash,
             source_trust, raw_trust_label, injection_score, injection_reasons, user_confirmed, safe_to_show, safe_to_summarize, safe_for_control)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        return try withTransaction {
            try withStatement(sql) { statement in
                var rows: [RecordedContext] = []
                rows.reserveCapacity(contexts.count)
                for (index, context) in contexts.enumerated() {
                    let sanitized = Self.sanitizedContext(context)
                    try bindContext(sanitized, at: index, in: statement)
                    try stepDone(statement)
                    rows.append(RecordedContext(
                        id: sqlite3_last_insert_rowid(connection.db),
                        capturedAt: sanitized.capturedAt,
                        source: sanitized.source,
                        appName: sanitized.appName,
                        bundleIdentifier: sanitized.bundleIdentifier,
                        windowTitle: sanitized.windowTitle,
                        ocrText: sanitized.ocrText,
                        imagePath: sanitized.imagePath,
                        metadataJSON: sanitized.metadataJSON,
                        frameHash: sanitized.frameHash,
                        sourceTrust: sanitized.sourceTrust,
                        rawTrustLabel: sanitized.rawTrustLabel,
                        injectionScore: sanitized.injectionScore,
                        injectionReasonsJSON: sanitized.injectionReasonsJSON,
                        userConfirmed: sanitized.userConfirmed,
                        safeToShow: sanitized.safeToShow,
                        safeToSummarize: sanitized.safeToSummarize,
                        safeForControl: sanitized.safeForControl
                    ))
                    if indexWorkGraph, let row = rows.last {
                        try linkWorkGraphEntities(for: row)
                    }
                    if let row = rows.last {
                        try upsertMemoryEvent(for: row)
                    }
                    try resetStatement(statement)
                    try clearBindings(statement)
                }
                return rows
            }
        }
    }

    /// Column list shared by `recentContexts` / `searchContexts`, in the order
    /// `decodeContext(_:)` expects. `prefix` qualifies each column with a table
    /// alias so the FTS join (where `ocr_text`/`window_title`/`app_name` exist in
    /// both tables) is unambiguous.
    private static func contextColumns(prefix: String = "") -> String {
        let p = prefix.isEmpty ? "" : "\(prefix)."
        return "\(p)id, \(p)captured_at, \(p)source, \(p)app_name, \(p)bundle_identifier, \(p)window_title, \(p)ocr_text, \(p)image_path, \(p)metadata_json, \(p)frame_hash, \(p)source_trust, \(p)raw_trust_label, \(p)injection_score, \(p)injection_reasons, \(p)user_confirmed, \(p)safe_to_show, \(p)safe_to_summarize, \(p)safe_for_control"
    }

    public func recentContexts(limit: Int = 40) throws -> [RecordedContext] {
        let sql = """
        SELECT \(Self.contextColumns())
        FROM recorded_context
        ORDER BY captured_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// Moments captured at or after `since`, newest-first, decoded WITHOUT the
    /// heavy OCR/metadata payloads so a whole day's worth stays cheap to load.
    /// Grounds day-scale chat questions; use `recentContexts` when OCR is needed.
    public func contextTimeline(since: Date, limit: Int = 8000) throws -> [RecordedContext] {
        let sql = """
        SELECT id, captured_at, source, app_name, bundle_identifier, window_title,
               NULL, image_path, NULL, frame_hash,
               source_trust, raw_trust_label, injection_score, injection_reasons,
               user_confirmed, safe_to_show, safe_to_summarize, safe_for_control
        FROM recorded_context
        WHERE captured_at >= ?
        ORDER BY captured_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(DateCodec.string(from: since), at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// One representative moment per app per clock hour — the one with the most
    /// on-screen text — with the OCR trimmed to `excerptLength`. Spreads content
    /// coverage across the whole window so the chat can answer about things seen
    /// at any point in the day, not just recently. Newest-first.
    public func contentSamples(since: Date, limit: Int = 48, excerptLength: Int = 400) throws -> [RecordedContext] {
        let sql = """
        SELECT id, captured_at, source, app_name, bundle_identifier, window_title,
               substr(ocr_text, 1, ?), image_path, NULL, frame_hash,
               source_trust, raw_trust_label, injection_score, injection_reasons,
               user_confirmed, safe_to_show, safe_to_summarize, safe_for_control,
               MAX(length(ocr_text))
        FROM recorded_context
        WHERE captured_at >= ? AND ocr_text IS NOT NULL AND length(ocr_text) > 0
        GROUP BY substr(captured_at, 1, 13), app_name
        ORDER BY captured_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(excerptLength))
            bind(DateCodec.string(from: since), at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// One moment by id — the agentic answerer's `inspect_moment` tool.
    public func context(id: Int64) throws -> RecordedContext? {
        let sql = "SELECT \(Self.contextColumns()) FROM recorded_context WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, id)
            return sqlite3_step(statement) == SQLITE_ROW ? decodeContext(statement) : nil
        }
    }

    /// Moments inside a time window, oldest-first — the agentic answerer's
    /// `get_timeframe` tool ("what was I doing between 2 and 3pm").
    public func contexts(between start: Date, and end: Date, limit: Int = 60) throws -> [RecordedContext] {
        let sql = """
        SELECT \(Self.contextColumns())
        FROM recorded_context
        WHERE captured_at >= ? AND captured_at <= ?
        ORDER BY captured_at ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(DateCodec.string(from: start), at: 1, in: statement)
            bind(DateCodec.string(from: end), at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// Opt-in integer time-key mirror of `contexts(between:and:limit:)`.
    public func contexts(capturedMilliseconds range: ClosedRange<Int64>, limit: Int = 60) throws -> [RecordedContext] {
        let sql = """
        SELECT \(Self.contextColumns())
        FROM recorded_context
        WHERE captured_ms >= ? AND captured_ms <= ?
        ORDER BY captured_ms ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(range.lowerBound, at: 1, in: statement)
            bind(range.upperBound, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// Moments whose recorded text matches ANY meaningful token of a natural-
    /// language question, best match first (FTS5 bm25). Unlike `searchContexts`
    /// — which ANDs every token, so a stopword-heavy question matches nothing —
    /// this is the recall path for chat questions like "when was the assignment
    /// due?". OCR is trimmed to `excerptLength`.
    public func relevantContexts(to question: String, limit: Int = 12, excerptLength: Int = 400) throws -> [RecordedContext] {
        let match = Self.ftsAnyQuery(from: question)
        guard !match.isEmpty else { return [] }
        let sql = """
        SELECT c.id, c.captured_at, c.source, c.app_name, c.bundle_identifier, c.window_title,
               substr(c.ocr_text, 1, ?), c.image_path, NULL, c.frame_hash
        FROM rewind_fts
        JOIN recorded_context c ON c.id = rewind_fts.rowid
        WHERE rewind_fts MATCH ?
        ORDER BY bm25(rewind_fts), c.captured_at DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(excerptLength))
            bind(match, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    public func unindexedRecentContexts(limit: Int = 24) throws -> [RecordedContext] {
        let sql = """
        SELECT \(Self.contextColumns(prefix: "c"))
        FROM recorded_context c
        WHERE c.ocr_text IS NOT NULL
          AND length(c.ocr_text) > 0
          AND NOT EXISTS (SELECT 1 FROM context_embedding e WHERE e.context_id = c.id)
          AND NOT EXISTS (SELECT 1 FROM context_chunk_embedding ce WHERE ce.context_id = c.id)
        ORDER BY c.captured_at DESC, c.id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(max(0, min(limit, Int(Int32.max)))))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// Full-text search over the OCR text, window title, and app name of stored
    /// moments via the `rewind_fts` FTS5 index. Returns matches newest-first.
    public func searchContexts(query: String, limit: Int = 80) throws -> [RecordedContext] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty else { return [] }
        // MATCH must name the FTS table itself (an alias is read as a column), so
        // `rewind_fts` is left unaliased; `recorded_context` is aliased `c` to
        // disambiguate the text columns it shares with the index.
        let sql = """
        SELECT \(Self.contextColumns(prefix: "c"))
        FROM rewind_fts
        JOIN recorded_context c ON c.id = rewind_fts.rowid
        WHERE rewind_fts MATCH ?
        ORDER BY c.captured_at DESC, c.id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(match, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    /// Hybrid recall — the recommended search entry point. Runs the keyword lane
    /// (FTS5/BM25) and the semantic lane (cosine over embeddings) in PARALLEL and
    /// fuses their rankings with Reciprocal Rank Fusion, rather than falling back
    /// one lane to the next. A moment the keyword lane missed but meaning ranked
    /// highly now surfaces even when keyword search also returned hits — the lanes
    /// cover each other's blind spots instead of one pre-empting the other.
    ///
    /// `candidatePool` is how deep each lane is read before fusing (wider than
    /// `limit` so a moment ranked, say, #20 in keyword but #2 in meaning can still
    /// win the fused top-N). Only the fused top-`limit` is hydrated to rows.
    public func hybridRankedCandidates(
        matching query: String,
        limit: Int = 12,
        candidatePool: Int = 40,
        now: Date = Date()
    ) throws -> [RankFusion.FusedCandidate] {
        let keyword = try lexicalRankedIDs(matching: query, limit: candidatePool)
        let semantic = try semanticRankedIDs(matching: query, limit: candidatePool)
        let memory = try memoryRankedIDs(matching: query, limit: candidatePool, now: now)
        let structured = try structuredRankedIDs(matching: query, limit: candidatePool)
        // Both empty → no match; one empty → RRF degenerates to the other lane's
        // order (still correct, no special-casing). Fuse and hydrate the winners.
        return RankFusion.reciprocalRankFusion([
            .init(.lexical, ids: keyword),
            .init(.vector, ids: semantic),
            .init(.memory, ids: memory),
            .init(.structured, ids: structured),
        ], limit: limit)
    }

    public func hybridContextCandidates(
        matching query: String,
        limit: Int = 12,
        candidatePool: Int = 40,
        now: Date = Date()
    ) throws -> [HybridContextCandidate] {
        try hybridRankedCandidates(matching: query, limit: limit, candidatePool: candidatePool, now: now)
            .compactMap { candidate in
                try context(id: candidate.id).map { HybridContextCandidate(candidate: candidate, context: $0) }
            }
    }

    public func hybridContexts(matching query: String, limit: Int = 12, candidatePool: Int = 40) throws -> [RecordedContext] {
        try hybridContextCandidates(matching: query, limit: limit, candidatePool: candidatePool).map(\.context)
    }

    /// The keyword lane's ranking as bare moment ids, best BM25 match first, for
    /// `hybridContexts` to fuse. Uses the any-token (OR) match for recall — BM25
    /// still floats moments matching more query terms to the top, so precision
    /// survives the fusion without a separate AND lane.
    private func lexicalRankedIDs(matching query: String, limit: Int) throws -> [Int64] {
        let match = Self.ftsAnyQuery(from: query)
        guard !match.isEmpty else { return [] }
        let sql = """
        SELECT rewind_fts.rowid
        FROM rewind_fts
        WHERE rewind_fts MATCH ?
        ORDER BY bm25(rewind_fts)
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(match, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var ids: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return ids
        }
    }

    private func structuredRankedIDs(matching query: String, limit: Int) throws -> [Int64] {
        let match = Self.ftsAnyQuery(from: query)
        guard !match.isEmpty else { return [] }
        let sql = """
        SELECT ocr_structure_fts.rowid
        FROM ocr_structure_fts
        JOIN recorded_context c ON c.id = ocr_structure_fts.rowid
        WHERE ocr_structure_fts MATCH ?
        ORDER BY bm25(ocr_structure_fts), c.captured_at DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(match, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var ids: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return ids
        }
    }

    /// Enforces local retention: drops moments older than `maxAge`, then trims the
    /// oldest remaining moments whose frames push total frame-file size over
    /// `maxTotalBytes`. Deleting the rows fires the FTS `_ad` trigger so the search
    /// index stays in sync; returns the `image_path`s of pruned moments so the
    /// caller can delete the backing JPEG files.
    @discardableResult
    public func prune(
        maxAge: TimeInterval = 7 * 24 * 60 * 60,
        maxTotalBytes: Int64 = 5 * 1024 * 1024 * 1024
    ) throws -> [String] {
        var removed: [String] = []

        // Age-based prune.
        let cutoff = DateCodec.string(from: Date().addingTimeInterval(-maxAge))
        removed += try withStatement("SELECT image_path FROM recorded_context WHERE captured_at < ?;") { statement in
            bind(cutoff, at: 1, in: statement)
            var paths: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = text(statement, 0) { paths.append(path) }
            }
            return paths
        }
        try withStatement("DELETE FROM recorded_context WHERE captured_at < ?;") { statement in
            bind(cutoff, at: 1, in: statement)
            try stepDone(statement)
        }

        // Size-based prune: keep newest moments until the frame-file budget is hit,
        // delete the older overflow.
        let survivors = try withStatement("SELECT id, image_path FROM recorded_context ORDER BY captured_at DESC, id DESC;") { statement in
            var rows: [(id: Int64, path: String?)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(statement, 0), text(statement, 1)))
            }
            return rows
        }
        var running: Int64 = 0
        var overflow: [(id: Int64, path: String?)] = []
        for row in survivors {
            running += row.path.flatMap { Self.fileSize(at: $0) } ?? 0
            if running > maxTotalBytes { overflow.append(row) }
        }
        for row in overflow {
            try withStatement("DELETE FROM recorded_context WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, row.id)
                try stepDone(statement)
            }
            if let path = row.path { removed.append(path) }
        }

        // Recorded input ages out on the same age budget (no backing files).
        try withStatement("DELETE FROM input_event WHERE captured_at < ?;") { statement in
            bind(cutoff, at: 1, in: statement)
            try stepDone(statement)
        }
        // Embeddings follow their moments out.
        try? execute("DELETE FROM context_embedding WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        try? execute("DELETE FROM context_chunk_embedding WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        try? execute("DELETE FROM context_visual_embedding WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        try? execute("DELETE FROM ocr_line WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        try? execute("DELETE FROM ocr_structure WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        try? execute("DELETE FROM frame_signature WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        return removed
    }

    public func performMaintenance(reason: CascadeStoreMaintenanceReason = .idle) throws {
        try execute("PRAGMA wal_checkpoint(PASSIVE);")
        try execute("PRAGMA optimize;")
        if reason == .quit || reason == .admin {
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    internal func pragmaIntValue(_ name: String) throws -> Int64 {
        precondition(name.range(of: #"^[A-Za-z_]+$"#, options: .regularExpression) != nil)
        return try withStatement("PRAGMA \(name);") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
        }
    }

    internal func walFileBytes() -> Int64 {
        Self.fileSize(at: path + "-wal") ?? 0
    }

    public func privacySummary(
        scope: PrivacyDataScope = PrivacyDataScope(),
        policy: CapturePrivacyPolicy = .default
    ) throws -> PrivacySummary {
        let contexts = try privacyContexts(scope: scope, limit: 100_000)
        let frameBytes = contexts.reduce(Int64(0)) { total, context in
            total + (context.imagePath.flatMap { Self.fileSize(at: $0) } ?? 0)
        }
        var grouped: [String: [RecordedContext]] = [:]
        for context in contexts {
            let key = [context.source.rawValue, context.appName, context.bundleIdentifier ?? ""]
                .joined(separator: "\u{1F}")
            grouped[key, default: []].append(context)
        }
        let buckets = grouped.values.compactMap { rows -> PrivacySummaryBucket? in
            guard let firstRow = rows.min(by: { $0.capturedAt < $1.capturedAt }),
                  let lastRow = rows.max(by: { $0.capturedAt < $1.capturedAt }) else { return nil }
            let bytes = rows.reduce(Int64(0)) { total, context in
                total + (context.imagePath.flatMap { Self.fileSize(at: $0) } ?? 0)
            }
            return PrivacySummaryBucket(
                source: firstRow.source,
                appName: firstRow.appName,
                bundleIdentifier: firstRow.bundleIdentifier,
                count: rows.count,
                firstCapturedAt: firstRow.capturedAt,
                lastCapturedAt: lastRow.capturedAt,
                estimatedFrameBytes: bytes
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.appName != $1.appName { return $0.appName < $1.appName }
            return $0.source.rawValue < $1.source.rawValue
        }
        return PrivacySummary(
            scope: scope,
            totalContexts: contexts.count,
            firstCapturedAt: contexts.map(\.capturedAt).min(),
            lastCapturedAt: contexts.map(\.capturedAt).max(),
            estimatedFrameBytes: frameBytes,
            buckets: buckets,
            policyVersion: policy.version,
            retentionByDataClass: policy.retentionByDataClass
        )
    }

    public func privacyExportManifest(
        scope: PrivacyDataScope = PrivacyDataScope(),
        policy: CapturePrivacyPolicy = .default,
        generatedAt: Date = Date()
    ) throws -> PrivacyExportManifest {
        PrivacyExportManifest(
            generatedAt: generatedAt,
            summary: try privacySummary(scope: scope, policy: policy)
        )
    }

    public func deletePrivacyData(scope: PrivacyDataScope) throws -> PrivacyDeletionResult {
        let contexts = try privacyContexts(scope: scope, limit: 100_000)
        let imagePaths = contexts.compactMap(\.imagePath)
        let deletedInputCount = try inputEventCount(scope: scope)
        try withTransaction {
            for context in contexts {
                try withStatement("DELETE FROM recorded_context WHERE id = ?;") { statement in
                    sqlite3_bind_int64(statement, 1, context.id)
                    try stepDone(statement)
                }
            }
            try deleteInputEvents(scope: scope)
        }
        return PrivacyDeletionResult(
            deletedContextCount: contexts.count,
            deletedInputEventCount: deletedInputCount,
            backingImagePaths: imagePaths
        )
    }

    private func privacyContexts(scope: PrivacyDataScope, limit: Int) throws -> [RecordedContext] {
        let sql = """
        SELECT id, captured_at, source, app_name, bundle_identifier, window_title,
               NULL, image_path, NULL, frame_hash,
               source_trust, raw_trust_label, injection_score, injection_reasons,
               user_confirmed, safe_to_show, safe_to_summarize, safe_for_control
        FROM recorded_context
        WHERE (? IS NULL OR source = ?)
          AND (? IS NULL OR app_name = ?)
          AND (? IS NULL OR bundle_identifier = ?)
          AND (? IS NULL OR captured_at >= ?)
          AND (? IS NULL OR captured_at <= ?)
        ORDER BY captured_at ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bindPrivacyScope(scope, in: statement)
            sqlite3_bind_int(statement, 11, Int32(max(0, min(limit, Int(Int32.max)))))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    private func inputEventCount(scope: PrivacyDataScope) throws -> Int {
        let sql = """
        SELECT count(*)
        FROM input_event
        WHERE (? = 1)
          AND (? IS NULL OR app_name = ?)
          AND (? IS NULL OR bundle_identifier = ?)
          AND (? IS NULL OR captured_at >= ?)
          AND (? IS NULL OR captured_at <= ?);
        """
        return try withStatement(sql) { statement in
            bindInputScope(scope, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    private func deleteInputEvents(scope: PrivacyDataScope) throws {
        let sql = """
        DELETE FROM input_event
        WHERE (? = 1)
          AND (? IS NULL OR app_name = ?)
          AND (? IS NULL OR bundle_identifier = ?)
          AND (? IS NULL OR captured_at >= ?)
          AND (? IS NULL OR captured_at <= ?);
        """
        try withStatement(sql) { statement in
            bindInputScope(scope, in: statement)
            try stepDone(statement)
        }
    }

    private func bindPrivacyScope(_ scope: PrivacyDataScope, in statement: OpaquePointer) {
        let source = scope.source?.rawValue
        bind(source, at: 1, in: statement)
        bind(source, at: 2, in: statement)
        bind(scope.appName, at: 3, in: statement)
        bind(scope.appName, at: 4, in: statement)
        bind(scope.bundleIdentifier, at: 5, in: statement)
        bind(scope.bundleIdentifier, at: 6, in: statement)
        let start = scope.start.map(DateCodec.string(from:))
        let end = scope.end.map(DateCodec.string(from:))
        bind(start, at: 7, in: statement)
        bind(start, at: 8, in: statement)
        bind(end, at: 9, in: statement)
        bind(end, at: 10, in: statement)
    }

    private func bindInputScope(_ scope: PrivacyDataScope, in statement: OpaquePointer) {
        let includeInput = scope.source == nil || scope.source == .input
        bind(includeInput ? Int64(1) : Int64(0), at: 1, in: statement)
        bind(scope.appName, at: 2, in: statement)
        bind(scope.appName, at: 3, in: statement)
        bind(scope.bundleIdentifier, at: 4, in: statement)
        bind(scope.bundleIdentifier, at: 5, in: statement)
        let start = scope.start.map(DateCodec.string(from:))
        let end = scope.end.map(DateCodec.string(from:))
        bind(start, at: 6, in: statement)
        bind(start, at: 7, in: statement)
        bind(end, at: 8, in: statement)
        bind(end, at: 9, in: statement)
    }

    // MARK: - Input events

    /// Batch-inserts recorded input events in one transaction.
    public func insertInputEvents(_ events: [InputEvent]) throws {
        guard !events.isEmpty else { return }
        let sql = """
        INSERT INTO input_event
            (captured_at, captured_ms, kind, x, y, text, key, modifiers, app_name, bundle_identifier, window_title, target_descriptor)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withTransaction {
            try withStatement(sql) { statement in
                for (index, event) in events.enumerated() {
                    try bindInputEvent(event, at: index, in: statement)
                    try stepDone(statement)
                    try resetStatement(statement)
                    try clearBindings(statement)
                }
            }
        }
    }

    public func insertInputEvent(_ event: InputEvent) throws {
        try insertInputEvents([event])
    }

    /// Most recent input events (newest first).
    public func recentInputEvents(limit: Int = 1000) throws -> [InputEvent] {
        let sql = """
        SELECT id, captured_at, kind, x, y, text, key, modifiers, app_name, bundle_identifier, window_title, target_descriptor
        FROM input_event
        ORDER BY captured_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [InputEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeInputEvent(statement))
            }
            return rows
        }
    }

    /// Input events inside a time window, oldest-first — the time-range mirror of
    /// `recentInputEvents`. Powers turning an arbitrary recorded range (a Teach-once
    /// demonstration, a Reel selection) into a workflow recipe; oldest-first matches
    /// what `WasteDetector` expects, so the bracketed events feed it directly.
    public func inputEvents(between start: Date, and end: Date, limit: Int = 2000) throws -> [InputEvent] {
        let sql = """
        SELECT id, captured_at, kind, x, y, text, key, modifiers, app_name, bundle_identifier, window_title, target_descriptor
        FROM input_event
        WHERE captured_at >= ? AND captured_at <= ?
        ORDER BY captured_at ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(DateCodec.string(from: start), at: 1, in: statement)
            bind(DateCodec.string(from: end), at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [InputEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeInputEvent(statement))
            }
            return rows
        }
    }

    /// Opt-in integer time-key mirror of `inputEvents(between:and:limit:)`.
    public func inputEvents(capturedMilliseconds range: ClosedRange<Int64>, limit: Int = 2000) throws -> [InputEvent] {
        let sql = """
        SELECT id, captured_at, kind, x, y, text, key, modifiers, app_name, bundle_identifier, window_title, target_descriptor
        FROM input_event
        WHERE captured_ms >= ? AND captured_ms <= ?
        ORDER BY captured_ms ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(range.lowerBound, at: 1, in: statement)
            bind(range.upperBound, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [InputEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeInputEvent(statement))
            }
            return rows
        }
    }

    public func clickInputEvents(near date: Date, window: TimeInterval = 1.0, limit: Int = 20) throws -> [InputEvent] {
        let start = DateCodec.string(from: date.addingTimeInterval(-window))
        let end = DateCodec.string(from: date.addingTimeInterval(window))
        let sql = """
        SELECT id, captured_at, kind, x, y, text, key, modifiers, app_name, bundle_identifier, window_title, target_descriptor
        FROM input_event
        WHERE captured_at >= ? AND captured_at <= ?
          AND kind IN ('click', 'doubleClick', 'rightClick')
        ORDER BY ABS(captured_ms - ?), id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(start, at: 1, in: statement)
            bind(end, at: 2, in: statement)
            bind(EventStoreLayout.capturedMilliseconds(for: date), at: 3, in: statement)
            sqlite3_bind_int(statement, 4, Int32(limit))
            var rows: [InputEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeInputEvent(statement))
            }
            return rows
        }
    }

    // MARK: - OCR lines + frame signatures

    public func insertOCRLines(_ lines: [OCRLine]) throws {
        guard !lines.isEmpty else { return }
        let sql = """
        INSERT OR REPLACE INTO ocr_line
            (context_id, line_index, source, text, x, y, width, height, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withTransaction {
            try withStatement(sql) { statement in
                for line in lines {
                    sqlite3_bind_int64(statement, 1, line.contextID)
                    sqlite3_bind_int(statement, 2, Int32(line.lineIndex))
                    bind(line.source, at: 3, in: statement)
                    bind(line.text, at: 4, in: statement)
                    bind(line.x, at: 5, in: statement)
                    bind(line.y, at: 6, in: statement)
                    bind(line.width, at: 7, in: statement)
                    bind(line.height, at: 8, in: statement)
                    bind(line.confidence, at: 9, in: statement)
                    try stepDone(statement)
                    try resetStatement(statement)
                    try clearBindings(statement)
                }
            }
        }
    }

    public func ocrLines(contextID: Int64) throws -> [OCRLine] {
        let sql = """
        SELECT context_id, line_index, source, text, x, y, width, height, confidence
        FROM ocr_line
        WHERE context_id = ?
        ORDER BY line_index ASC, source ASC;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            var rows: [OCRLine] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(OCRLine(
                    contextID: sqlite3_column_int64(statement, 0),
                    lineIndex: Int(sqlite3_column_int(statement, 1)),
                    source: text(statement, 2) ?? "unknown",
                    text: text(statement, 3) ?? "",
                    x: double(statement, 4),
                    y: double(statement, 5),
                    width: double(statement, 6),
                    height: double(statement, 7),
                    confidence: double(statement, 8)
                ))
            }
            return rows
        }
    }

    public func insertOCRStructure(
        contextID: Int64,
        version: Int,
        json: String,
        searchableText: String
    ) throws {
        let sql = """
        INSERT INTO ocr_structure (context_id, version, json, searchable_text)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(context_id) DO UPDATE SET
            version = excluded.version,
            json = excluded.json,
            searchable_text = excluded.searchable_text;
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            sqlite3_bind_int(statement, 2, Int32(version))
            bind(json, at: 3, in: statement)
            bind(searchableText, at: 4, in: statement)
            try stepDone(statement)
        }
    }

    public func ocrStructure(contextID: Int64) throws -> StoredOCRStructure? {
        let sql = """
        SELECT context_id, version, json, searchable_text
        FROM ocr_structure
        WHERE context_id = ?
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredOCRStructure(
                contextID: sqlite3_column_int64(statement, 0),
                version: Int(sqlite3_column_int(statement, 1)),
                json: text(statement, 2) ?? "{}",
                searchableText: text(statement, 3) ?? ""
            )
        }
    }

    public func insertFrameSignature(_ signature: StoredFrameSignature) throws {
        let sql = """
        INSERT OR REPLACE INTO frame_signature
            (context_id, dhash, combined_grid_hash, grid_hashes, block_hash, changed_cells_mask, text_digest)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, signature.contextID)
            bind(signature.dHash, at: 2, in: statement)
            bind(signature.combinedGridHash, at: 3, in: statement)
            bind(signature.gridHashes.map(String.init).joined(separator: ","), at: 4, in: statement)
            bind(signature.blockHash, at: 5, in: statement)
            sqlite3_bind_int(statement, 6, Int32(signature.changedCellsMask))
            bind(signature.textDigest, at: 7, in: statement)
            try stepDone(statement)
        }
    }

    public func frameSignature(contextID: Int64) throws -> StoredFrameSignature? {
        let sql = """
        SELECT context_id, dhash, combined_grid_hash, grid_hashes, block_hash, changed_cells_mask, text_digest
        FROM frame_signature
        WHERE context_id = ?
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let hashes = (text(statement, 3) ?? "")
                .split(separator: ",")
                .compactMap { Int64($0) }
            return StoredFrameSignature(
                contextID: sqlite3_column_int64(statement, 0),
                dHash: sqlite3_column_int64(statement, 1),
                combinedGridHash: sqlite3_column_int64(statement, 2),
                gridHashes: hashes,
                blockHash: sqlite3_column_int64(statement, 4),
                changedCellsMask: UInt16(sqlite3_column_int(statement, 5)),
                textDigest: int64(statement, 6)
            )
        }
    }

    // MARK: - Timeline episodes

    @discardableResult
    public func refreshTimelineEpisodes(between start: Date, and end: Date, limit: Int = 5_000) throws -> [TimelineEpisode] {
        let moments = try contexts(between: start, and: end, limit: limit)
        let momentsByID = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        let episodes = SessionSegmenter.segment(moments).map { episode in
            let summary = episode.momentIDs
                .compactMap { momentsByID[$0]?.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                .map { String($0.prefix(400)) }
            return TimelineEpisode(
                id: episode.id,
                startAt: episode.startedAt,
                endAt: episode.endedAt,
                bundleIdentifier: episode.bundleIdentifier,
                appName: episode.appName,
                windowTitleHint: episode.title,
                contextCount: episode.momentCount,
                representativeContextID: episode.id,
                summaryText: summary
            )
        }
        try withTransaction {
            try withStatement("DELETE FROM timeline_episode WHERE start_at >= ? AND start_at <= ?;") { statement in
                bind(DateCodec.string(from: start), at: 1, in: statement)
                bind(DateCodec.string(from: end), at: 2, in: statement)
                try stepDone(statement)
            }
            try insertTimelineEpisodes(episodes)
        }
        return episodes
    }

    public func timelineEpisodes(between start: Date, and end: Date, limit: Int = 200) throws -> [TimelineEpisode] {
        let sql = """
        SELECT id, start_at, end_at, bundle_identifier, app_name, window_title_hint, context_count, representative_context_id, summary_text
        FROM timeline_episode
        WHERE start_at >= ? AND start_at <= ?
        ORDER BY start_at ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(DateCodec.string(from: start), at: 1, in: statement)
            bind(DateCodec.string(from: end), at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [TimelineEpisode] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeTimelineEpisode(statement))
            }
            return rows
        }
    }

    private func insertTimelineEpisodes(_ episodes: [TimelineEpisode]) throws {
        guard !episodes.isEmpty else { return }
        let sql = """
        INSERT OR REPLACE INTO timeline_episode
            (id, start_at, end_at, bundle_identifier, app_name, window_title_hint, context_count, representative_context_id, summary_text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            for episode in episodes {
                sqlite3_bind_int64(statement, 1, episode.id)
                bind(DateCodec.string(from: episode.startAt), at: 2, in: statement)
                bind(DateCodec.string(from: episode.endAt), at: 3, in: statement)
                bind(episode.bundleIdentifier, at: 4, in: statement)
                bind(episode.appName, at: 5, in: statement)
                bind(episode.windowTitleHint, at: 6, in: statement)
                sqlite3_bind_int(statement, 7, Int32(episode.contextCount))
                sqlite3_bind_int64(statement, 8, episode.representativeContextID)
                bind(episode.summaryText, at: 9, in: statement)
                try stepDone(statement)
                try resetStatement(statement)
                try clearBindings(statement)
            }
        }
    }

    // MARK: - Agents

    /// Inserts a new agent, or updates the existing one with the same `signature`
    /// (so re-detecting a workflow refreshes it rather than duplicating). Returns
    /// the stored agent with its id.
    @discardableResult
    public func upsertAgent(_ agent: CascadeAgent) throws -> CascadeAgent {
        let recipeJSON = Self.encodeRecipe(agent.recipe)
        let appsCSV = agent.apps.joined(separator: "\u{1F}") // unit separator — app names may contain commas
        let evidenceIDsJSON = Self.encodeAgentEvidenceIDs(agent.evidenceIDs)
        let demoSketchesJSON = Self.encodeAgentDemoSketches(agent.demoSketches)

        let existingID = try withStatement("SELECT id FROM agents WHERE signature = ? LIMIT 1;") { statement in
            bind(agent.signature, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
        }

        if let existingID {
            // run_count, last_run_at, schedule, and goal are never overwritten by a
            // re-detect — the run history, schedule, and curated goal belong to the
            // approved agent, not the detection.
            try withStatement("""
            UPDATE agents SET name = ?, source = ?, recipe_json = ?, apps = ?, estimated_seconds = ?, seconds_per_run = ?, evidence_count = ?, evidence_ids_json = ?, demo_sketches_json = CASE WHEN ? = '[]' THEN demo_sketches_json ELSE ? END
            WHERE id = ?;
            """) { statement in
                bind(agent.name, at: 1, in: statement)
                bind(agent.source.rawValue, at: 2, in: statement)
                bind(recipeJSON, at: 3, in: statement)
                bind(appsCSV, at: 4, in: statement)
                sqlite3_bind_int64(statement, 5, Int64(agent.estimatedSeconds))
                sqlite3_bind_int64(statement, 6, Int64(agent.estimatedSecondsPerRun))
                sqlite3_bind_int64(statement, 7, Int64(agent.evidenceCount))
                bind(evidenceIDsJSON, at: 8, in: statement)
                bind(demoSketchesJSON, at: 9, in: statement)
                bind(demoSketchesJSON, at: 10, in: statement)
                sqlite3_bind_int64(statement, 11, existingID)
                try stepDone(statement)
            }
            return try self.agent(id: existingID) ?? agent
        }

        try withStatement("""
        INSERT INTO agents
            (name, source, signature, recipe_json, apps, estimated_seconds, seconds_per_run, evidence_count, evidence_ids_json, run_count, created_at, last_run_at, enabled, schedule, goal, demo_sketches_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bind(agent.name, at: 1, in: statement)
            bind(agent.source.rawValue, at: 2, in: statement)
            bind(agent.signature, at: 3, in: statement)
            bind(recipeJSON, at: 4, in: statement)
            bind(appsCSV, at: 5, in: statement)
            sqlite3_bind_int64(statement, 6, Int64(agent.estimatedSeconds))
            sqlite3_bind_int64(statement, 7, Int64(agent.estimatedSecondsPerRun))
            sqlite3_bind_int64(statement, 8, Int64(agent.evidenceCount))
            bind(evidenceIDsJSON, at: 9, in: statement)
            sqlite3_bind_int64(statement, 10, Int64(agent.runCount))
            bind(DateCodec.string(from: agent.createdAt), at: 11, in: statement)
            bind(agent.lastRunAt.map(DateCodec.string(from:)), at: 12, in: statement)
            sqlite3_bind_int(statement, 13, agent.enabled ? 1 : 0)
            bind(agent.schedule, at: 14, in: statement)
            bind(agent.goal, at: 15, in: statement)
            bind(demoSketchesJSON, at: 16, in: statement)
            try stepDone(statement)
        }
        let newID = sqlite3_last_insert_rowid(connection.db)
        return try self.agent(id: newID) ?? agent
    }

    public func agents() throws -> [CascadeAgent] {
        try withStatement("\(Self.agentColumns) FROM agents ORDER BY created_at DESC, id DESC;") { statement in
            var rows: [CascadeAgent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeAgent(statement))
            }
            return rows
        }
    }

    public func agent(id: Int64) throws -> CascadeAgent? {
        try withStatement("\(Self.agentColumns) FROM agents WHERE id = ? LIMIT 1;") { statement in
            sqlite3_bind_int64(statement, 1, id)
            return sqlite3_step(statement) == SQLITE_ROW ? decodeAgent(statement) : nil
        }
    }

    /// One completed deploy: stamps the time AND increments the run counter —
    /// the "time reclaimed" math multiplies seconds-per-run by real runs.
    public func markAgentRun(id: Int64, at date: Date = Date()) throws {
        try withStatement("UPDATE agents SET last_run_at = ?, run_count = run_count + 1 WHERE id = ?;") { statement in
            bind(DateCodec.string(from: date), at: 1, in: statement)
            sqlite3_bind_int64(statement, 2, id)
            try stepDone(statement)
        }
    }

    public func setAgentEnabled(id: Int64, enabled: Bool) throws {
        try withStatement("UPDATE agents SET enabled = ? WHERE id = ?;") { statement in
            sqlite3_bind_int(statement, 1, enabled ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
            try stepDone(statement)
        }
    }

    /// Sets or clears an agent's recurring schedule ("daily@HH:mm" / nil).
    public func setAgentSchedule(id: Int64, schedule: String?) throws {
        try withStatement("UPDATE agents SET schedule = ? WHERE id = ?;") { statement in
            bind(schedule, at: 1, in: statement)
            sqlite3_bind_int64(statement, 2, id)
            try stepDone(statement)
        }
    }

    public func deleteAgent(id: Int64) throws {
        try withStatement("DELETE FROM agents WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
            try stepDone(statement)
        }
    }

    @discardableResult
    public func appendPreferenceEvent(_ event: PreferenceEvent) throws -> PreferenceEvent {
        let sanitized = Self.sanitizedPreferenceEvent(event)
        let sql = """
        INSERT INTO preference_event
            (created_at, kind, reward, surface, app_name, workflow_signature, agent_id, feature_json, evidence_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            bind(DateCodec.string(from: sanitized.createdAt), at: 1, in: statement)
            bind(sanitized.kind.rawValue, at: 2, in: statement)
            bind(sanitized.reward, at: 3, in: statement)
            bind(sanitized.surface, at: 4, in: statement)
            bind(sanitized.appName, at: 5, in: statement)
            bind(sanitized.workflowSignature, at: 6, in: statement)
            bind(sanitized.agentID, at: 7, in: statement)
            bind(sanitized.featureJSON, at: 8, in: statement)
            bind(sanitized.evidenceJSON, at: 9, in: statement)
            try stepDone(statement)
        }
        let stored = PreferenceEvent(
            id: sqlite3_last_insert_rowid(connection.db),
            createdAt: sanitized.createdAt,
            kind: sanitized.kind,
            reward: sanitized.reward,
            surface: sanitized.surface,
            appName: sanitized.appName,
            workflowSignature: sanitized.workflowSignature,
            agentID: sanitized.agentID,
            featureJSON: sanitized.featureJSON,
            evidenceJSON: sanitized.evidenceJSON
        )
        try upsertRoutineProfile(from: stored)
        _ = try? appendAudit(AuditEvent(
            actor: "system",
            action: "preference.event",
            detail: Self.preferenceAuditDetail(stored)
        ))
        _ = try? appendAudit(AuditEvent(
            actor: "system",
            action: "preference.updated",
            detail: Self.preferenceAuditDetail(stored)
        ))
        return stored
    }

    public func recentPreferenceEvents(limit: Int = 500) throws -> [PreferenceEvent] {
        let sql = """
        SELECT id, created_at, kind, reward, surface, app_name, workflow_signature, agent_id, feature_json, evidence_json
        FROM preference_event
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [PreferenceEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodePreferenceEvent(statement))
            }
            return rows
        }
    }

    public func preferenceEvents(
        workflowSignature: String? = nil,
        agentID: Int64? = nil,
        limit: Int = 500
    ) throws -> [PreferenceEvent] {
        let storedSignature = workflowSignature.map(AuditIdentity.hash)
        let sql = """
        SELECT id, created_at, kind, reward, surface, app_name, workflow_signature, agent_id, feature_json, evidence_json
        FROM preference_event
        WHERE (? IS NULL OR workflow_signature = ?)
          AND (? IS NULL OR agent_id = ?)
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(storedSignature, at: 1, in: statement)
            bind(storedSignature, at: 2, in: statement)
            bind(agentID, at: 3, in: statement)
            bind(agentID, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(limit))
            var rows: [PreferenceEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodePreferenceEvent(statement))
            }
            return rows
        }
    }

    public func routineProfiles(limit: Int = 100) throws -> [RoutineProfile] {
        let sql = """
        SELECT id, app_name, surface, weekday, hour_bucket, workflow_signature,
               shown, accepted, dismissed_snoozed, completed, scheduled, disabled_deleted,
               last_seen_at, metadata_json
        FROM routine_profile
        ORDER BY last_seen_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [RoutineProfile] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeRoutineProfile(statement))
            }
            return rows
        }
    }

    public func personalizationSnapshot() throws -> PersonalizationSnapshot {
        let eventCount = Int(Self.scalarValue(connection.db, "SELECT count(*) FROM preference_event;"))
        let routineCount = Int(Self.scalarValue(connection.db, "SELECT count(*) FROM routine_profile;"))
        let disabledSignatures = Int(Self.scalarValue(
            connection.db,
            "SELECT count(DISTINCT workflow_signature) FROM preference_event WHERE kind IN ('agent.disabled', 'agent.deleted') AND workflow_signature IS NOT NULL;"
        ))
        let disabledApps = Int(Self.scalarValue(
            connection.db,
            "SELECT count(DISTINCT app_name) FROM preference_event WHERE kind IN ('personalization.disabled', 'proactive.offer.suppressed') AND app_name IS NOT NULL;"
        ))
        let lastEventAt = try withStatement("SELECT created_at FROM preference_event ORDER BY created_at DESC, id DESC LIMIT 1;") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? DateCodec.date(from: text(statement, 0)) : nil
        }
        return PersonalizationSnapshot(
            eventCount: eventCount,
            routineProfileCount: routineCount,
            disabledSignatureCount: disabledSignatures,
            disabledAppCount: disabledApps,
            lastEventAt: lastEventAt
        )
    }

    public func clearPersonalization(workflowSignature: String? = nil, appName: String? = nil) throws {
        let storedSignature = workflowSignature.map(AuditIdentity.hash)
        let storedAppName = Self.sanitizePreferenceText(appName)
        if workflowSignature == nil && appName == nil {
            try execute("DELETE FROM preference_event; DELETE FROM routine_profile;")
        } else {
            let sql = """
            DELETE FROM preference_event
            WHERE (? IS NULL OR workflow_signature = ?)
              AND (? IS NULL OR app_name = ?);
            """
            try withStatement(sql) { statement in
                bind(storedSignature, at: 1, in: statement)
                bind(storedSignature, at: 2, in: statement)
                bind(storedAppName, at: 3, in: statement)
                bind(storedAppName, at: 4, in: statement)
                try stepDone(statement)
            }
            try withStatement("""
            DELETE FROM routine_profile
            WHERE (? IS NULL OR workflow_signature = ?)
              AND (? IS NULL OR app_name = ?);
            """) { statement in
                bind(storedSignature, at: 1, in: statement)
                bind(storedSignature, at: 2, in: statement)
                bind(storedAppName, at: 3, in: statement)
                bind(storedAppName, at: 4, in: statement)
                try stepDone(statement)
            }
        }
        _ = try? appendAudit(AuditEvent(
            actor: "employee",
            action: "preference.disabled",
            detail: "signatureHash=\(AuditIdentity.hash(workflowSignature)) appHash=\(AuditIdentity.hash(appName))"
        ))
    }

    public func appendAudit(_ event: AuditEvent) throws -> AuditEvent {
        let createdAt = DateCodec.string(from: event.createdAt)
        // Strip high-confidence secrets/PII from the detail before it touches the
        // log: an audit trail must prove who/what/when without becoming a place
        // emails, cards, SSNs, or API keys come to rest (OWASP logging guidance).
        let detail = Self.sanitizeStoredText(event.detail) ?? ""
        let redactionVersion = PIIDetector.redactionVersion
        let keyID = auditSigner.keyID
        // Link this row to the chain head so any later mutation/deletion is evident.
        let prev = (try latestAuditHash()) ?? AuditChain.genesis
        let canonical = AuditChain.canonicalForm(
            createdAt: createdAt,
            actor: event.actor,
            action: event.action,
            detail: detail,
            redactionVersion: redactionVersion,
            keyID: keyID
        )
        let eventHash = AuditChain.hash(prev: prev, canonical: canonical)
        let signature = auditSigner.sign(eventHash: eventHash)
        let sql = """
        INSERT INTO audit_event
            (created_at, actor, action, detail, prev_hash, event_hash, key_id, signature, redaction_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            bind(createdAt, at: 1, in: statement)
            bind(event.actor, at: 2, in: statement)
            bind(event.action, at: 3, in: statement)
            bind(detail, at: 4, in: statement)
            bind(prev, at: 5, in: statement)
            bind(eventHash, at: 6, in: statement)
            bind(keyID, at: 7, in: statement)
            bind(signature, at: 8, in: statement)
            bind(redactionVersion, at: 9, in: statement)
            try stepDone(statement)
        }
        // Mirror the new chain head to the out-of-band anchor so truncation /
        // wholesale rewrite (which keep the internal chain self-consistent) are
        // still detectable.
        auditAnchor.save(AuditHead(count: chainedAuditCount(), hash: eventHash), database: path)
        return AuditEvent(
            id: sqlite3_last_insert_rowid(connection.db),
            createdAt: event.createdAt,
            actor: event.actor,
            action: event.action,
            detail: detail
        )
    }

    /// The chain head: the most recent row's `event_hash`, or nil if no chained
    /// rows exist yet (fresh DB, or a DB whose only rows predate chaining).
    public func latestAuditHash() throws -> String? {
        let sql = "SELECT event_hash FROM audit_event WHERE event_hash IS NOT NULL ORDER BY id DESC LIMIT 1;"
        return try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return text(statement, 0)
        }
    }

    private func chainedAuditCount() -> Int {
        Int(Self.scalarValue(connection.db, "SELECT count(*) FROM audit_event WHERE event_hash IS NOT NULL;"))
    }

    public func auditHead() throws -> AuditHead? {
        guard let hash = try latestAuditHash() else { return nil }
        return AuditHead(count: chainedAuditCount(), hash: hash)
    }

    /// Recompute the audit hash chain and report the first row that no longer
    /// reconciles. Scans ALL rows (not just chained ones) so a forged un-chained
    /// row inserted after the chain begins is caught; legacy pre-chain rows are
    /// allowed only as a leading prefix, and the first chained row must start at
    /// genesis. Detects field mutation (recompute mismatch) and insertion/deletion
    /// (broken `prev_hash` link). Finally compares the head to the out-of-band
    /// anchor to catch truncation / rewrites that keep the chain self-consistent.
    public func verifyAuditChain() throws -> AuditChainStatus {
        let sql = """
        SELECT id, created_at, actor, action, detail, prev_hash, event_hash, key_id, signature, redaction_version
        FROM audit_event ORDER BY id ASC;
        """
        let scan: (status: AuditChainStatus?, verified: Int, head: String, seenAny: Bool, firstUnchainedID: Int64?) = try withStatement(sql) { statement in
            var verified = 0
            var seenChained = false
            var seenAny = false
            var firstUnchainedID: Int64?
            var expectedPrev = AuditChain.genesis
            var lastHash = ""
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                seenAny = true
                guard let storedHash = text(statement, 6) else {
                    // Unchained (legacy) row — allowed ONLY as a leading prefix.
                    if seenChained { return (.broken(atID: id), verified, lastHash, seenAny, firstUnchainedID) }
                    firstUnchainedID = firstUnchainedID ?? id
                    continue
                }
                let createdAt = text(statement, 1) ?? ""
                let actor = text(statement, 2) ?? ""
                let action = text(statement, 3) ?? ""
                let detail = text(statement, 4) ?? ""
                let prevHash = text(statement, 5) ?? ""
                let keyID = text(statement, 7) ?? ""
                let signature = text(statement, 8)
                let redactionVersion = text(statement, 9) ?? ""
                guard !redactionVersion.isEmpty, !keyID.isEmpty else {
                    return (.broken(atID: id), verified, lastHash, seenAny, firstUnchainedID)
                }
                if !seenChained {
                    if prevHash != AuditChain.genesis { return (.broken(atID: id), verified, lastHash, seenAny, firstUnchainedID) }
                    seenChained = true
                } else if prevHash != expectedPrev {
                    return (.broken(atID: id), verified, lastHash, seenAny, firstUnchainedID)
                }
                let canonical = AuditChain.canonicalForm(
                    createdAt: createdAt,
                    actor: actor,
                    action: action,
                    detail: detail,
                    redactionVersion: redactionVersion,
                    keyID: keyID
                )
                if AuditChain.hash(prev: prevHash, canonical: canonical) != storedHash {
                    return (.broken(atID: id), verified, lastHash, seenAny, firstUnchainedID)
                }
                if !auditSigner.verify(signature: signature, eventHash: storedHash, keyID: keyID) {
                    return (.broken(atID: id), verified, lastHash, seenAny, firstUnchainedID)
                }
                expectedPrev = storedHash
                lastHash = storedHash
                verified += 1
            }
            return (nil, verified, lastHash, seenAny, firstUnchainedID)
        }
        if let status = scan.status { return status }
        // Out-of-band anchor: catches truncation / rewrite the internal chain alone
        // can't (a shortened chain still links cleanly). Skipped when no anchor is
        // recorded (e.g. the no-op default), so internal-only integrity still works.
        if let head = auditAnchor.load(database: path),
           head.count != scan.verified || head.hash != scan.head {
            return .truncated(expectedCount: head.count, foundCount: scan.verified)
        }
        if scan.verified == 0 {
            if scan.seenAny, let firstUnchainedID = scan.firstUnchainedID {
                return .unchained(firstID: firstUnchainedID)
            }
            return .empty
        }
        return .intact(verified: scan.verified)
    }

    public func recentAudit(limit: Int = 80) throws -> [AuditEvent] {
        let sql = """
        SELECT id, created_at, actor, action, detail
        FROM audit_event
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [AuditEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(AuditEvent(
                    id: sqlite3_column_int64(statement, 0),
                    createdAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
                    actor: text(statement, 2) ?? "system",
                    action: text(statement, 3) ?? "unknown",
                    detail: text(statement, 4) ?? ""
                ))
            }
            return rows
        }
    }

    public func recentChainedAudit(limit: Int = 80) throws -> [AuditEvent] {
        let sql = """
        SELECT id, created_at, actor, action, detail
        FROM audit_event
        WHERE event_hash IS NOT NULL
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [AuditEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(AuditEvent(
                    id: sqlite3_column_int64(statement, 0),
                    createdAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
                    actor: text(statement, 2) ?? "system",
                    action: text(statement, 3) ?? "unknown",
                    detail: text(statement, 4) ?? ""
                ))
            }
            return rows
        }
    }

    /// Opt-in chronological audit window for trace assembly. Kept separate from
    /// `recentAudit` so the UI's latest-first activity feed remains byte-for-byte
    /// unchanged unless callers explicitly enable trace assembly.
    public func auditWindowForTraceAssembly(
        from start: Date,
        to end: Date,
        limit: Int = 500,
        enableTraceAssembly: Bool = false
    ) throws -> [AuditEvent] {
        guard enableTraceAssembly, limit > 0 else { return [] }
        switch try verifyAuditChain() {
        case .broken, .truncated, .unchained:
            return []
        case .empty, .intact:
            break
        }
        let sql = """
        SELECT id, created_at, actor, action, detail
        FROM audit_event
        WHERE event_hash IS NOT NULL AND created_at >= ? AND created_at <= ?
        ORDER BY created_at ASC, id ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(DateCodec.string(from: start), at: 1, in: statement)
            bind(DateCodec.string(from: end), at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [AuditEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(AuditEvent(
                    id: sqlite3_column_int64(statement, 0),
                    createdAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
                    actor: text(statement, 2) ?? "system",
                    action: text(statement, 3) ?? "unknown",
                    detail: text(statement, 4) ?? ""
                ))
            }
            return rows
        }
    }

    private static func migrate(_ db: OpaquePointer?) throws {
        try execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS recorded_context (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at TEXT NOT NULL,
            captured_ms INTEGER,
            source TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT,
            window_title TEXT,
            ocr_text TEXT,
            image_path TEXT,
            metadata_json TEXT,
            frame_hash INTEGER,
            source_trust TEXT NOT NULL DEFAULT 'untrustedScreen',
            raw_trust_label TEXT,
            injection_score INTEGER NOT NULL DEFAULT 0,
            injection_reasons TEXT,
            user_confirmed INTEGER NOT NULL DEFAULT 0,
            safe_to_show INTEGER NOT NULL DEFAULT 1,
            safe_to_summarize INTEGER NOT NULL DEFAULT 1,
            safe_for_control INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_recorded_context_captured_at
            ON recorded_context(captured_at DESC);

        CREATE TABLE IF NOT EXISTS audit_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT NOT NULL,
            prev_hash TEXT,
            event_hash TEXT,
            key_id TEXT,
            signature TEXT,
            redaction_version TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_audit_event_created_at
            ON audit_event(created_at DESC);

        CREATE TABLE IF NOT EXISTS preference_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            kind TEXT NOT NULL,
            reward REAL NOT NULL,
            surface TEXT,
            app_name TEXT,
            workflow_signature TEXT,
            agent_id INTEGER,
            feature_json TEXT NOT NULL,
            evidence_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_preference_event_created_at
            ON preference_event(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_preference_event_kind
            ON preference_event(kind, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_preference_event_signature
            ON preference_event(workflow_signature, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_preference_event_agent
            ON preference_event(agent_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS routine_profile (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_name TEXT NOT NULL,
            surface TEXT NOT NULL,
            weekday INTEGER NOT NULL,
            hour_bucket INTEGER NOT NULL,
            workflow_signature TEXT NOT NULL DEFAULT '',
            shown INTEGER NOT NULL DEFAULT 0,
            accepted INTEGER NOT NULL DEFAULT 0,
            dismissed_snoozed INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0,
            scheduled INTEGER NOT NULL DEFAULT 0,
            disabled_deleted INTEGER NOT NULL DEFAULT 0,
            last_seen_at TEXT NOT NULL,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            UNIQUE(app_name, surface, weekday, hour_bucket, workflow_signature)
        );
        CREATE INDEX IF NOT EXISTS idx_routine_profile_app_hour
            ON routine_profile(app_name, weekday, hour_bucket);
        CREATE INDEX IF NOT EXISTS idx_routine_profile_signature
            ON routine_profile(workflow_signature, weekday, hour_bucket);
        """, db: db)

        // Best-effort migrations for databases created before these columns existed.
        try? execute("ALTER TABLE recorded_context ADD COLUMN image_path TEXT;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN frame_hash INTEGER;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN captured_ms INTEGER;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN source_trust TEXT NOT NULL DEFAULT 'untrustedScreen';", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN raw_trust_label TEXT;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN injection_score INTEGER NOT NULL DEFAULT 0;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN injection_reasons TEXT;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN user_confirmed INTEGER NOT NULL DEFAULT 0;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN safe_to_show INTEGER NOT NULL DEFAULT 1;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN safe_to_summarize INTEGER NOT NULL DEFAULT 1;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN safe_for_control INTEGER NOT NULL DEFAULT 0;", db: db)
        try execute("""
        CREATE INDEX IF NOT EXISTS idx_recorded_context_captured_ms
            ON recorded_context(captured_ms ASC, id ASC);
        """, db: db)
        try? execute("ALTER TABLE agents ADD COLUMN seconds_per_run INTEGER NOT NULL DEFAULT 0;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN run_count INTEGER NOT NULL DEFAULT 0;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN schedule TEXT;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN goal TEXT;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN evidence_ids_json TEXT NOT NULL DEFAULT '[]';", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN demo_sketches_json TEXT NOT NULL DEFAULT '[]';", db: db)
        try? execute("ALTER TABLE input_event ADD COLUMN target_descriptor TEXT;", db: db)
        try? execute("ALTER TABLE input_event ADD COLUMN captured_ms INTEGER;", db: db)
        // Tamper-evident audit chain columns for databases created before they existed.
        try? execute("ALTER TABLE audit_event ADD COLUMN prev_hash TEXT;", db: db)
        try? execute("ALTER TABLE audit_event ADD COLUMN event_hash TEXT;", db: db)
        try? execute("ALTER TABLE audit_event ADD COLUMN key_id TEXT;", db: db)
        try? execute("ALTER TABLE audit_event ADD COLUMN signature TEXT;", db: db)
        try? execute("ALTER TABLE audit_event ADD COLUMN redaction_version TEXT;", db: db)

        // Full-text search over recorded moments. External-content FTS5 indexes the
        // text columns of `recorded_context` (no duplicated content); triggers keep
        // it in sync — `_ad`/`_au` issue the special 'delete' command echoing the
        // old row so deletes (including retention pruning) stay consistent.
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS rewind_fts USING fts5(
            ocr_text, window_title, app_name,
            content='recorded_context', content_rowid='id'
        );

        CREATE TRIGGER IF NOT EXISTS recorded_context_ai AFTER INSERT ON recorded_context BEGIN
            INSERT INTO rewind_fts(rowid, ocr_text, window_title, app_name)
            VALUES (new.id, new.ocr_text, new.window_title, new.app_name);
        END;
        CREATE TRIGGER IF NOT EXISTS recorded_context_ad AFTER DELETE ON recorded_context BEGIN
            INSERT INTO rewind_fts(rewind_fts, rowid, ocr_text, window_title, app_name)
            VALUES ('delete', old.id, old.ocr_text, old.window_title, old.app_name);
        END;
        CREATE TRIGGER IF NOT EXISTS recorded_context_au AFTER UPDATE ON recorded_context BEGIN
            INSERT INTO rewind_fts(rewind_fts, rowid, ocr_text, window_title, app_name)
            VALUES ('delete', old.id, old.ocr_text, old.window_title, old.app_name);
            INSERT INTO rewind_fts(rowid, ocr_text, window_title, app_name)
            VALUES (new.id, new.ocr_text, new.window_title, new.app_name);
        END;
        """, db: db)

        // Recorded user input (clicks/keys) and saved agents built from repeated
        // workflows. Input is local-only and privacy-gated at the recorder.
        try execute("""
        CREATE TABLE IF NOT EXISTS input_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at TEXT NOT NULL,
            captured_ms INTEGER,
            kind TEXT NOT NULL,
            x REAL,
            y REAL,
            text TEXT,
            key TEXT,
            modifiers TEXT,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT,
            window_title TEXT,
            target_descriptor TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_input_event_captured_at
            ON input_event(captured_at DESC);
        CREATE INDEX IF NOT EXISTS idx_input_event_captured_ms
            ON input_event(captured_ms ASC, id ASC);

        CREATE TABLE IF NOT EXISTS agents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            source TEXT NOT NULL,
            signature TEXT NOT NULL UNIQUE,
            recipe_json TEXT NOT NULL,
            apps TEXT,
            estimated_seconds INTEGER NOT NULL DEFAULT 0,
            seconds_per_run INTEGER NOT NULL DEFAULT 0,
            evidence_count INTEGER NOT NULL DEFAULT 0,
            evidence_ids_json TEXT NOT NULL DEFAULT '[]',
            run_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            last_run_at TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            schedule TEXT,
            goal TEXT,
            demo_sketches_json TEXT NOT NULL DEFAULT '[]'
        );

        CREATE TABLE IF NOT EXISTS context_embedding (
            context_id INTEGER PRIMARY KEY,
            vector BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS context_chunk_embedding (
            context_id INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            text_digest INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (context_id, chunk_index)
        );
        CREATE INDEX IF NOT EXISTS idx_context_chunk_embedding_context
            ON context_chunk_embedding(context_id);

        CREATE TABLE IF NOT EXISTS ocr_line (
            context_id INTEGER NOT NULL,
            line_index INTEGER NOT NULL,
            source TEXT NOT NULL,
            text TEXT NOT NULL,
            x REAL,
            y REAL,
            width REAL,
            height REAL,
            confidence REAL,
            PRIMARY KEY (context_id, line_index, source),
            FOREIGN KEY(context_id) REFERENCES recorded_context(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_ocr_line_context
            ON ocr_line(context_id, line_index);

        CREATE TABLE IF NOT EXISTS ocr_structure (
            context_id INTEGER PRIMARY KEY,
            version INTEGER NOT NULL,
            json TEXT NOT NULL,
            searchable_text TEXT NOT NULL DEFAULT '',
            FOREIGN KEY(context_id) REFERENCES recorded_context(id) ON DELETE CASCADE
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS ocr_structure_fts USING fts5(
            searchable_text,
            context_id UNINDEXED
        );

        CREATE TRIGGER IF NOT EXISTS ocr_structure_ai AFTER INSERT ON ocr_structure BEGIN
            INSERT INTO ocr_structure_fts(rowid, context_id, searchable_text)
            VALUES (new.context_id, new.context_id, new.searchable_text);
        END;
        CREATE TRIGGER IF NOT EXISTS ocr_structure_ad AFTER DELETE ON ocr_structure BEGIN
            DELETE FROM ocr_structure_fts WHERE rowid = old.context_id;
        END;
        CREATE TRIGGER IF NOT EXISTS ocr_structure_au AFTER UPDATE ON ocr_structure BEGIN
            DELETE FROM ocr_structure_fts WHERE rowid = old.context_id;
            INSERT INTO ocr_structure_fts(rowid, context_id, searchable_text)
            VALUES (new.context_id, new.context_id, new.searchable_text);
        END;

        CREATE TABLE IF NOT EXISTS frame_signature (
            context_id INTEGER PRIMARY KEY,
            dhash INTEGER NOT NULL,
            combined_grid_hash INTEGER NOT NULL,
            grid_hashes TEXT NOT NULL,
            block_hash INTEGER NOT NULL,
            changed_cells_mask INTEGER NOT NULL,
            text_digest INTEGER,
            FOREIGN KEY(context_id) REFERENCES recorded_context(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS timeline_episode (
            id INTEGER PRIMARY KEY,
            start_at TEXT NOT NULL,
            end_at TEXT NOT NULL,
            bundle_identifier TEXT,
            app_name TEXT NOT NULL,
            window_title_hint TEXT,
            context_count INTEGER NOT NULL,
            representative_context_id INTEGER NOT NULL,
            summary_text TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_timeline_episode_start
            ON timeline_episode(start_at ASC, id ASC);
        CREATE INDEX IF NOT EXISTS idx_timeline_episode_bundle_time
            ON timeline_episode(bundle_identifier, start_at ASC);

        CREATE TRIGGER IF NOT EXISTS recorded_context_embedding_ad
        AFTER DELETE ON recorded_context BEGIN
            DELETE FROM context_embedding WHERE context_id = old.id;
            DELETE FROM context_chunk_embedding WHERE context_id = old.id;
            DELETE FROM ocr_line WHERE context_id = old.id;
            DELETE FROM ocr_structure WHERE context_id = old.id;
            DELETE FROM frame_signature WHERE context_id = old.id;
        END;

        CREATE TABLE IF NOT EXISTS context_visual_embedding (
            context_id INTEGER NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            revision TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            vector BLOB NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (context_id, provider, model, revision)
        );
        CREATE INDEX IF NOT EXISTS idx_context_visual_embedding_compat
            ON context_visual_embedding(provider, model, revision, dimension);
        CREATE TRIGGER IF NOT EXISTS recorded_context_visual_embedding_ad
        AFTER DELETE ON recorded_context BEGIN
            DELETE FROM context_visual_embedding WHERE context_id = old.id;
        END;

        CREATE TABLE IF NOT EXISTS memory_event (
            context_id INTEGER PRIMARY KEY,
            captured_at TEXT NOT NULL,
            app_name TEXT NOT NULL,
            summary TEXT NOT NULL,
            entities_json TEXT NOT NULL,
            importance REAL NOT NULL,
            last_accessed_at TEXT,
            access_count INTEGER NOT NULL DEFAULT 0,
            links_json TEXT NOT NULL,
            metadata_json TEXT NOT NULL,
            FOREIGN KEY(context_id) REFERENCES recorded_context(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_memory_event_time
            ON memory_event(captured_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memory_event_importance
            ON memory_event(importance DESC, captured_at DESC);
        CREATE TRIGGER IF NOT EXISTS recorded_context_memory_event_ad
        AFTER DELETE ON recorded_context BEGIN
            DELETE FROM memory_event WHERE context_id = old.id;
        END;
        """, db: db)

        try execute("""
        CREATE TABLE IF NOT EXISTS agent_trace (
            trace_id TEXT PRIMARY KEY,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            surface TEXT NOT NULL,
            actor TEXT NOT NULL,
            title TEXT NOT NULL,
            goal_hash TEXT,
            app_name TEXT,
            bundle_identifier TEXT,
            status TEXT NOT NULL,
            failure_kind TEXT,
            root_audit_event_id INTEGER REFERENCES audit_event(id),
            total_input_tokens INTEGER NOT NULL DEFAULT 0,
            total_cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            total_output_tokens INTEGER NOT NULL DEFAULT 0,
            total_reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            total_cost_microusd INTEGER NOT NULL DEFAULT 0,
            redaction_policy TEXT NOT NULL DEFAULT 'content-ref-only',
            metadata_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_agent_trace_started
            ON agent_trace(started_at DESC);
        CREATE INDEX IF NOT EXISTS idx_agent_trace_status_failure
            ON agent_trace(status, failure_kind);

        CREATE TABLE IF NOT EXISTS agent_span (
            span_id TEXT PRIMARY KEY,
            trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id) ON DELETE CASCADE,
            parent_span_id TEXT REFERENCES agent_span(span_id),
            audit_event_id INTEGER REFERENCES audit_event(id),
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_ms INTEGER,
            status TEXT NOT NULL,
            failure_kind TEXT,
            gen_ai_operation TEXT,
            model_provider TEXT,
            model_name TEXT,
            tool_name TEXT,
            tool_type TEXT,
            app_name TEXT,
            recorded_context_id INTEGER REFERENCES recorded_context(id),
            input_event_id INTEGER REFERENCES input_event(id),
            input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
            cost_microusd INTEGER NOT NULL DEFAULT 0,
            prompt_sha256 TEXT,
            response_sha256 TEXT,
            attributes_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_agent_span_trace_started
            ON agent_span(trace_id, started_at);

        CREATE TABLE IF NOT EXISTS trace_event (
            event_id TEXT PRIMARY KEY,
            trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id) ON DELETE CASCADE,
            span_id TEXT REFERENCES agent_span(span_id) ON DELETE CASCADE,
            audit_event_id INTEGER REFERENCES audit_event(id),
            created_at TEXT NOT NULL,
            name TEXT NOT NULL,
            severity TEXT NOT NULL DEFAULT 'info',
            failure_kind TEXT,
            attributes_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_trace_event_trace_created
            ON trace_event(trace_id, created_at);

        CREATE TABLE IF NOT EXISTS model_cost_ledger (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id) ON DELETE CASCADE,
            span_id TEXT NOT NULL REFERENCES agent_span(span_id) ON DELETE CASCADE,
            created_at TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            response_id TEXT,
            price_card_version TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
            cost_microusd INTEGER NOT NULL DEFAULT 0,
            billable INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_model_cost_trace
            ON model_cost_ledger(trace_id, created_at);

        CREATE TABLE IF NOT EXISTS trace_eval (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trace_id TEXT NOT NULL REFERENCES agent_trace(trace_id) ON DELETE CASCADE,
            span_id TEXT REFERENCES agent_span(span_id) ON DELETE CASCADE,
            created_at TEXT NOT NULL,
            evaluator_kind TEXT NOT NULL,
            evaluator_name TEXT NOT NULL,
            score_value REAL,
            score_label TEXT,
            explanation_redacted TEXT,
            confidence REAL,
            failure_kind TEXT,
            source_span_id TEXT REFERENCES agent_span(span_id)
        );
        CREATE INDEX IF NOT EXISTS idx_trace_eval_trace_created
            ON trace_eval(trace_id, created_at);
        """, db: db)
        try? execute("ALTER TABLE model_cost_ledger ADD COLUMN response_id TEXT;", db: db)
        try? execute("ALTER TABLE trace_eval ADD COLUMN failure_kind TEXT;", db: db)

        try execute("""
        CREATE TABLE IF NOT EXISTS agent_experience_case (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            app_name TEXT NOT NULL,
            goal_pattern TEXT NOT NULL,
            recipe_signature TEXT NOT NULL,
            skill_slug TEXT,
            outcome TEXT NOT NULL,
            verification_signal TEXT,
            failure_kind TEXT,
            evidence_ids_json TEXT NOT NULL,
            action_count INTEGER NOT NULL,
            retained_score REAL NOT NULL,
            user_feedback TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_agent_experience_case_app_goal
            ON agent_experience_case(app_name, goal_pattern);
        CREATE INDEX IF NOT EXISTS idx_agent_experience_case_failure
            ON agent_experience_case(failure_kind);
        CREATE INDEX IF NOT EXISTS idx_agent_experience_case_recipe
            ON agent_experience_case(recipe_signature);

        CREATE TABLE IF NOT EXISTS agent_failure_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            app_name TEXT NOT NULL,
            goal_tokens_json TEXT NOT NULL,
            failure_kind TEXT NOT NULL,
            first_bad_action TEXT,
            screen_signature_hash TEXT,
            target_hash TEXT,
            state_summary TEXT,
            repair_hint TEXT NOT NULL,
            recovery_evidence_hash TEXT,
            retained_score REAL NOT NULL,
            expires_after_successes INTEGER NOT NULL DEFAULT 2,
            remaining_counterexamples INTEGER NOT NULL DEFAULT 2,
            last_used_at TEXT,
            expired_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_agent_failure_memory_app_failure
            ON agent_failure_memory(app_name, failure_kind, created_at DESC);
        """, db: db)
        try? execute("ALTER TABLE agent_failure_memory ADD COLUMN state_summary TEXT;", db: db)
        try? execute("ALTER TABLE agent_failure_memory ADD COLUMN expires_after_successes INTEGER NOT NULL DEFAULT 2;", db: db)
        try? execute("ALTER TABLE agent_failure_memory ADD COLUMN remaining_counterexamples INTEGER NOT NULL DEFAULT 2;", db: db)
        try? execute("ALTER TABLE agent_failure_memory ADD COLUMN last_used_at TEXT;", db: db)
        try? execute("ALTER TABLE agent_failure_memory ADD COLUMN expired_at TEXT;", db: db)

        // Native work graph storage. Entities and evidence links are separate so
        // aliases can be merged without duplicating moment citations. The valid_*
        // columns describe the world-time assertion; transaction_* describes when
        // Cascade stored or retracted that assertion.
        try execute("""
	        CREATE TABLE IF NOT EXISTS graph_entity (
	            id INTEGER PRIMARY KEY AUTOINCREMENT,
	            kind TEXT NOT NULL,
	            canonical_value TEXT NOT NULL,
	            display_name TEXT NOT NULL,
	            normalized_value TEXT,
	            confidence REAL NOT NULL DEFAULT 1.0,
	            source TEXT NOT NULL DEFAULT 'legacy',
	            pii_class TEXT,
	            metadata_json TEXT,
	            first_seen_at TEXT NOT NULL,
	            last_seen_at TEXT NOT NULL,
	            valid_from TEXT NOT NULL,
	            valid_to TEXT,
	            transaction_from TEXT NOT NULL,
	            transaction_to TEXT,
	            created_at TEXT NOT NULL,
	            updated_at TEXT NOT NULL,
	            UNIQUE(kind, canonical_value)
	        );
	        CREATE INDEX IF NOT EXISTS idx_graph_entity_type_key
	            ON graph_entity(kind, canonical_value);
	        CREATE INDEX IF NOT EXISTS idx_graph_entity_kind_seen
	            ON graph_entity(kind, last_seen_at DESC);
	        CREATE INDEX IF NOT EXISTS idx_graph_entity_current
	            ON graph_entity(kind, transaction_to, last_seen_at DESC);

	        CREATE TABLE IF NOT EXISTS graph_entity_alias (
	            id INTEGER PRIMARY KEY AUTOINCREMENT,
	            entity_id INTEGER NOT NULL,
	            alias TEXT NOT NULL,
	            normalized_alias TEXT NOT NULL,
	            source TEXT NOT NULL,
	            confidence REAL NOT NULL DEFAULT 1.0,
	            mention_count INTEGER NOT NULL DEFAULT 1,
	            first_seen_at TEXT NOT NULL,
	            last_seen_at TEXT NOT NULL,
	            valid_from TEXT NOT NULL,
	            valid_to TEXT,
	            transaction_from TEXT NOT NULL,
	            transaction_to TEXT,
	            created_at TEXT NOT NULL,
	            updated_at TEXT NOT NULL,
	            UNIQUE(entity_id, normalized_alias),
	            FOREIGN KEY(entity_id) REFERENCES graph_entity(id) ON DELETE CASCADE
	        );
	        CREATE INDEX IF NOT EXISTS idx_graph_entity_alias_lookup
	            ON graph_entity_alias(normalized_alias);

	        CREATE TABLE IF NOT EXISTS context_entity_link (
	            id INTEGER PRIMARY KEY AUTOINCREMENT,
	            context_id INTEGER NOT NULL,
	            entity_id INTEGER NOT NULL,
	            relation TEXT NOT NULL,
	            role TEXT NOT NULL DEFAULT 'observed',
	            extractor TEXT NOT NULL DEFAULT 'legacy',
	            evidence_snippet TEXT NOT NULL,
	            span_start INTEGER,
	            span_end INTEGER,
	            confidence REAL NOT NULL DEFAULT 1.0,
	            observed_at TEXT NOT NULL,
	            valid_from TEXT NOT NULL,
	            valid_to TEXT,
	            transaction_from TEXT NOT NULL,
	            transaction_to TEXT,
	            created_at TEXT NOT NULL,
	            updated_at TEXT NOT NULL,
	            UNIQUE(context_id, entity_id, relation),
	            FOREIGN KEY(context_id) REFERENCES recorded_context(id) ON DELETE CASCADE,
	            FOREIGN KEY(entity_id) REFERENCES graph_entity(id) ON DELETE CASCADE
	        );
	        CREATE INDEX IF NOT EXISTS idx_context_entity_link_entity_time
	            ON context_entity_link(entity_id, observed_at ASC, context_id ASC);
	        CREATE INDEX IF NOT EXISTS idx_context_entity_link_context
	            ON context_entity_link(context_id);
	        CREATE INDEX IF NOT EXISTS idx_context_entity_link_role_extractor
	            ON context_entity_link(context_id, entity_id, role, extractor, span_start);

	        CREATE TABLE IF NOT EXISTS graph_edge (
	            id INTEGER PRIMARY KEY AUTOINCREMENT,
	            source_entity_id INTEGER NOT NULL,
	            target_entity_id INTEGER NOT NULL,
	            relation TEXT NOT NULL,
	            evidence_snippet TEXT NOT NULL,
	            weight REAL NOT NULL DEFAULT 1.0,
	            confidence REAL NOT NULL DEFAULT 1.0,
	            provenance_context_id INTEGER REFERENCES recorded_context(id) ON DELETE SET NULL,
	            provenance_input_event_id INTEGER REFERENCES input_event(id) ON DELETE SET NULL,
	            extractor TEXT NOT NULL DEFAULT 'legacy',
	            metadata_json TEXT,
	            first_seen_at TEXT NOT NULL,
	            last_seen_at TEXT NOT NULL,
	            valid_from TEXT NOT NULL,
	            valid_to TEXT,
	            transaction_from TEXT NOT NULL,
	            transaction_to TEXT,
	            created_at TEXT NOT NULL,
	            updated_at TEXT NOT NULL,
	            UNIQUE(source_entity_id, target_entity_id, relation),
	            FOREIGN KEY(source_entity_id) REFERENCES graph_entity(id) ON DELETE CASCADE,
	            FOREIGN KEY(target_entity_id) REFERENCES graph_entity(id) ON DELETE CASCADE
	        );
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_source
	            ON graph_edge(source_entity_id, relation);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_target
	            ON graph_edge(target_entity_id, relation);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_time_provenance
	            ON graph_edge(relation, valid_from, valid_to, provenance_context_id);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_current
	            ON graph_edge(source_entity_id, relation, transaction_to, valid_to);

	        CREATE TABLE IF NOT EXISTS graph_edge_assertion (
	            id INTEGER PRIMARY KEY AUTOINCREMENT,
	            source_entity_id INTEGER NOT NULL,
	            target_entity_id INTEGER NOT NULL,
	            relation TEXT NOT NULL,
	            evidence_snippet TEXT NOT NULL,
	            weight REAL NOT NULL DEFAULT 1.0,
	            first_seen_at TEXT NOT NULL,
	            last_seen_at TEXT NOT NULL,
	            valid_from TEXT NOT NULL,
	            valid_to TEXT,
	            transaction_from TEXT NOT NULL,
	            transaction_to TEXT,
	            confidence REAL NOT NULL DEFAULT 1.0,
	            provenance_context_id INTEGER REFERENCES recorded_context(id) ON DELETE SET NULL,
	            provenance_input_event_id INTEGER REFERENCES input_event(id) ON DELETE SET NULL,
	            extractor TEXT NOT NULL DEFAULT 'legacy',
	            metadata_json TEXT,
	            created_at TEXT NOT NULL,
	            updated_at TEXT NOT NULL,
	            FOREIGN KEY(source_entity_id) REFERENCES graph_entity(id) ON DELETE CASCADE,
	            FOREIGN KEY(target_entity_id) REFERENCES graph_entity(id) ON DELETE CASCADE
	        );
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_assertion_current
	            ON graph_edge_assertion(source_entity_id, relation, transaction_to, valid_to);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_assertion_asof
	            ON graph_edge_assertion(transaction_from, transaction_to, valid_from, valid_to);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_assertion_provenance
	            ON graph_edge_assertion(provenance_context_id, provenance_input_event_id);

	        CREATE TRIGGER IF NOT EXISTS recorded_context_entity_link_ad
	        AFTER DELETE ON recorded_context BEGIN
	            DELETE FROM context_entity_link WHERE context_id = old.id;
	            UPDATE graph_edge SET provenance_context_id = NULL WHERE provenance_context_id = old.id;
	            UPDATE graph_edge_assertion SET provenance_context_id = NULL WHERE provenance_context_id = old.id;
	        END;
	        """, db: db)
	        try? execute("ALTER TABLE graph_entity ADD COLUMN normalized_value TEXT;", db: db)
	        try? execute("ALTER TABLE graph_entity ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0;", db: db)
	        try? execute("ALTER TABLE graph_entity ADD COLUMN source TEXT NOT NULL DEFAULT 'legacy';", db: db)
	        try? execute("ALTER TABLE graph_entity ADD COLUMN pii_class TEXT;", db: db)
	        try? execute("ALTER TABLE graph_entity ADD COLUMN metadata_json TEXT;", db: db)
	        try? execute("ALTER TABLE graph_entity_alias ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0;", db: db)
	        try? execute("ALTER TABLE context_entity_link ADD COLUMN role TEXT NOT NULL DEFAULT 'observed';", db: db)
	        try? execute("ALTER TABLE context_entity_link ADD COLUMN extractor TEXT NOT NULL DEFAULT 'legacy';", db: db)
	        try? execute("ALTER TABLE context_entity_link ADD COLUMN span_start INTEGER;", db: db)
	        try? execute("ALTER TABLE context_entity_link ADD COLUMN span_end INTEGER;", db: db)
	        try? execute("ALTER TABLE context_entity_link ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0;", db: db)
	        try? execute("ALTER TABLE graph_edge ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0;", db: db)
	        try? execute("ALTER TABLE graph_edge ADD COLUMN provenance_context_id INTEGER REFERENCES recorded_context(id) ON DELETE SET NULL;", db: db)
	        try? execute("ALTER TABLE graph_edge ADD COLUMN provenance_input_event_id INTEGER REFERENCES input_event(id) ON DELETE SET NULL;", db: db)
	        try? execute("ALTER TABLE graph_edge ADD COLUMN extractor TEXT NOT NULL DEFAULT 'legacy';", db: db)
	        try? execute("ALTER TABLE graph_edge ADD COLUMN metadata_json TEXT;", db: db)
	        try execute("""
	        CREATE INDEX IF NOT EXISTS idx_graph_entity_type_key
	            ON graph_entity(kind, canonical_value);
	        CREATE INDEX IF NOT EXISTS idx_graph_entity_current
	            ON graph_entity(kind, transaction_to, last_seen_at DESC);
	        CREATE INDEX IF NOT EXISTS idx_context_entity_link_role_extractor
	            ON context_entity_link(context_id, entity_id, role, extractor, span_start);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_time_provenance
	            ON graph_edge(relation, valid_from, valid_to, provenance_context_id);
	        CREATE INDEX IF NOT EXISTS idx_graph_edge_current
	            ON graph_edge(source_entity_id, relation, transaction_to, valid_to);
	        """, db: db)

        // Backfill the index for rows inserted before FTS existed (triggers only
        // fire on new writes). Counts match in steady state, so this rebuild runs
        // at most once after upgrading.
        if scalarValue(db, "SELECT count(*) FROM recorded_context;") != scalarValue(db, "SELECT count(*) FROM rewind_fts;") {
            try? execute("INSERT INTO rewind_fts(rewind_fts) VALUES('rebuild');", db: db)
        }
    }

    private static func configureConnection(_ db: OpaquePointer?) throws {
        try execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        PRAGMA synchronous=NORMAL;
        PRAGMA busy_timeout=2500;
        PRAGMA temp_store=MEMORY;
        PRAGMA mmap_size=268435456;
        PRAGMA wal_autocheckpoint=512;
        """, db: db)
    }

    /// Runs a single-column scalar query and returns the first integer result
    /// (0 if the query yields no row). Used only during migration.
    private static func scalarValue(_ db: OpaquePointer?, _ sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, db: connection.db)
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN TRANSACTION;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private static func execute(_ sql: String, db: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) }
                ?? db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
                ?? "unknown"
            sqlite3_free(error)
            throw CascadeStoreError.sqlite(message)
        }
    }

    internal func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CascadeStoreError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    internal func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func resetStatement(_ statement: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func clearBindings(_ statement: OpaquePointer) throws {
        guard sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func bindContext(_ context: RecordedContext, at rowIndex: Int, in statement: OpaquePointer) throws {
        try batchBindFailureInjector?(.recordedContext, rowIndex)
        try bindChecked(DateCodec.string(from: context.capturedAt), at: 1, in: statement)
        try bindChecked(EventStoreLayout.capturedMilliseconds(for: context.capturedAt), at: 2, in: statement)
        try bindChecked(context.source.rawValue, at: 3, in: statement)
        try bindChecked(context.appName, at: 4, in: statement)
        try bindChecked(context.bundleIdentifier, at: 5, in: statement)
        try bindChecked(context.windowTitle, at: 6, in: statement)
        try bindChecked(context.ocrText, at: 7, in: statement)
        try bindChecked(context.imagePath, at: 8, in: statement)
        try bindChecked(context.metadataJSON, at: 9, in: statement)
        try bindChecked(context.frameHash, at: 10, in: statement)
        try bindChecked(context.sourceTrust, at: 11, in: statement)
        try bindChecked(context.rawTrustLabel, at: 12, in: statement)
        try bindChecked(Int64(context.injectionScore), at: 13, in: statement)
        try bindChecked(context.injectionReasonsJSON, at: 14, in: statement)
        try bindChecked(Int64(context.userConfirmed ? 1 : 0), at: 15, in: statement)
        try bindChecked(Int64(context.safeToShow ? 1 : 0), at: 16, in: statement)
        try bindChecked(Int64(context.safeToSummarize ? 1 : 0), at: 17, in: statement)
        try bindChecked(Int64(context.safeForControl ? 1 : 0), at: 18, in: statement)
    }

    private static func sanitizedContext(_ context: RecordedContext) -> RecordedContext {
        RecordedContext(
            id: context.id,
            capturedAt: context.capturedAt,
            source: context.source,
            appName: sanitizeStoredText(context.appName) ?? context.appName,
            bundleIdentifier: sanitizeStoredText(context.bundleIdentifier),
            windowTitle: sanitizeStoredText(context.windowTitle),
            ocrText: sanitizeStoredText(context.ocrText),
            imagePath: context.imagePath,
            metadataJSON: context.metadataJSON,
            frameHash: context.frameHash,
            sourceTrust: sanitizeStoredText(context.sourceTrust) ?? context.sourceTrust,
            rawTrustLabel: sanitizeStoredText(context.rawTrustLabel),
            injectionScore: context.injectionScore,
            injectionReasonsJSON: context.injectionReasonsJSON,
            userConfirmed: context.userConfirmed,
            safeToShow: context.safeToShow,
            safeToSummarize: context.safeToSummarize,
            safeForControl: context.safeForControl
        )
    }

    private static func sanitizedPreferenceEvent(_ event: PreferenceEvent) -> PreferenceEvent {
        let appName = sanitizePreferenceText(event.appName)
        let surface = sanitizePreferenceText(event.surface)
        let signature = event.workflowSignature.map { AuditIdentity.hash($0) }
        return PreferenceEvent(
            id: event.id,
            createdAt: event.createdAt,
            kind: event.kind,
            reward: event.reward,
            surface: surface,
            appName: appName,
            workflowSignature: signature,
            agentID: event.agentID,
            featureJSON: sanitizePreferenceJSON(event.featureJSON) ?? "{}",
            evidenceJSON: sanitizePreferenceJSON(event.evidenceJSON)
        )
    }

    private static func sanitizePreferenceText(_ value: String?) -> String? {
        guard let value = sanitizeStoredText(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if PrivacyRules.isSensitiveText(value) { return "hash:\(AuditIdentity.hash(value))" }
        return AuditIdentity.safeToken(value.lowercased())
    }

    private static func sanitizePreferenceJSON(_ json: String?) -> String? {
        guard let json, !json.isEmpty else { return nil }
        let piiRedacted = redactPIIForStorage(json)
        let keywordRedacted = PrivacyRules.redactingSensitiveKeywords(in: piiRedacted)
        guard !keywordRedacted.isEmpty else { return nil }
        if keywordRedacted == json { return json }
        return keywordRedacted
    }

    private func upsertRoutineProfile(from event: PreferenceEvent) throws {
        let counts = Self.routineCounts(for: event.kind)
        guard counts.shown + counts.accepted + counts.dismissedSnoozed + counts.completed + counts.scheduled + counts.disabledDeleted > 0 else {
            return
        }
        let components = Calendar.current.dateComponents([.weekday, .hour], from: event.createdAt)
        let weekday = components.weekday ?? 1
        let hourBucket = components.hour ?? 0
        let appName = event.appName ?? "unknown"
        let surface = event.surface ?? "unknown"
        let signature = event.workflowSignature ?? ""
        let lastSeen = DateCodec.string(from: event.createdAt)
        let sql = """
        INSERT INTO routine_profile
            (app_name, surface, weekday, hour_bucket, workflow_signature,
             shown, accepted, dismissed_snoozed, completed, scheduled, disabled_deleted,
             last_seen_at, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(app_name, surface, weekday, hour_bucket, workflow_signature) DO UPDATE SET
            shown = shown + excluded.shown,
            accepted = accepted + excluded.accepted,
            dismissed_snoozed = dismissed_snoozed + excluded.dismissed_snoozed,
            completed = completed + excluded.completed,
            scheduled = scheduled + excluded.scheduled,
            disabled_deleted = disabled_deleted + excluded.disabled_deleted,
            last_seen_at = excluded.last_seen_at,
            metadata_json = excluded.metadata_json;
        """
        try withStatement(sql) { statement in
            bind(appName, at: 1, in: statement)
            bind(surface, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(weekday))
            sqlite3_bind_int(statement, 4, Int32(hourBucket))
            bind(signature, at: 5, in: statement)
            sqlite3_bind_int(statement, 6, Int32(counts.shown))
            sqlite3_bind_int(statement, 7, Int32(counts.accepted))
            sqlite3_bind_int(statement, 8, Int32(counts.dismissedSnoozed))
            sqlite3_bind_int(statement, 9, Int32(counts.completed))
            sqlite3_bind_int(statement, 10, Int32(counts.scheduled))
            sqlite3_bind_int(statement, 11, Int32(counts.disabledDeleted))
            bind(lastSeen, at: 12, in: statement)
            bind(event.featureJSON, at: 13, in: statement)
            try stepDone(statement)
        }
    }

    private static func routineCounts(for kind: PreferenceEventKind) -> (
        shown: Int,
        accepted: Int,
        dismissedSnoozed: Int,
        completed: Int,
        scheduled: Int,
        disabledDeleted: Int
    ) {
        switch kind {
        case .agentProposed, .proactiveOfferShown:
            return (1, 0, 0, 0, 0, 0)
        case .agentApproved, .proactiveAccepted, .agentEnabled, .coldStartSet:
            return (0, 1, 0, 0, 0, 0)
        case .agentDeclined, .proactiveSnoozed, .proactiveDismissed, .proactiveOfferSuppressed:
            return (0, 0, 1, 0, 0, 0)
        case .agentRunCompleted:
            return (0, 0, 0, 1, 0, 0)
        case .agentScheduleSet:
            return (0, 0, 0, 0, 1, 0)
        case .agentDisabled, .agentDeleted, .agentScheduleCleared, .personalizationCleared, .personalizationDisabled:
            return (0, 0, 0, 0, 0, 1)
        }
    }

    private static func preferenceAuditDetail(_ event: PreferenceEvent) -> String {
        var parts = [
            "kind=\(AuditIdentity.safeToken(event.kind.rawValue))",
            String(format: "reward=%.2f", event.reward),
            "signatureHash=\(AuditIdentity.hash(event.workflowSignature))"
        ]
        if let agentID = event.agentID { parts.append("agentID=\(agentID)") }
        if let appName = event.appName { parts.append("app=\(AuditIdentity.safeToken(appName))") }
        if let surface = event.surface { parts.append("surface=\(AuditIdentity.safeToken(surface))") }
        return parts.joined(separator: " ")
    }

    static func sanitizeStoredText(_ text: String?) -> String? {
        guard let text else { return nil }
        let piiRedacted = redactPIIForStorage(text)
        let keywordRedacted = PrivacyRules.redactingSensitiveKeywords(in: piiRedacted)
        return keywordRedacted.isEmpty ? nil : keywordRedacted
    }

    private static func redactPIIForStorage(_ text: String) -> String {
        let findings = PIIDetector.findings(in: text, includeNames: false)
        guard !findings.isEmpty else { return text }

        var redacted = text
        for finding in findings.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let replacement = finding.type == .url
                ? privacySafeURLText(finding.text)
                : finding.type.placeholder
            redacted.replaceSubrange(finding.range, with: replacement)
        }
        return redacted
    }

    private static func privacySafeURLText(_ rawValue: String) -> String {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return PIIType.url.placeholder
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        if !url.path.isEmpty, url.path != "/" {
            components.path = url.path
        }
        return components.string ?? "\(scheme)://\(host)"
    }

    private func bindInputEvent(_ event: InputEvent, at rowIndex: Int, in statement: OpaquePointer) throws {
        try batchBindFailureInjector?(.inputEvent, rowIndex)
        let sanitizedText = InputEventSanitizer.sanitize(text: event.text, kind: event.kind)
        let sanitizedDescriptor = InputEventSanitizer.sanitize(descriptor: event.targetDescriptor)
        try bindChecked(DateCodec.string(from: event.capturedAt), at: 1, in: statement)
        try bindChecked(EventStoreLayout.capturedMilliseconds(for: event.capturedAt), at: 2, in: statement)
        try bindChecked(event.kind.rawValue, at: 3, in: statement)
        try bindChecked(event.x, at: 4, in: statement)
        try bindChecked(event.y, at: 5, in: statement)
        try bindChecked(sanitizedText, at: 6, in: statement)
        try bindChecked(event.key, at: 7, in: statement)
        try bindChecked(event.modifiers.isEmpty ? nil : event.modifiers.joined(separator: ","), at: 8, in: statement)
        try bindChecked(event.appName, at: 9, in: statement)
        try bindChecked(event.bundleIdentifier, at: 10, in: statement)
        try bindChecked(event.windowTitle, at: 11, in: statement)
        try bindChecked(sanitizedDescriptor, at: 12, in: statement)
    }

    private func lastError() -> String {
        connection.db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindChecked(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bindChecked(_ value: Int64?, at index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_int64(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func int64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bindChecked(_ value: Double?, at index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func double(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func decodeInputEvent(_ statement: OpaquePointer) -> InputEvent {
        InputEvent(
            id: sqlite3_column_int64(statement, 0),
            capturedAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
            kind: InputEventKind(rawValue: text(statement, 2) ?? "") ?? .click,
            x: double(statement, 3),
            y: double(statement, 4),
            text: text(statement, 5),
            key: text(statement, 6),
            modifiers: text(statement, 7).map { $0.split(separator: ",").map(String.init) } ?? [],
            appName: text(statement, 8) ?? "Unknown",
            bundleIdentifier: text(statement, 9),
            windowTitle: text(statement, 10),
            targetDescriptor: text(statement, 11)
        )
    }

    private func decodeTimelineEpisode(_ statement: OpaquePointer) -> TimelineEpisode {
        TimelineEpisode(
            id: sqlite3_column_int64(statement, 0),
            startAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
            endAt: DateCodec.date(from: text(statement, 2)) ?? Date(),
            bundleIdentifier: text(statement, 3),
            appName: text(statement, 4) ?? "Unknown",
            windowTitleHint: text(statement, 5),
            contextCount: Int(sqlite3_column_int(statement, 6)),
            representativeContextID: sqlite3_column_int64(statement, 7),
            summaryText: text(statement, 8)
        )
    }

    private func decodePreferenceEvent(_ statement: OpaquePointer) -> PreferenceEvent {
        PreferenceEvent(
            id: sqlite3_column_int64(statement, 0),
            createdAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
            kind: PreferenceEventKind(rawValue: text(statement, 2) ?? "") ?? .agentProposed,
            reward: sqlite3_column_double(statement, 3),
            surface: text(statement, 4),
            appName: text(statement, 5),
            workflowSignature: text(statement, 6),
            agentID: int64(statement, 7),
            featureJSON: text(statement, 8) ?? "{}",
            evidenceJSON: text(statement, 9)
        )
    }

    private func decodeRoutineProfile(_ statement: OpaquePointer) -> RoutineProfile {
        let rawSignature = text(statement, 5) ?? ""
        return RoutineProfile(
            id: sqlite3_column_int64(statement, 0),
            appName: text(statement, 1) ?? "unknown",
            surface: text(statement, 2) ?? "unknown",
            weekday: Int(sqlite3_column_int(statement, 3)),
            hourBucket: Int(sqlite3_column_int(statement, 4)),
            workflowSignature: rawSignature.isEmpty ? nil : rawSignature,
            shown: Int(sqlite3_column_int(statement, 6)),
            accepted: Int(sqlite3_column_int(statement, 7)),
            dismissedSnoozed: Int(sqlite3_column_int(statement, 8)),
            completed: Int(sqlite3_column_int(statement, 9)),
            scheduled: Int(sqlite3_column_int(statement, 10)),
            disabledDeleted: Int(sqlite3_column_int(statement, 11)),
            lastSeenAt: DateCodec.date(from: text(statement, 12)) ?? Date(),
            metadataJSON: text(statement, 13) ?? "{}"
        )
    }

    private static let agentColumns =
        "SELECT id, name, source, signature, recipe_json, apps, estimated_seconds, evidence_count, created_at, last_run_at, enabled, seconds_per_run, run_count, schedule, goal, evidence_ids_json, demo_sketches_json"

    private func decodeAgent(_ statement: OpaquePointer) -> CascadeAgent {
        let appsRaw = text(statement, 5) ?? ""
        let apps = appsRaw.isEmpty ? [] : appsRaw.components(separatedBy: "\u{1F}")
        return CascadeAgent(
            id: sqlite3_column_int64(statement, 0),
            name: text(statement, 1) ?? "Agent",
            source: AgentSource(rawValue: text(statement, 2) ?? "") ?? .detected,
            signature: text(statement, 3) ?? "",
            recipe: Self.decodeRecipe(text(statement, 4)),
            apps: apps,
            estimatedSeconds: Int(sqlite3_column_int64(statement, 6)),
            estimatedSecondsPerRun: Int(sqlite3_column_int64(statement, 11)),
            evidenceCount: Int(sqlite3_column_int64(statement, 7)),
            evidenceIDs: Self.decodeAgentEvidenceIDs(text(statement, 15)),
            runCount: Int(sqlite3_column_int64(statement, 12)),
            createdAt: DateCodec.date(from: text(statement, 8)) ?? Date(),
            lastRunAt: DateCodec.date(from: text(statement, 9)),
            enabled: sqlite3_column_int(statement, 10) != 0,
            schedule: text(statement, 13),
            goal: text(statement, 14),
            demoSketches: Self.decodeAgentDemoSketches(text(statement, 16))
        )
    }

    private static func encodeRecipe(_ recipe: AgentRecipe) -> String {
        guard let data = try? JSONEncoder().encode(recipe),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"steps\":[]}"
        }
        return json
    }

    private static func decodeRecipe(_ json: String?) -> AgentRecipe {
        guard let json, let data = json.data(using: .utf8),
              let recipe = try? JSONDecoder().decode(AgentRecipe.self, from: data) else {
            return AgentRecipe(steps: [])
        }
        return recipe
    }

    private static func encodeAgentEvidenceIDs(_ ids: [Int64]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeAgentEvidenceIDs(_ json: String?) -> [Int64] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else {
            return []
        }
        return ids
    }

    private static func encodeAgentDemoSketches(_ sketches: [AgentDemoSketch]) -> String {
        guard let data = try? JSONEncoder().encode(sketches),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeAgentDemoSketches(_ json: String?) -> [AgentDemoSketch] {
        guard let json, let data = json.data(using: .utf8),
              let sketches = try? JSONDecoder().decode([AgentDemoSketch].self, from: data) else {
            return []
        }
        return sketches
    }

    /// Decodes a `recorded_context` row in the `contextColumns(...)` order.
    private func decodeContext(_ statement: OpaquePointer) -> RecordedContext {
        RecordedContext(
            id: sqlite3_column_int64(statement, 0),
            capturedAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
            source: ContextSource(rawValue: text(statement, 2) ?? "") ?? .system,
            appName: text(statement, 3) ?? "Unknown",
            bundleIdentifier: text(statement, 4),
            windowTitle: text(statement, 5),
            ocrText: text(statement, 6),
            imagePath: text(statement, 7),
            metadataJSON: text(statement, 8),
            frameHash: int64(statement, 9),
            sourceTrust: text(statement, 10),
            rawTrustLabel: text(statement, 11),
            injectionScore: Int(int64(statement, 12) ?? 0),
            injectionReasonsJSON: text(statement, 13),
            userConfirmed: (int64(statement, 14) ?? 0) != 0,
            safeToShow: (int64(statement, 15) ?? 1) != 0,
            safeToSummarize: (int64(statement, 16) ?? 1) != 0,
            safeForControl: (int64(statement, 17).map { $0 != 0 })
        )
    }

    /// Question words that carry no recall signal — dropped before building the
    /// OR query in `ftsAnyQuery(from:)`.
    private static let questionStopwords: Set<String> = [
        "the", "and", "was", "were", "what", "when", "where", "which", "who", "whom",
        "why", "how", "did", "does", "doing", "done", "have", "has", "had", "you",
        "your", "yours", "about", "with", "from", "that", "this", "these", "those",
        "for", "are", "show", "tell", "give", "find", "get", "see", "look", "today",
        "yesterday", "earlier", "morning", "afternoon", "evening", "tonight", "day",
        "week", "time", "thing", "things", "summary", "summarize", "recap"
    ]

    /// Turns a natural-language question into an FTS5 MATCH expression that ORs
    /// its meaningful tokens (quoted, prefix-matched), so a question like "when
    /// was the assignment due?" still recalls moments mentioning "assignment".
    /// Returns `""` when nothing meaningful remains.
    private static func ftsAnyQuery(from question: String) -> String {
        let tokens = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !questionStopwords.contains($0) }
        guard !tokens.isEmpty else { return "" }
        return Array(Set(tokens)).sorted().map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    /// Turns free-form user input into a safe FTS5 MATCH expression: each
    /// alphanumeric token is double-quoted (so punctuation can't trigger
    /// `fts5: syntax error`) and AND-ed together with a trailing `*` for prefix
    /// matching. Returns `""` when the query has no usable tokens.
    private static func ftsQuery(from query: String) -> String {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static func fileSize(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func ensureParentDirectory(for path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let db: OpaquePointer?

    init(_ db: OpaquePointer?) {
        self.db = db
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }
}

private enum DateCodec {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return formatter().date(from: string)
    }
}
