import AppKit
import CascadeMemory
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Continuous, always-on screen recorder. Replaces the old 4s Timer with an
// SCStream at ~1fps, gated and deduped so only *changed* frames become moments:
//
//   SCStream → RewindStreamOutput (off-main, serial queue): convert + perceptual
//   hash + dedup + JPEG-encode → RewindEngine (actor, serializes OCR): privacy
//   gate + save + OCR + privacy re-gate + store.insert → publish on the main actor.
//
// Non-Sendable Core Media / Core Image / Core Graphics values never leave the
// delegate — only Sendable `ChangedFrame` (JPEG `Data`, `UInt64` hash, size) is
// handed to the engine. See the Rewind Capture handoff for the full design.

/// A changed frame ready for OCR + storage. All fields are Sendable so it can
/// cross from the stream delegate to the `RewindEngine` actor.
struct CapturedDisplayMetadata: Sendable, Equatable, Codable {
    let id: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(id: CGDirectDisplayID, bounds: CGRect) {
        self.id = id
        self.x = Double(bounds.minX)
        self.y = Double(bounds.minY)
        self.width = Double(bounds.width)
        self.height = Double(bounds.height)
    }
}

enum FrameOCRMode: String, Sendable, Equatable, Codable {
    case fullFrame = "full_frame"
    case changedRegion = "changed_region"
    case sparseAXFullFrame = "sparse_ax_full_frame"
    case auditFullFrame = "audit_full_frame"
}

struct ChangedFrame: Sendable {
    /// HEIC-encoded (JPEG fallback) — see `FrameStore.encodeFrame`.
    let imageData: Data
    let signature: FrameSignature
    let width: Int
    let height: Int
    let display: CapturedDisplayMetadata?
    let changedRegions: [CGRect]
    let ocrMode: FrameOCRMode
    let ocrRegion: CGRect?
    let ocrPixelsRequested: Int
}

enum RecorderMetadataJSON {
    private struct RegionPayload: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            self.x = Double(rect.minX)
            self.y = Double(rect.minY)
            self.width = Double(rect.width)
            self.height = Double(rect.height)
        }
    }

    private struct SignaturePayload: Encodable {
        let dHash: String
        let combinedGridHash: String
        let blockHash: String
        let changedCellsMask: UInt16
        let textDigest: String?

        init(_ signature: FrameSignature) {
            self.dHash = String(signature.dHash)
            self.combinedGridHash = String(signature.combinedGridHash)
            self.blockHash = String(signature.blockHash)
            self.changedCellsMask = signature.changedCellsMask
            self.textDigest = signature.textDigest.map(String.init)
        }
    }

    private struct RewindPayload: Encodable {
        let rewind: Bool
        let w: Int
        let h: Int
        let ax: Int
        let captureReason: String?
        let display: CapturedDisplayMetadata?
        let signature: SignaturePayload?
        let ocrMode: String?
        let ocrRegion: RegionPayload?
        let ocrPixelsRequested: Int?
        let changedRegions: [RegionPayload]?
        let structured: StructuredContentExporter.Metadata?
        let privacy: FrameRedactor.Metadata?

        private enum CodingKeys: String, CodingKey {
            case rewind, w, h, ax, captureReason, display, signature, structured, privacy
            case ocrMode = "ocr_mode"
            case ocrRegion = "ocr_region"
            case ocrPixelsRequested = "ocr_pixels_requested"
            case changedRegions = "changed_regions"
        }
    }

    private struct CapturePayload: Encodable {
        let processIdentifier: Int32?
        let cursorScreen: Bool
        let w: Int?
        let h: Int?
        let captureReason: String?
        let display: CapturedDisplayMetadata?
        let structured: StructuredContentExporter.Metadata?
        let privacy: FrameRedactor.Metadata?
    }

    static func rewind(
        width: Int,
        height: Int,
        axCount: Int,
        reason: CaptureReason? = nil,
        display: CapturedDisplayMetadata? = nil,
        signature: FrameSignature? = nil,
        ocrMode: FrameOCRMode? = nil,
        ocrRegion: CGRect? = nil,
        ocrPixelsRequested: Int? = nil,
        changedRegions: [CGRect] = [],
        structured: StructuredContentExporter.Metadata?,
        privacy: FrameRedactor.Metadata? = nil
    ) -> String {
        if reason == nil, display == nil, signature == nil, ocrMode == nil, ocrRegion == nil, ocrPixelsRequested == nil, changedRegions.isEmpty, structured == nil, privacy == nil {
            return "{\"rewind\":true,\"w\":\(width),\"h\":\(height),\"ax\":\(axCount)}"
        }
        let signaturePayload = signature.map(SignaturePayload.init)
        return encode(RewindPayload(
            rewind: true,
            w: width,
            h: height,
            ax: axCount,
            captureReason: reason?.rawValue,
            display: display,
            signature: signaturePayload,
            ocrMode: ocrMode?.rawValue,
            ocrRegion: ocrRegion.map(RegionPayload.init),
            ocrPixelsRequested: ocrPixelsRequested,
            changedRegions: changedRegions.isEmpty ? nil : changedRegions.map(RegionPayload.init),
            structured: structured,
            privacy: privacy
        ))
    }

    static func capture(
        processIdentifier: Int32?,
        cursorScreen: Bool,
        width: Int? = nil,
        height: Int? = nil,
        reason: CaptureReason? = nil,
        display: CapturedDisplayMetadata? = nil,
        structured: StructuredContentExporter.Metadata?,
        privacy: FrameRedactor.Metadata? = nil
    ) -> String {
        guard structured != nil || privacy != nil else {
            return encode(CapturePayload(
                processIdentifier: processIdentifier,
                cursorScreen: cursorScreen,
                w: width,
                h: height,
                captureReason: reason?.rawValue,
                display: display,
                structured: nil,
                privacy: nil
            ))
        }
        return encode(CapturePayload(
            processIdentifier: processIdentifier,
            cursorScreen: cursorScreen,
            w: width,
            h: height,
            captureReason: reason?.rawValue,
            display: display,
            structured: structured,
            privacy: privacy
        ))
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Where captured frames are written on disk. Single source of truth for the
/// frames directory so the recorder, the manual single-shot path, and retention
/// pruning all agree. Frames are JPEG (q≈0.6) to keep disk ~3–5× smaller than PNG.
public enum FrameStore {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "frames")

    public static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Cascade/frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Encodes a captured frame for persistence: HEIC (hardware-accelerated on
    /// Apple silicon, ~2-3x smaller than JPEG for screen content at the same
    /// legibility), with a JPEG fallback so recording never stops if the HEVC
    /// encoder is unavailable. OCR and NSImage read either through CGImageSource.
    static func encodeFrame(_ image: CGImage, quality: CGFloat = 0.55) -> Data? {
        let data = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality as String: quality
            ] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length > 0 {
                return data as Data
            }
        }
        return NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    /// Persists an encoded frame, picking the extension from the container's
    /// magic bytes (JPEG starts FF D8; anything else here is HEIC) so mixed
    /// archives stay honest. Redacted frames come back as JPEG even when the
    /// capture was HEIC, so both flow through this path.
    public static func save(frame data: Data) -> String? {
        let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
        guard let dir = directory() else { return nil }
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            logger.error("Frame write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Persists pre-encoded JPEG bytes. Returns the file path, or nil on failure.
    public static func save(jpeg: Data) -> String? {
        save(frame: jpeg)
    }

    /// Re-encodes arbitrary image data (e.g. a PNG from the single-shot path) to
    /// JPEG and persists it.
    public static func save(imageData: Data, compression: CGFloat = 0.6) -> String? {
        autoreleasepool {
            guard let rep = NSBitmapImageRep(data: imageData),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
                return nil
            }
            return save(jpeg: jpeg)
        }
    }

    public static func delete(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// SCStream output + delegate. Runs entirely off the main actor on a serial queue;
/// `@unchecked Sendable` is sound because the only mutable state (`lastHash`) is
/// touched solely on that serial `sampleHandlerQueue`.
final class RewindStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let engine: RewindEngine
    private let threshold: Int
    private let onStop: @Sendable (Error?) -> Void
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastGrid: [UInt64]?
    private var scheduler = CaptureScheduler()
    private var display: CapturedDisplayMetadata?
    private var frameOrdinal = 0

    init(
        engine: RewindEngine,
        threshold: Int,
        heartbeatGap: TimeInterval,
        onStop: @escaping @Sendable (Error?) -> Void
    ) {
        self.engine = engine
        self.threshold = threshold
        self.onStop = onStop
        scheduler.streamHeartbeatGap = heartbeatGap
    }

    func setDisplay(id: CGDirectDisplayID, bounds: CGRect) {
        display = CapturedDisplayMetadata(id: id, bounds: bounds)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let result = autoreleasepool(invoking: { () -> (ChangedFrame, Bool)? in
            guard type == .screen, sampleBuffer.isValid else { return nil }
            // Skip idle/blank/suspended frames — SCStream still delivers these, but
            // they carry no new content and reading the status flag is cheaper than
            // hashing them.
            guard isComplete(sampleBuffer) else { return nil }
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return nil }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

            // Change-aware dedup: per-region hashes, so a small but real change (a
            // new message in an otherwise static window) defeats the skip instead
            // of being averaged away by a whole-frame hash.
            let previousGrid = lastGrid
            let grid = PerceptualHash.gridHashes(cgImage)
            let changedCellsMask = PerceptualHash.changedCellsMask(current: grid, previous: previousGrid, threshold: threshold)
            let changedRegions = previousGrid.map {
                PerceptualHash.diffRegions(
                    current: grid,
                    previous: $0,
                    threshold: threshold,
                    imageSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                )
            } ?? []
            let visuallyChanged = previousGrid.map { !PerceptualHash.isDuplicateGrid(grid, of: $0, threshold: threshold) } ?? true
            lastGrid = grid
            frameOrdinal += 1
            let signature = FrameSignature(
                dHash: PerceptualHash.dHash(cgImage),
                combinedGridHash: PerceptualHash.combinedHash(grid),
                gridDHash: grid,
                blockHash: PerceptualHash.blockMeanHash(cgImage),
                changedCellsMask: changedCellsMask
            )

            guard let imageData = FrameStore.encodeFrame(cgImage) else {
                return nil
            }
            let ocrPlan = Self.ocrPlan(
                previousGrid: previousGrid,
                changedCellsMask: changedCellsMask,
                width: cgImage.width,
                height: cgImage.height,
                frameOrdinal: frameOrdinal
            )
            let frame = ChangedFrame(
                imageData: imageData,
                signature: signature,
                width: cgImage.width,
                height: cgImage.height,
                display: display,
                changedRegions: changedRegions,
                ocrMode: ocrPlan.mode,
                ocrRegion: ocrPlan.region,
                ocrPixelsRequested: ocrPlan.pixelsRequested
            )
            let shouldHeartbeat = visuallyChanged && scheduler.admits(reason: .streamHeartbeat)
            return (frame, shouldHeartbeat)
        }) else { return }
        let (frame, shouldHeartbeat) = result
        let engine = self.engine
        Task {
            await engine.updateLatest(frame)
            if shouldHeartbeat {
                await engine.captureLatest(reason: .streamHeartbeat)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first,
            let statusRaw = attachment[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw) else {
            // No status attachment — assume usable and let the hash dedupe decide.
            return true
        }
        return status == .complete
    }

    private static func ocrPlan(
        previousGrid: [UInt64]?,
        changedCellsMask: UInt16,
        width: Int,
        height: Int,
        frameOrdinal: Int
    ) -> (mode: FrameOCRMode, region: CGRect?, pixelsRequested: Int) {
        let fullPixels = max(1, width * height)
        guard previousGrid != nil else {
            return (.fullFrame, nil, fullPixels)
        }
        if frameOrdinal % 60 == 0 {
            return (.auditFullFrame, nil, fullPixels)
        }
        let changedCells = changedCellsMask.nonzeroBitCount
        guard changedCells > 0, changedCells <= 3,
              let region = PerceptualHash.normalizedChangedRegion(changedCellsMask: changedCellsMask) else {
            return (.fullFrame, nil, fullPixels)
        }
        let roiPixels = Int((CGFloat(fullPixels) * region.width * region.height).rounded(.up))
        return (.changedRegion, region, max(1, roiPixels))
    }
}

enum OCRLineBuilder {
    static func visionLines(contextID: Int64, boxes: [ScreenTextRecognizer.TextBox], source: String) -> [OCRLine] {
        ScreenContentStructurer.structure(boxes, topLeftOrigin: false).lines.enumerated().map { index, line in
            let confidence: Double? = if line.boxes.isEmpty {
                nil
            } else {
                Double(line.boxes.reduce(Float(0)) { $0 + $1.confidence } / Float(line.boxes.count))
            }
            return OCRLine(
                contextID: contextID,
                lineIndex: index,
                source: source,
                text: line.text,
                x: Double(line.rect.minX),
                y: Double(line.rect.minY),
                width: Double(line.rect.width),
                height: Double(line.rect.height),
                confidence: confidence
            )
        }
    }

    static func axLines(contextID: Int64, text: String, startingAt startIndex: Int = 0) -> [OCRLine] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, line in
                OCRLine(contextID: contextID, lineIndex: startIndex + index, source: "ax", text: line)
            }
    }
}

actor RecorderMaintenanceScheduler {
    private static let catchUpLimit = 24

    private let store: CascadeStore
    private let maintenanceInterval: Duration
    private let maintenanceTolerance: Duration
    private let now: @Sendable () -> Date
    private var budget: RecorderCadenceBudget = .normal
    private var pendingSemanticIndex: [Int64: String] = [:]
    private var task: Task<Void, Never>?

    init(
        store: CascadeStore,
        maintenanceInterval: Duration = .seconds(3600),
        maintenanceTolerance: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.maintenanceInterval = maintenanceInterval
        self.maintenanceTolerance = maintenanceTolerance
        self.now = now
    }

    func start() {
        guard task == nil else { return }
        let interval = maintenanceInterval
        let tolerance = maintenanceTolerance
        task = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                if let self {
                    await self.runScheduledPass()
                } else {
                    return
                }
                try? await Task.sleep(
                    for: interval,
                    tolerance: tolerance
                )
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func updateBudget(_ budget: RecorderCadenceBudget) {
        self.budget = budget
    }

    func isRunning() -> Bool {
        task != nil
    }

    func enqueueSemanticIndexing(contextID: Int64, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSemanticIndex[contextID] = trimmed
    }

    /// The recorder starts this immediately and repeats it hourly. A graph must
    /// commit before a frame older than 24 hours is removed; prune is skipped if
    /// compaction cannot fully catch up so source rows remain available to retry.
    func runOnce(reason: CascadeStoreMaintenanceReason = .idle, now: Date = Date()) async {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        if let result = try? await store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff),
           result.isCaughtUp,
           result.deletionFailures == 0,
           let removed = try? await store.prune(protectingContextsCapturedOnOrAfter: cutoff) {
            for path in removed { FrameStore.delete(path) }
        }
        try? await store.performMaintenance(reason: reason)
        await flushSemanticIndexing()
    }

    private func runScheduledPass() async {
        await runOnce(reason: .idle, now: now())
    }

    func flushSemanticIndexing() async {
        guard budget.allowsSemanticIndexing else { return }
        var work = pendingSemanticIndex
        pendingSemanticIndex.removeAll()
        if let catchUp = try? await store.unindexedRecentContexts(limit: Self.catchUpLimit) {
            for context in catchUp {
                if let text = context.ocrText, !text.isEmpty {
                    work[context.id] = text
                }
            }
        }
        guard !work.isEmpty else { return }
        let store = self.store
        await Task.detached(priority: .utility) {
            for (contextID, text) in work {
                try? await store.indexEmbedding(contextID: contextID, text: text)
            }
        }.value
    }
}

struct ContextWriteBufferItem: Sendable {
    let context: RecordedContext
    let structuredPayload: StructuredContentExporter.SidecarPayload?
    let visionBoxes: [ScreenTextRecognizer.TextBox]
    let axText: String
    let nativeVisionBoxes: [ScreenTextRecognizer.TextBox]
    let signature: FrameSignature
    let semanticText: String?
    let auditDetail: String
}

actor ContextWriteBuffer {
    private let store: CascadeStore
    private let indexWorkGraph: Bool
    private let maintenanceScheduler: RecorderMaintenanceScheduler?
    private let onMoment: @Sendable (RecordedContext) -> Void
    private let flushThreshold: Int
    private let flushIntervalNanoseconds: UInt64
    private let logger = Logger(subsystem: "com.humain.cascade", category: "rewind")
    private var pending: [ContextWriteBufferItem] = []
    private var flushTask: Task<Void, Never>?
    private var flushing = false

    init(
        store: CascadeStore,
        indexWorkGraph: Bool,
        maintenanceScheduler: RecorderMaintenanceScheduler?,
        flushThreshold: Int = 4,
        flushInterval: TimeInterval = 1.0,
        onMoment: @escaping @Sendable (RecordedContext) -> Void
    ) {
        self.store = store
        self.indexWorkGraph = indexWorkGraph
        self.maintenanceScheduler = maintenanceScheduler
        self.flushThreshold = max(1, flushThreshold)
        self.flushIntervalNanoseconds = UInt64(max(0.01, flushInterval) * 1_000_000_000)
        self.onMoment = onMoment
    }

    func enqueue(_ item: ContextWriteBufferItem) async {
        pending.append(item)
        if pending.count >= flushThreshold {
            await flushPending(cancelScheduled: true)
        } else {
            scheduleFlush()
        }
    }

    func flush() async {
        await flushPending(cancelScheduled: true)
    }

    private func scheduleFlush() {
        guard flushTask == nil, !flushing else { return }
        let interval = flushIntervalNanoseconds
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            await self?.flushFromTimer()
        }
    }

    private func flushFromTimer() async {
        flushTask = nil
        await flushPending(cancelScheduled: false)
    }

    private func flushPending(cancelScheduled: Bool) async {
        if cancelScheduled {
            flushTask?.cancel()
            flushTask = nil
        }
        guard !flushing else { return }
        flushing = true
        defer {
            flushing = false
            if !pending.isEmpty {
                scheduleFlush()
            }
        }

        while !pending.isEmpty {
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            await write(batch)
        }
    }

    private func write(_ batch: [ContextWriteBufferItem]) async {
        do {
            let insertedRows = try await store.insertContexts(batch.map(\.context), indexWorkGraph: indexWorkGraph)
            for (item, inserted) in zip(batch, insertedRows) {
                await writeSideEffects(for: inserted, item: item)
            }
        } catch {
            for item in batch {
                if let imagePath = item.context.imagePath {
                    FrameStore.delete(imagePath)
                }
            }
            logger.error("Rewind buffered insert failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeSideEffects(for inserted: RecordedContext, item: ContextWriteBufferItem) async {
        if let payload = item.structuredPayload {
            try? await store.insertOCRStructure(
                contextID: inserted.id,
                version: payload.version,
                json: payload.json,
                searchableText: payload.searchableText
            )
        }
        var lines = OCRLineBuilder.visionLines(contextID: inserted.id, boxes: item.visionBoxes, source: "vision")
        lines += OCRLineBuilder.axLines(contextID: inserted.id, text: item.axText, startingAt: lines.count)
        if !item.nativeVisionBoxes.isEmpty {
            lines += OCRLineBuilder.visionLines(contextID: inserted.id, boxes: item.nativeVisionBoxes, source: "vision_native_crop")
        }
        try? await store.insertOCRLines(lines)
        try? await store.insertFrameSignature(StoredFrameSignature(
            contextID: inserted.id,
            dHash: Int64(bitPattern: item.signature.dHash),
            combinedGridHash: Int64(bitPattern: item.signature.combinedGridHash),
            gridHashes: item.signature.gridDHash.map { Int64(bitPattern: $0) },
            blockHash: Int64(bitPattern: item.signature.blockHash),
            changedCellsMask: item.signature.changedCellsMask,
            textDigest: item.signature.textDigest.map { Int64(bitPattern: $0) }
        ))
        if let semanticText = item.semanticText {
            await maintenanceScheduler?.enqueueSemanticIndexing(contextID: inserted.id, text: semanticText)
        }
        _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "rewind.capture", detail: item.auditDetail))
        onMoment(inserted)
    }
}

/// Serializes the expensive work (OCR + storage) per changed frame. Actor
/// isolation *is* the serialization; `ingest` coalesces to the latest pending
/// frame so a slow OCR pass can't pile up a backlog.
actor RewindEngine {
    private struct PendingFrame: Sendable {
        let frame: ChangedFrame
        let reason: CaptureReason
    }

    private let store: CascadeStore
    private let indexWorkGraph: Bool
    private let structuredContent: Bool
    private let maintenanceScheduler: RecorderMaintenanceScheduler?
    private let writeBuffer: ContextWriteBuffer
    private var policy: CapturePrivacyPolicy
    private var budget: RecorderCadenceBudget = .normal
    private let onMoment: @Sendable (RecordedContext) -> Void
    private var latest: ChangedFrame?
    private var pending: PendingFrame?
    private var processing = false
    private var lastStoredBucket: String?
    private var lastStoredSignature: FrameSignature?
    private var skipThreshold = PerceptualHash.defaultSkipThreshold
    private var lastNativeOCRAt = Date.distantPast
    private let logger = Logger(subsystem: "com.humain.cascade", category: "rewind")

    /// When the AX channel gave us less text than this, the window is probably
    /// a canvas/web surface and OCR is carrying the frame — worth paying for a
    /// native-resolution pass so small text isn't lost to the 1920px cap.
    static let sparseAXThreshold = 200
    /// Native-resolution OCR is an extra SCScreenshotManager capture; rate-limit
    /// it so a busy canvas app doesn't double the capture cost every second.
    static let nativeOCRInterval: TimeInterval = 3.0

    init(
        store: CascadeStore,
        indexWorkGraph: Bool = true,
        structuredContent: Bool = false,
        maintenanceScheduler: RecorderMaintenanceScheduler? = nil,
        policy: CapturePrivacyPolicy = .default,
        onMoment: @escaping @Sendable (RecordedContext) -> Void
    ) {
        self.store = store
        self.indexWorkGraph = indexWorkGraph
        self.structuredContent = structuredContent
        self.maintenanceScheduler = maintenanceScheduler
        self.policy = policy
        self.onMoment = onMoment
        self.writeBuffer = ContextWriteBuffer(
            store: store,
            indexWorkGraph: indexWorkGraph,
            maintenanceScheduler: maintenanceScheduler,
            onMoment: onMoment
        )
    }

    func updatePolicy(_ policy: CapturePrivacyPolicy) {
        self.policy = policy
    }

    func updateBudget(_ budget: RecorderCadenceBudget) {
        self.budget = budget
    }

    /// Teach-once demo burst: the stream-side gate tightens its dedup threshold,
    /// and the store-side duplicate check here must match — otherwise the
    /// transient states the burst exists to keep get re-dropped at persistence.
    func updateSkipThreshold(_ threshold: Int) {
        skipThreshold = threshold
    }

    func flushWrites() async {
        await writeBuffer.flush()
    }

    func updateLatest(_ frame: ChangedFrame) {
        if processing,
           let pending,
           pending.frame.imageData.count + frame.imageData.count > budget.pendingFrameByteBudget {
            latest = nil
            return
        }
        latest = frame
    }

    /// Stores the newest stream frame for an admitted scheduler reason. Keeps only
    /// the newest pending request while OCR is in flight, so backlog remains bounded.
    func captureLatest(reason: CaptureReason) async {
        guard budget.admitsCapture else { return }
        guard let frame = latest else { return }
        guard frame.imageData.count <= budget.pendingFrameByteBudget else {
            latest = nil
            return
        }
        pending = PendingFrame(frame: frame, reason: reason)
        latest = nil
        guard !processing else { return }
        processing = true
        while let next = pending {
            pending = nil
            await process(next.frame, reason: next.reason)
        }
        processing = false
    }

    private func process(_ frame: ChangedFrame, reason: CaptureReason) async {
        let snapshot = await MainActor.run { AppWindowObserver.snapshot() }

        // Never record Cascade itself — when our own UI is frontmost the captured
        // frame is just our (excluded) window over a black backdrop, which would
        // otherwise pile up as junk "Cascade" moments in the reel.
        if snapshot.bundleIdentifier == Bundle.main.bundleIdentifier
            || snapshot.appName.caseInsensitiveCompare("Cascade") == .orderedSame {
            return
        }

        // Cheap pre-OCR privacy gate on app/bundle/window — drop sensitive surfaces
        // before paying for OCR or writing a frame to disk.
        if !policy.decision(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle
        ).allowed {
            return
        }

        // The exact-text channel: the focused window's accessibility tree.
        // Character-perfect for native apps, immune to the resolution cap.
        // (Thread-safe C API; this actor serializes the walks.)
        let axText = snapshot.processIdentifier.map { AXTextHarvester.text(forWindowOfPID: $0) } ?? ""
        let axControls = structuredContent
            ? (snapshot.processIdentifier.map { AXTextHarvester.controls(forWindowOfPID: $0) } ?? [])
            : []

        // OCR carries the frame only where AX can't. When AX already owns the
        // window's text (native apps), a full `.accurate` pass every second is
        // wasted CPU — the merge keeps only OCR lines AX didn't already cover,
        // usually icon/menu labels. So run a cheap `.fast` insurance pass there
        // (still catches text living only in images/canvas), and reserve the
        // `.accurate` pass + native-res rescue for sparse-AX (web/canvas)
        // windows where OCR is the load-bearing channel.
        let axRich = axText.count >= Self.sparseAXThreshold

        var ocrMode = frame.ocrMode
        var ocrRegion = frame.ocrRegion
        if !axRich {
            ocrMode = .sparseAXFullFrame
            ocrRegion = nil
        }
        let ocrPixelsRequested = ocrRegion == nil
            ? max(1, frame.width * frame.height)
            : frame.ocrPixelsRequested
        let recognitionLevel: VNRequestTextRecognitionLevel = budget.ocrPolicy == .fastOnly ? .fast : (axRich ? .fast : .accurate)
        let maxDecodeDimension = recognitionLevel == .fast && axRich ? 1280 : nil
        let ocrBoxes = ScreenTextRecognizer.recognizeBoxes(
            inImageData: frame.imageData,
            level: recognitionLevel,
            regionOfInterest: ocrRegion,
            maxDecodeDimension: maxDecodeDimension
        )
        var redactedOCRBoxes = ocrBoxes
        let structured = ScreenContentStructurer.structure(ocrBoxes, topLeftOrigin: false)
        var ocrText = structured.readingOrderText
        var nativeOCRLines: [ScreenTextRecognizer.TextBox] = []

        // Canvas/web window with little AX text → OCR is the only channel, so
        // do one native-resolution pass (rate-limited) for the focused window
        // instead of trusting the 1920px-capped stream frame with small text.
        if !axRich,
           budget.allowsNativeResolutionOCR,
           Date().timeIntervalSince(lastNativeOCRAt) >= Self.nativeOCRInterval,
           let pid = snapshot.processIdentifier,
           let windowRect = await MainActor.run(body: { ScreenCaptureUtility.focusedWindowNormalizedRect(pid: pid) }),
           let nativeCrop = await ScreenCaptureUtility.captureCursorScreenZoomJPEG(
	               normalizedRect: windowRect, maxDimension: 2400
	           ) {
            lastNativeOCRAt = Date()
            let nativeBoxes = ScreenTextRecognizer.recognizeBoxes(inImageData: nativeCrop, level: .accurate)
            let nativeText = ScreenContentStructurer.structure(nativeBoxes, topLeftOrigin: false).readingOrderText
            if nativeText.count > ocrText.count {
                ocrText = nativeText
                nativeOCRLines = nativeBoxes
            }
        }

        let rawMergedText = AXTextHarvester.merge(ax: axText, ocr: ocrText)
        if FrameRedactor.wholeFrameDropReason(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            rawText: rawMergedText,
            policy: policy
        ) != nil {
            return
        }
        guard let redacted = FrameRedactor.redact(imageData: frame.imageData, boxes: ocrBoxes, policy: policy) else { return }
        redactedOCRBoxes = redacted.boxes
        ocrText = ScreenContentStructurer.structure(redactedOCRBoxes, topLeftOrigin: false).readingOrderText
        let redactedAXText = FrameRedactor.redactedText(axText, policy: policy)
        let redactedAXControls = axControls.map {
            ScreenContentStructurer.AXControl(
                id: $0.id,
                kind: $0.kind,
                label: $0.label.map { FrameRedactor.redactedText($0, policy: policy) },
                value: $0.value.map { FrameRedactor.redactedText($0, policy: policy) },
                rect: $0.rect,
                confidence: $0.confidence
            )
        }
        nativeOCRLines = nativeOCRLines.map {
            ScreenTextRecognizer.TextBox(
                text: FrameRedactor.redactedText($0.text, policy: policy),
                boundingBox: $0.boundingBox,
                confidence: $0.confidence
            )
        }
        let structuredRedacted = ScreenContentStructurer.structure(
            redactedOCRBoxes,
            topLeftOrigin: false,
            axControls: redactedAXControls
        )
        let structuredMetadata: StructuredContentExporter.Metadata? = if structuredContent {
            StructuredContentExporter.metadata(from: structuredRedacted)
        } else {
            nil
        }
        let mergedText = AXTextHarvester.merge(ax: redactedAXText, ocr: ocrText)
        var signature = frame.signature
        signature.textDigest = Self.textDigest(mergedText)
        let bucket = Self.bucket(for: snapshot)
        if isDuplicate(bucket: bucket, signature: signature) {
            return
        }
        guard let imagePath = FrameStore.save(frame: redacted.imageData) else { return }

        let context = RecordedContext(
            source: .screen,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            ocrText: mergedText.isEmpty ? nil : mergedText,
            imagePath: imagePath,
            metadataJSON: RecorderMetadataJSON.rewind(
                width: frame.width,
                height: frame.height,
                axCount: axText.count,
                reason: reason,
                display: frame.display,
                signature: signature,
                ocrMode: ocrMode,
                ocrRegion: ocrRegion,
                ocrPixelsRequested: ocrPixelsRequested,
                changedRegions: frame.changedRegions,
                structured: structuredMetadata,
                privacy: redacted.metadata
            ),
            frameHash: Int64(bitPattern: signature.combinedGridHash)
        )

        if !policy.decision(
            appName: context.appName,
            bundleIdentifier: context.bundleIdentifier,
            windowTitle: context.windowTitle,
            text: context.ocrText
        ).allowed {
            FrameStore.delete(imagePath)
            return
        }

        await writeBuffer.enqueue(ContextWriteBufferItem(
            context: context,
            structuredPayload: structuredContent ? StructuredContentExporter.sidecarPayload(from: structuredRedacted) : nil,
            visionBoxes: redactedOCRBoxes,
            axText: redactedAXText,
            nativeVisionBoxes: nativeOCRLines,
            signature: signature,
            semanticText: mergedText.isEmpty ? nil : mergedText,
            auditDetail: ContextRecorder.captureAuditDetail(
                appName: context.appName,
                axChars: axText.count,
                ocrChars: ocrText.count
            )
        ))
        lastStoredBucket = bucket
        lastStoredSignature = signature
    }

    private func isDuplicate(bucket: String, signature: FrameSignature) -> Bool {
        guard let lastBucket = lastStoredBucket,
              let last = lastStoredSignature,
              lastBucket == bucket,
              last.textDigest == signature.textDigest else {
            return false
        }
        let combinedDistance = PerceptualHash.hamming(signature.combinedGridHash, last.combinedGridHash)
        let blockDistance = PerceptualHash.hamming(signature.blockHash, last.blockHash)
        return combinedDistance <= skipThreshold
            && blockDistance <= skipThreshold
    }

    private static func bucket(for snapshot: AppWindowSnapshot) -> String {
        [
            snapshot.bundleIdentifier ?? snapshot.appName,
            snapshot.windowTitle ?? "",
        ].joined(separator: "\u{1F}")
    }

    static func textDigest(_ text: String) -> UInt64 {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

/// Owns the SCStream lifecycle (start/stop/restart). Pinned to the main actor
/// because `SCStream`/`SCContentFilter` are not Sendable and the capture-setup
/// helpers are main-actor isolated; the actual per-frame work happens off-main in
/// the stream delegate and the `RewindEngine` actor. Fail-closed: never builds a
/// stream unless Screen Recording is already granted.
@MainActor
final class RewindRecorder {
    private let engine: RewindEngine
    private let threshold: Int
    private let fps: Int32
    private let sampleQueue = DispatchQueue(label: "com.humain.cascade.rewind.frames")
    private var stream: SCStream?
    private var output: RewindStreamOutput?
    private var streamedDisplayID: CGDirectDisplayID?
    private var stopping = false
    private let logger = Logger(subsystem: "com.humain.cascade", category: "rewind")

    init(
        store: CascadeStore,
        threshold: Int = PerceptualHash.defaultSkipThreshold,
        fps: Int32 = 1,
        indexWorkGraph: Bool = true,
        structuredContent: Bool = false,
        maintenanceScheduler: RecorderMaintenanceScheduler? = nil,
        policy: CapturePrivacyPolicy = .default,
        onMoment: @escaping @Sendable (RecordedContext) -> Void
    ) {
        self.engine = RewindEngine(
            store: store,
            indexWorkGraph: indexWorkGraph,
            structuredContent: structuredContent,
            maintenanceScheduler: maintenanceScheduler,
            policy: policy,
            onMoment: onMoment
        )
        self.threshold = threshold
        self.fps = fps
    }

    /// Whether a capture stream is currently live.
    var isRunning: Bool { stream != nil }

    /// Teach-once demo burst: while the user demonstrates a task, the stream runs
    /// denser (2fps, 0.5s persistence gap) with a tighter dedup threshold so
    /// transient demo states — a menu open for half a second, a dialog — become
    /// moments instead of falling between 1s heartbeats.
    private(set) var demoBurst = false

    /// The capture parameters for the current mode. Pure so tests can pin the
    /// burst contract without a live stream.
    nonisolated static func demoBurstParameters(
        baseFPS: Int32,
        baseThreshold: Int,
        burst: Bool
    ) -> (fps: Int32, threshold: Int, heartbeatGap: TimeInterval) {
        guard burst else { return (baseFPS, baseThreshold, CaptureScheduler.streamHeartbeatInterval) }
        return (max(baseFPS, 2), min(baseThreshold, 2), 0.5)
    }

    /// Flip the demonstration cadence. When a stream is live it restarts at the
    /// new rate (the SCStream's frame interval is fixed at creation); when not,
    /// the flag alone is enough — the next `start()` picks it up.
    func setDemoBurst(_ on: Bool) async {
        guard demoBurst != on else { return }
        demoBurst = on
        await restartLiveStream(reason: on ? "demo burst on" : "demo burst off")
    }

    /// Tear down the live stream and bring it back with the current configuration —
    /// the one restart shared by display-follow and demo-burst toggles. A concurrent
    /// `stop()`/pause landing while the old stream goes down WINS: the restart
    /// stands down instead of resurrecting recording the user just stopped. A
    /// transiently failed start (display briefly unavailable mid-swap) gets one
    /// retry so a healthy stream is never traded for a dead one on a hiccup.
    private func restartLiveStream(reason: String) async {
        guard stream != nil, !stopping else { return }
        let liveStream = stream
        stream = nil
        output = nil
        streamedDisplayID = nil
        if let liveStream { try? await liveStream.stopCapture() }
        guard !stopping else { return }
        logger.info("Restarting rewind stream (\(reason, privacy: .public)).")
        try? await start()
        if stream == nil, !stopping {
            try? await Task.sleep(for: .milliseconds(500))
            guard !stopping else { return }
            try? await start()
        }
    }

    func updatePolicy(_ policy: CapturePrivacyPolicy) {
        Task { await engine.updatePolicy(policy) }
    }

    func updateBudget(_ budget: RecorderCadenceBudget) {
        Task { await engine.updateBudget(budget) }
    }

    func start() async throws {
        guard stream == nil else { return }
        stopping = false
        let mode = Self.demoBurstParameters(baseFPS: fps, baseThreshold: threshold, burst: demoBurst)
        // The store-side duplicate gate must match the stream-side one, or burst
        // frames that clear the tighter stream threshold get re-dropped at persist.
        await engine.updateSkipThreshold(mode.threshold)
        let output = RewindStreamOutput(
            engine: engine,
            threshold: mode.threshold,
            heartbeatGap: mode.heartbeatGap
        ) { [weak self] error in
            guard let self else { return }
            Task { await self.handleStreamStopped(error) }
        }
        guard let made = try await ScreenCaptureUtility.makeRewindStream(
            output: output,
            sampleHandlerQueue: sampleQueue,
            fps: mode.fps
        ) else {
            return // Fail-closed (no permission / no display) — nothing started.
        }
        output.setDisplay(id: made.displayID, bounds: made.displayBounds)
        // A pause could have arrived while we awaited stream creation.
        guard !stopping else {
            try? await made.stream.stopCapture()
            return
        }
        try await made.stream.startCapture()
        // A stop() can land while startCapture is in flight (it sees stream == nil
        // and returns) — honor it instead of leaving an orphaned live stream.
        guard !stopping else {
            try? await made.stream.stopCapture()
            return
        }
        self.stream = made.stream
        self.output = output
        self.streamedDisplayID = made.displayID
        logger.info("Rewind stream started on display \(made.displayID).")
    }

    func capture(reason: CaptureReason) async {
        await engine.captureLatest(reason: reason)
    }

    func stop() async {
        stopping = true
        if let stream {
            self.stream = nil
            self.output = nil
            self.streamedDisplayID = nil
            try? await stream.stopCapture()
            logger.info("Rewind stream stopped.")
        }
        await engine.flushWrites()
    }

    /// Follow the user across monitors: when the cursor lives on a different
    /// display than the one being streamed, restart the stream there. Called on
    /// app-activation events — cheap when nothing changed.
    func followCursorDisplay() async {
        guard stream != nil, !stopping else { return }
        guard let current = await ScreenCaptureUtility.currentCursorDisplayID(),
              let streamed = streamedDisplayID, current != streamed else { return }
        logger.info("Cursor moved to display \(current).")
        await restartLiveStream(reason: "display change")
    }

    private func handleStreamStopped(_ error: Error?) async {
        logger.error("Rewind stream stopped unexpectedly: \(error?.localizedDescription ?? "no error", privacy: .public)")
        guard !stopping, stream != nil else { return }
        // The OS tore the stream down (e.g. display sleep/wake). Drop our handle and
        // attempt a single restart; if permission is gone, start() fails closed.
        self.stream = nil
        self.output = nil
        try? await start()
    }
}
