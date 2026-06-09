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
    private var lastHash: UInt64?

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

        let hash = PerceptualHash.dHash(cgImage)
        if let last = lastHash, PerceptualHash.isDuplicate(hash, of: last, threshold: threshold) {
            return // Near-identical to the last stored frame — drop.
        }
        lastHash = hash

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
    private let logger = Logger(subsystem: "com.humain.cascade", category: "rewind")

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

        // `recognize(inPNG:)` decodes via ImageIO, which handles JPEG bytes too.
        let ocrText = await ScreenTextRecognizer.recognize(inPNG: frame.jpeg)

        let context = RecordedContext(
            source: .screen,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            ocrText: ocrText.isEmpty ? nil : ocrText,
            imagePath: imagePath,
            metadataJSON: "{\"rewind\":true,\"w\":\(frame.width),\"h\":\(frame.height)}",
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
            _ = try? await store.appendAudit(AuditEvent(
                actor: "system",
                action: "rewind.capture",
                detail: ocrText.isEmpty ? inserted.appName : "\(inserted.appName) · ocr \(ocrText.count) chars"
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
        guard let stream = try await ScreenCaptureUtility.makeRewindStream(
            output: output,
            sampleHandlerQueue: sampleQueue,
            fps: fps
        ) else {
            return // Fail-closed (no permission / no display) — nothing started.
        }
        // A pause could have arrived while we awaited stream creation.
        guard !stopping else {
            try? await stream.stopCapture()
            return
        }
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        logger.info("Rewind stream started.")
    }

    func stop() async {
        stopping = true
        guard let stream else { return }
        self.stream = nil
        self.output = nil
        try? await stream.stopCapture()
        logger.info("Rewind stream stopped.")
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
