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
        frameHash: Int64? = nil
    ) {
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
        isParameter: Bool = false
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
        runCount: Int = 0,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        enabled: Bool = true,
        schedule: String? = nil,
        goal: String? = nil
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
        self.runCount = runCount
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.enabled = enabled
        self.schedule = schedule
        self.goal = goal
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

internal enum CascadeBatchInsertTable: Sendable {
    case recordedContext
    case inputEvent
}

internal typealias CascadeBatchBindFailureInjector = @Sendable (CascadeBatchInsertTable, Int) throws -> Void

public actor CascadeStore {
    private let connection: SQLiteConnection
    private let path: String
    private let auditAnchor: AuditAnchorStore
    private var batchBindFailureInjector: CascadeBatchBindFailureInjector?

    public init(path: String? = nil, auditAnchor: AuditAnchorStore = NullAuditAnchor()) throws {
        self.path = path ?? Self.defaultDatabasePath()
        self.auditAnchor = auditAnchor
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
            (captured_at, captured_ms, source, app_name, bundle_identifier, window_title, ocr_text, image_path, metadata_json, frame_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        return try withTransaction {
            try withStatement(sql) { statement in
                var rows: [RecordedContext] = []
                rows.reserveCapacity(contexts.count)
                for (index, context) in contexts.enumerated() {
                    try bindContext(context, at: index, in: statement)
                    try stepDone(statement)
                    rows.append(RecordedContext(
                        id: sqlite3_last_insert_rowid(connection.db),
                        capturedAt: context.capturedAt,
                        source: context.source,
                        appName: context.appName,
                        bundleIdentifier: context.bundleIdentifier,
                        windowTitle: context.windowTitle,
                        ocrText: context.ocrText,
                        imagePath: context.imagePath,
                        metadataJSON: context.metadataJSON,
                        frameHash: context.frameHash
                    ))
                    if indexWorkGraph, let row = rows.last {
                        try linkWorkGraphEntities(for: row)
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
        return "\(p)id, \(p)captured_at, \(p)source, \(p)app_name, \(p)bundle_identifier, \(p)window_title, \(p)ocr_text, \(p)image_path, \(p)metadata_json, \(p)frame_hash"
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
               NULL, image_path, NULL, frame_hash
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
    public func hybridContexts(matching query: String, limit: Int = 12, candidatePool: Int = 40) throws -> [RecordedContext] {
        let keyword = try lexicalRankedIDs(matching: query, limit: candidatePool)
        let semantic = try semanticRankedIDs(matching: query, limit: candidatePool)
        // Both empty → no match; one empty → RRF degenerates to the other lane's
        // order (still correct, no special-casing). Fuse and hydrate the winners.
        let fused = RankFusion.reciprocalRankFusion([keyword, semantic], limit: limit)
        return try fused.compactMap { try context(id: $0) }
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
        try? execute("DELETE FROM context_visual_embedding WHERE context_id NOT IN (SELECT id FROM recorded_context);")
        return removed
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

    // MARK: - Agents

    /// Inserts a new agent, or updates the existing one with the same `signature`
    /// (so re-detecting a workflow refreshes it rather than duplicating). Returns
    /// the stored agent with its id.
    @discardableResult
    public func upsertAgent(_ agent: CascadeAgent) throws -> CascadeAgent {
        let recipeJSON = Self.encodeRecipe(agent.recipe)
        let appsCSV = agent.apps.joined(separator: "\u{1F}") // unit separator — app names may contain commas

        let existingID = try withStatement("SELECT id FROM agents WHERE signature = ? LIMIT 1;") { statement in
            bind(agent.signature, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
        }

        if let existingID {
            // run_count, last_run_at, schedule, and goal are never overwritten by a
            // re-detect — the run history, schedule, and curated goal belong to the
            // approved agent, not the detection.
            try withStatement("""
            UPDATE agents SET name = ?, source = ?, recipe_json = ?, apps = ?, estimated_seconds = ?, seconds_per_run = ?, evidence_count = ?
            WHERE id = ?;
            """) { statement in
                bind(agent.name, at: 1, in: statement)
                bind(agent.source.rawValue, at: 2, in: statement)
                bind(recipeJSON, at: 3, in: statement)
                bind(appsCSV, at: 4, in: statement)
                sqlite3_bind_int64(statement, 5, Int64(agent.estimatedSeconds))
                sqlite3_bind_int64(statement, 6, Int64(agent.estimatedSecondsPerRun))
                sqlite3_bind_int64(statement, 7, Int64(agent.evidenceCount))
                sqlite3_bind_int64(statement, 8, existingID)
                try stepDone(statement)
            }
            return try self.agent(id: existingID) ?? agent
        }

        try withStatement("""
        INSERT INTO agents
            (name, source, signature, recipe_json, apps, estimated_seconds, seconds_per_run, evidence_count, run_count, created_at, last_run_at, enabled, schedule, goal)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bind(agent.name, at: 1, in: statement)
            bind(agent.source.rawValue, at: 2, in: statement)
            bind(agent.signature, at: 3, in: statement)
            bind(recipeJSON, at: 4, in: statement)
            bind(appsCSV, at: 5, in: statement)
            sqlite3_bind_int64(statement, 6, Int64(agent.estimatedSeconds))
            sqlite3_bind_int64(statement, 7, Int64(agent.estimatedSecondsPerRun))
            sqlite3_bind_int64(statement, 8, Int64(agent.evidenceCount))
            sqlite3_bind_int64(statement, 9, Int64(agent.runCount))
            bind(DateCodec.string(from: agent.createdAt), at: 10, in: statement)
            bind(agent.lastRunAt.map(DateCodec.string(from:)), at: 11, in: statement)
            sqlite3_bind_int(statement, 12, agent.enabled ? 1 : 0)
            bind(agent.schedule, at: 13, in: statement)
            bind(agent.goal, at: 14, in: statement)
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

    public func appendAudit(_ event: AuditEvent) throws -> AuditEvent {
        let createdAt = DateCodec.string(from: event.createdAt)
        // Strip high-confidence secrets/PII from the detail before it touches the
        // log: an audit trail must prove who/what/when without becoming a place
        // emails, cards, SSNs, or API keys come to rest (OWASP logging guidance).
        let detail = PIIDetector.redact(event.detail).redacted
        // Link this row to the chain head so any later mutation/deletion is evident.
        let prev = (try latestAuditHash()) ?? AuditChain.genesis
        let canonical = AuditChain.canonicalForm(
            createdAt: createdAt, actor: event.actor, action: event.action, detail: detail
        )
        let eventHash = AuditChain.hash(prev: prev, canonical: canonical)
        let sql = "INSERT INTO audit_event (created_at, actor, action, detail, prev_hash, event_hash) VALUES (?, ?, ?, ?, ?, ?);"
        try withStatement(sql) { statement in
            bind(createdAt, at: 1, in: statement)
            bind(event.actor, at: 2, in: statement)
            bind(event.action, at: 3, in: statement)
            bind(detail, at: 4, in: statement)
            bind(prev, at: 5, in: statement)
            bind(eventHash, at: 6, in: statement)
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

    /// Recompute the audit hash chain and report the first row that no longer
    /// reconciles. Scans ALL rows (not just chained ones) so a forged un-chained
    /// row inserted after the chain begins is caught; legacy pre-chain rows are
    /// allowed only as a leading prefix, and the first chained row must start at
    /// genesis. Detects field mutation (recompute mismatch) and insertion/deletion
    /// (broken `prev_hash` link). Finally compares the head to the out-of-band
    /// anchor to catch truncation / rewrites that keep the chain self-consistent.
    public func verifyAuditChain() throws -> AuditChainStatus {
        let sql = """
        SELECT id, created_at, actor, action, detail, prev_hash, event_hash
        FROM audit_event ORDER BY id ASC;
        """
        let scan: (status: AuditChainStatus?, verified: Int, head: String) = try withStatement(sql) { statement in
            var verified = 0
            var seenChained = false
            var expectedPrev = AuditChain.genesis
            var lastHash = ""
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                guard let storedHash = text(statement, 6) else {
                    // Unchained (legacy) row — allowed ONLY as a leading prefix.
                    if seenChained { return (.broken(atID: id), verified, lastHash) }
                    continue
                }
                let createdAt = text(statement, 1) ?? ""
                let actor = text(statement, 2) ?? ""
                let action = text(statement, 3) ?? ""
                let detail = text(statement, 4) ?? ""
                let prevHash = text(statement, 5) ?? ""
                if !seenChained {
                    if prevHash != AuditChain.genesis { return (.broken(atID: id), verified, lastHash) }
                    seenChained = true
                } else if prevHash != expectedPrev {
                    return (.broken(atID: id), verified, lastHash)
                }
                let canonical = AuditChain.canonicalForm(
                    createdAt: createdAt, actor: actor, action: action, detail: detail
                )
                if AuditChain.hash(prev: prevHash, canonical: canonical) != storedHash {
                    return (.broken(atID: id), verified, lastHash)
                }
                expectedPrev = storedHash
                lastHash = storedHash
                verified += 1
            }
            return (nil, verified, lastHash)
        }
        if let status = scan.status { return status }
        // Out-of-band anchor: catches truncation / rewrite the internal chain alone
        // can't (a shortened chain still links cleanly). Skipped when no anchor is
        // recorded (e.g. the no-op default), so internal-only integrity still works.
        if let head = auditAnchor.load(database: path),
           head.count != scan.verified || head.hash != scan.head {
            return .truncated(expectedCount: head.count, foundCount: scan.verified)
        }
        return scan.verified == 0 ? .empty : .intact(verified: scan.verified)
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
            metadata_json TEXT
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
            event_hash TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_audit_event_created_at
            ON audit_event(created_at DESC);
        """, db: db)

        // Best-effort migrations for databases created before these columns existed.
        try? execute("ALTER TABLE recorded_context ADD COLUMN image_path TEXT;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN frame_hash INTEGER;", db: db)
        try? execute("ALTER TABLE recorded_context ADD COLUMN captured_ms INTEGER;", db: db)
        try execute("""
        CREATE INDEX IF NOT EXISTS idx_recorded_context_captured_ms
            ON recorded_context(captured_ms ASC, id ASC);
        """, db: db)
        try? execute("ALTER TABLE agents ADD COLUMN seconds_per_run INTEGER NOT NULL DEFAULT 0;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN run_count INTEGER NOT NULL DEFAULT 0;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN schedule TEXT;", db: db)
        try? execute("ALTER TABLE agents ADD COLUMN goal TEXT;", db: db)
        try? execute("ALTER TABLE input_event ADD COLUMN target_descriptor TEXT;", db: db)
        try? execute("ALTER TABLE input_event ADD COLUMN captured_ms INTEGER;", db: db)
        // Tamper-evident audit chain columns for databases created before they existed.
        try? execute("ALTER TABLE audit_event ADD COLUMN prev_hash TEXT;", db: db)
        try? execute("ALTER TABLE audit_event ADD COLUMN event_hash TEXT;", db: db)

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
            run_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            last_run_at TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            schedule TEXT,
            goal TEXT
        );

        CREATE TABLE IF NOT EXISTS context_embedding (
            context_id INTEGER PRIMARY KEY,
            vector BLOB NOT NULL
        );

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
        """, db: db)

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
        """, db: db)

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
        CREATE INDEX IF NOT EXISTS idx_graph_entity_kind_seen
            ON graph_entity(kind, last_seen_at DESC);

        CREATE TABLE IF NOT EXISTS graph_entity_alias (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_id INTEGER NOT NULL,
            alias TEXT NOT NULL,
            normalized_alias TEXT NOT NULL,
            source TEXT NOT NULL,
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
            evidence_snippet TEXT NOT NULL,
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

        CREATE TABLE IF NOT EXISTS graph_edge (
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

        CREATE TRIGGER IF NOT EXISTS recorded_context_entity_link_ad
        AFTER DELETE ON recorded_context BEGIN
            DELETE FROM context_entity_link WHERE context_id = old.id;
        END;
        """, db: db)

        // Backfill the index for rows inserted before FTS existed (triggers only
        // fire on new writes). Counts match in steady state, so this rebuild runs
        // at most once after upgrading.
        if scalarValue(db, "SELECT count(*) FROM recorded_context;") != scalarValue(db, "SELECT count(*) FROM rewind_fts;") {
            try? execute("INSERT INTO rewind_fts(rewind_fts) VALUES('rebuild');", db: db)
        }
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
    }

    private func bindInputEvent(_ event: InputEvent, at rowIndex: Int, in statement: OpaquePointer) throws {
        try batchBindFailureInjector?(.inputEvent, rowIndex)
        try bindChecked(DateCodec.string(from: event.capturedAt), at: 1, in: statement)
        try bindChecked(EventStoreLayout.capturedMilliseconds(for: event.capturedAt), at: 2, in: statement)
        try bindChecked(event.kind.rawValue, at: 3, in: statement)
        try bindChecked(event.x, at: 4, in: statement)
        try bindChecked(event.y, at: 5, in: statement)
        try bindChecked(event.text, at: 6, in: statement)
        try bindChecked(event.key, at: 7, in: statement)
        try bindChecked(event.modifiers.isEmpty ? nil : event.modifiers.joined(separator: ","), at: 8, in: statement)
        try bindChecked(event.appName, at: 9, in: statement)
        try bindChecked(event.bundleIdentifier, at: 10, in: statement)
        try bindChecked(event.windowTitle, at: 11, in: statement)
        try bindChecked(event.targetDescriptor, at: 12, in: statement)
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

    private static let agentColumns =
        "SELECT id, name, source, signature, recipe_json, apps, estimated_seconds, evidence_count, created_at, last_run_at, enabled, seconds_per_run, run_count, schedule, goal"

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
            runCount: Int(sqlite3_column_int64(statement, 12)),
            createdAt: DateCodec.date(from: text(statement, 8)) ?? Date(),
            lastRunAt: DateCodec.date(from: text(statement, 9)),
            enabled: sqlite3_column_int(statement, 10) != 0,
            schedule: text(statement, 13),
            goal: text(statement, 14)
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
            frameHash: int64(statement, 9)
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
