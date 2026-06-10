import AppKit
import CascadeMemory
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

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
struct ChangedFrame: Sendable {
    let jpeg: Data
    let hash: UInt64
    let width: Int
    let height: Int
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

    /// Persists pre-encoded JPEG bytes. Returns the file path, or nil on failure.
    public static func save(jpeg: Data) -> String? {
        guard let dir = directory() else { return nil }
        let url = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            return url.path
        } catch {
            logger.error("Frame write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Re-encodes arbitrary image data (e.g. a PNG from the single-shot path) to
    /// JPEG and persists it.
    public static func save(imageData: Data, compression: CGFloat = 0.6) -> String? {
        guard let rep = NSBitmapImageRep(data: imageData),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            return nil
        }
        return save(jpeg: jpeg)
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

    init(engine: RewindEngine, threshold: Int, onStop: @escaping @Sendable (Error?) -> Void) {
        self.engine = engine
        self.threshold = threshold
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Skip idle/blank/suspended frames — SCStream still delivers these, but
        // they carry no new content and reading the status flag is cheaper than
        // hashing them.
        guard isComplete(sampleBuffer) else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        // Change-aware dedup: per-region hashes, so a small but real change (a
        // new message in an otherwise static window) defeats the skip instead
        // of being averaged away by a whole-frame hash.
        let grid = PerceptualHash.gridHashes(cgImage)
        if let last = lastGrid, PerceptualHash.isDuplicateGrid(grid, of: last) {
            return // Every region near-identical to the last stored frame — drop.
        }
        lastGrid = grid
        let hash = PerceptualHash.dHash(cgImage)

        guard let jpeg = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return
        }
        let frame = ChangedFrame(jpeg: jpeg, hash: hash, width: cgImage.width, height: cgImage.height)
        let engine = self.engine
        Task { await engine.ingest(frame) }
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
}

/// Serializes the expensive work (OCR + storage) per changed frame. Actor
/// isolation *is* the serialization; `ingest` coalesces to the latest pending
/// frame so a slow OCR pass can't pile up a backlog.
actor RewindEngine {
    private let store: CascadeStore
    private let onMoment: @Sendable (RecordedContext) -> Void
    private var pending: ChangedFrame?
    private var processing = false
    private var lastNativeOCRAt = Date.distantPast
    private let logger = Logger(subsystem: "com.humain.cascade", category: "rewind")

    /// When the AX channel gave us less text than this, the window is probably
    /// a canvas/web surface and OCR is carrying the frame — worth paying for a
    /// native-resolution pass so small text isn't lost to the 1920px cap.
    static let sparseAXThreshold = 200
    /// Native-resolution OCR is an extra SCScreenshotManager capture; rate-limit
    /// it so a busy canvas app doesn't double the capture cost every second.
    static let nativeOCRInterval: TimeInterval = 3.0

    init(store: CascadeStore, onMoment: @escaping @Sendable (RecordedContext) -> Void) {
        self.store = store
        self.onMoment = onMoment
    }

    /// Accepts a changed frame. Keeps only the newest one while a frame is being
    /// processed (coalesce-latest), so OCR backlog is bounded to one in-flight + one
    /// pending frame.
    func ingest(_ frame: ChangedFrame) async {
        pending = frame
        guard !processing else { return }
        processing = true
        while let next = pending {
            pending = nil
            await process(next)
        }
        processing = false
    }

    private func process(_ frame: ChangedFrame) async {
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
        if PrivacyRules.isSensitive(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle
        ) {
            return
        }

        guard let imagePath = FrameStore.save(jpeg: frame.jpeg) else { return }

        // The exact-text channel: the focused window's accessibility tree.
        // Character-perfect for native apps, immune to the resolution cap.
        // (Thread-safe C API; this actor serializes the walks.)
        let axText = snapshot.processIdentifier.map { AXTextHarvester.text(forWindowOfPID: $0) } ?? ""

        // `recognize(inPNG:)` decodes via ImageIO, which handles JPEG bytes too.
        var ocrText = await ScreenTextRecognizer.recognize(inPNG: frame.jpeg)

        // Canvas/web window with little AX text → OCR is the only channel, so
        // do one native-resolution pass (rate-limited) for the focused window
        // instead of trusting the 1920px-capped stream frame with small text.
        if axText.count < Self.sparseAXThreshold,
           Date().timeIntervalSince(lastNativeOCRAt) >= Self.nativeOCRInterval,
           let pid = snapshot.processIdentifier,
           let windowRect = await MainActor.run(body: { ScreenCaptureUtility.focusedWindowNormalizedRect(pid: pid) }),
           let nativeCrop = await ScreenCaptureUtility.captureCursorScreenZoomJPEG(
               normalizedRect: windowRect, maxDimension: 2400
           ) {
            lastNativeOCRAt = Date()
            let nativeText = await ScreenTextRecognizer.recognize(inPNG: nativeCrop)
            if nativeText.count > ocrText.count { ocrText = nativeText }
        }

        let mergedText = AXTextHarvester.merge(ax: axText, ocr: ocrText)

        let context = RecordedContext(
            source: .screen,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            ocrText: mergedText.isEmpty ? nil : mergedText,
            imagePath: imagePath,
            metadataJSON: "{\"rewind\":true,\"w\":\(frame.width),\"h\":\(frame.height),\"ax\":\(axText.count)}",
            frameHash: Int64(bitPattern: frame.hash)
        )

        // Re-check with OCR text now available — if anything sensitive surfaced in
        // the captured text, drop the frame entirely (delete the file, don't store).
        if PrivacyRules.isSensitive(context) {
            FrameStore.delete(imagePath)
            return
        }

        do {
            let inserted = try await store.insert(context)
            // Semantic recall: index the moment's text locally (best-effort).
            if !mergedText.isEmpty {
                try? await store.indexEmbedding(contextID: inserted.id, text: mergedText)
            }
            _ = try? await store.appendAudit(AuditEvent(
                actor: "system",
                action: "rewind.capture",
                detail: mergedText.isEmpty
                    ? inserted.appName
                    : "\(inserted.appName) · ax \(axText.count) + ocr \(ocrText.count) chars"
            ))
            onMoment(inserted)
        } catch {
            FrameStore.delete(imagePath)
            logger.error("Rewind insert failed: \(error.localizedDescription, privacy: .public)")
        }
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
        onMoment: @escaping @Sendable (RecordedContext) -> Void
    ) {
        self.engine = RewindEngine(store: store, onMoment: onMoment)
        self.threshold = threshold
        self.fps = fps
    }

    /// Whether a capture stream is currently live.
    var isRunning: Bool { stream != nil }

    func start() async throws {
        guard stream == nil else { return }
        stopping = false
        let output = RewindStreamOutput(engine: engine, threshold: threshold) { [weak self] error in
            guard let self else { return }
            Task { await self.handleStreamStopped(error) }
        }
        guard let made = try await ScreenCaptureUtility.makeRewindStream(
            output: output,
            sampleHandlerQueue: sampleQueue,
            fps: fps
        ) else {
            return // Fail-closed (no permission / no display) — nothing started.
        }
        // A pause could have arrived while we awaited stream creation.
        guard !stopping else {
            try? await made.stream.stopCapture()
            return
        }
        try await made.stream.startCapture()
        self.stream = made.stream
        self.output = output
        self.streamedDisplayID = made.displayID
        logger.info("Rewind stream started on display \(made.displayID).")
    }

    func stop() async {
        stopping = true
        guard let stream else { return }
        self.stream = nil
        self.output = nil
        self.streamedDisplayID = nil
        try? await stream.stopCapture()
        logger.info("Rewind stream stopped.")
    }

    /// Follow the user across monitors: when the cursor lives on a different
    /// display than the one being streamed, restart the stream there. Called on
    /// app-activation events — cheap when nothing changed.
    func followCursorDisplay() async {
        guard stream != nil, !stopping else { return }
        guard let current = await ScreenCaptureUtility.currentCursorDisplayID(),
              let streamed = streamedDisplayID, current != streamed else { return }
        logger.info("Cursor moved to display \(current) — restarting rewind stream there.")
        let liveStream = stream
        stream = nil
        output = nil
        streamedDisplayID = nil
        if let liveStream { try? await liveStream.stopCapture() }
        stopping = false
        try? await start()
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
