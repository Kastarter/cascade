import CoreGraphics
import Foundation

public struct GroundingCorpusRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: Int64
    public let contextID: Int64
    public let capturedAt: Date
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitleHash: String?
    public let imagePath: String?
    public let point: CGPoint
    public let kind: InputEventKind
    public let descriptor: String?
    public let descriptorHash: String?
    public let labelHash: String?
    public let ocrAnchorHash: String?
    public let ocrTextHash: String?
    public let frameHash: Int64?
    public let sourceEvidence: [String]

    public init(
        schemaVersion: Int = 1,
        eventID: Int64,
        contextID: Int64,
        capturedAt: Date,
        appName: String,
        bundleIdentifier: String?,
        windowTitleHash: String?,
        imagePath: String?,
        point: CGPoint,
        kind: InputEventKind,
        descriptor: String?,
        descriptorHash: String?,
        labelHash: String?,
        ocrAnchorHash: String?,
        ocrTextHash: String?,
        frameHash: Int64?,
        sourceEvidence: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.contextID = contextID
        self.capturedAt = capturedAt
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitleHash = windowTitleHash
        self.imagePath = imagePath
        self.point = point
        self.kind = kind
        self.descriptor = descriptor
        self.descriptorHash = descriptorHash
        self.labelHash = labelHash
        self.ocrAnchorHash = ocrAnchorHash
        self.ocrTextHash = ocrTextHash
        self.frameHash = frameHash
        self.sourceEvidence = sourceEvidence
    }
}

public struct GroundingCorpusExporter: Sendable {
    public struct Options: Equatable, Sendable {
        public let includeImagePaths: Bool
        public let nearestContextWindow: TimeInterval

        public init(includeImagePaths: Bool = true, nearestContextWindow: TimeInterval = 3) {
            self.includeImagePaths = includeImagePaths
            self.nearestContextWindow = nearestContextWindow
        }
    }

    public init() {}

    public func records(
        clicks: [InputEvent],
        contexts: [RecordedContext],
        recipe: AgentRecipe? = nil,
        options: Options = Options()
    ) -> [GroundingCorpusRecord] {
        let safeContexts = contexts
            .filter { $0.safeToShow && !PrivacyRules.isSensitive($0) }
            .sorted { $0.capturedAt < $1.capturedAt }
        let recipeAnchors = recipeAnchorsByOrder(recipe)
        return clicks.enumerated().compactMap { offset, event in
            guard Self.isClick(event),
                  let x = event.x,
                  let y = event.y,
                  !PrivacyRules.isSensitive(
                      appName: event.appName,
                      bundleIdentifier: event.bundleIdentifier,
                      windowTitle: event.windowTitle
                  ) else { return nil }
            guard let context = Self.nearestContext(
                to: event.capturedAt,
                in: safeContexts,
                within: options.nearestContextWindow
            ) else { return nil }

            let sanitizedDescriptor = InputEventSanitizer.sanitize(descriptor: event.targetDescriptor)
            let sanitizedLabel = InputEventSanitizer.sanitize(text: event.text, kind: event.kind)
            let anchor = recipeAnchors[offset]
            let evidence = [
                sanitizedDescriptor == nil ? nil : "descriptor",
                sanitizedLabel == nil ? nil : "label_hash",
                anchor == nil ? nil : "ocr_anchor_hash",
                context.imagePath == nil ? nil : "image",
                context.ocrText == nil ? nil : "ocr_hash",
            ].compactMap { $0 }

            return GroundingCorpusRecord(
                eventID: event.id,
                contextID: context.id,
                capturedAt: event.capturedAt,
                appName: event.appName,
                bundleIdentifier: event.bundleIdentifier,
                windowTitleHash: Self.hash(event.windowTitle ?? context.windowTitle),
                imagePath: options.includeImagePaths ? context.imagePath : nil,
                point: CGPoint(x: x, y: y),
                kind: event.kind,
                descriptor: sanitizedDescriptor,
                descriptorHash: Self.hash(sanitizedDescriptor),
                labelHash: Self.hash(sanitizedLabel),
                ocrAnchorHash: Self.hash(anchor),
                ocrTextHash: Self.hash(context.ocrText),
                frameHash: context.frameHash,
                sourceEvidence: evidence
            )
        }
    }

    public func jsonl(
        clicks: [InputEvent],
        contexts: [RecordedContext],
        recipe: AgentRecipe? = nil,
        options: Options = Options()
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try records(clicks: clicks, contexts: contexts, recipe: recipe, options: options)
            .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }

    public static func nearestContext(
        to date: Date,
        in contexts: [RecordedContext],
        within window: TimeInterval
    ) -> RecordedContext? {
        contexts
            .filter { abs($0.capturedAt.timeIntervalSince(date)) <= window }
            .min {
                let left = abs($0.capturedAt.timeIntervalSince(date))
                let right = abs($1.capturedAt.timeIntervalSince(date))
                if left != right { return left < right }
                return $0.id < $1.id
            }
    }

    public static func hash(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func isClick(_ event: InputEvent) -> Bool {
        switch event.kind {
        case .click, .doubleClick, .rightClick:
            return true
        case .type, .key, .scroll:
            return false
        }
    }

    private func recipeAnchorsByOrder(_ recipe: AgentRecipe?) -> [Int: String] {
        guard let recipe else { return [:] }
        var anchors: [Int: String] = [:]
        for step in recipe.steps where step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
            if let anchor = step.ocrAnchor?.trimmingCharacters(in: .whitespacesAndNewlines), !anchor.isEmpty {
                anchors[step.order] = anchor
            }
        }
        return anchors
    }
}
