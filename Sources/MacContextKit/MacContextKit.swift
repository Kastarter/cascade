import AppKit
import ApplicationServices
import CascadeMemory
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

public struct CapturePermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(screenRecording: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public var canRecordContext: Bool {
        screenRecording
    }

    public var canRunScreenAgent: Bool {
        screenRecording && accessibility && inputMonitoring
    }

    public var missingLabels: [String] {
        var labels: [String] = []
        if !screenRecording { labels.append("Screen Recording") }
        if !accessibility { labels.append("Accessibility") }
        if !inputMonitoring { labels.append("Input Monitoring") }
        return labels
    }
}

public enum PermissionPromptKind: Sendable {
    case accessibility
    case inputMonitoring
}

public struct PermissionDiagnostics: Equatable, Sendable {
    public var bundleIdentifier: String
    public var bundlePath: String
    public var executablePath: String
    public var screenRecording: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        screenRecording: Bool,
        accessibility: Bool,
        inputMonitoring: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

@MainActor
public enum PermissionProbe {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "permissions")

    public static func currentStatus() -> CapturePermissionStatus {
        let status = CapturePermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
        logger.info(
            "Permission preflight bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public) screen=\(status.screenRecording, privacy: .public) ax=\(status.accessibility, privacy: .public) input=\(status.inputMonitoring, privacy: .public)"
        )
        return status
    }

    public static func diagnostics() -> PermissionDiagnostics {
        let status = currentStatus()
        return PermissionDiagnostics(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path ?? "unknown",
            screenRecording: status.screenRecording,
            accessibility: status.accessibility,
            inputMonitoring: status.inputMonitoring
        )
    }

    public static func requestScreenRecordingPrompt() -> Bool {
        logger.info("Explicit Screen Recording request for \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
        return CGRequestScreenCaptureAccess()
    }

    public static func request(_ kind: PermissionPromptKind) {
        switch kind {
        case .accessibility:
            logger.info("Explicit Accessibility request for \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            logger.info("Explicit Input Monitoring request for \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
            _ = CGRequestListenEventAccess()
        }
    }
}

public struct AppWindowSnapshot: Equatable, Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t?
    public let windowTitle: String?

    public init(
        appName: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t?,
        windowTitle: String?
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
    }
}

@MainActor
public final class AppWindowObserver: ObservableObject {
    @Published public private(set) var latest: AppWindowSnapshot

    public init() {
        latest = Self.snapshot()
    }

    @discardableResult
    public func refresh() -> AppWindowSnapshot {
        let snapshot = Self.snapshot()
        latest = snapshot
        return snapshot
    }

    public static func snapshot() -> AppWindowSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let title = frontmostWindowTitle(for: app?.processIdentifier)
        return AppWindowSnapshot(
            appName: app?.localizedName ?? "Unknown app",
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            windowTitle: title
        )
    }

    private static func frontmostWindowTitle(for pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else {
            return nil
        }
        return frontmostWindowTitle(focusedWindowRef: focused)
    }

    static func frontmostWindowTitle(focusedWindowRef focused: CFTypeRef?) -> String? {
        guard let window = decodeAXElement(focused) else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}

public struct ContextRecorderStatus: Equatable, Sendable {
    public var running: Bool
    public var permissions: CapturePermissionStatus
    public var latestContext: RecordedContext?
    public var message: String
}

@MainActor
public final class ContextRecorder: ObservableObject {
    public struct Options: Equatable, Sendable {
        public var indexWorkGraph: Bool
        public var structuredContent: Bool

        public init(indexWorkGraph: Bool = false, structuredContent: Bool = false) {
            self.indexWorkGraph = indexWorkGraph
            self.structuredContent = structuredContent
        }
    }

    @Published public private(set) var status: ContextRecorderStatus

    private let store: CascadeStore
    private let observer: AppWindowObserver
    private let options: Options
    private var rewind: RewindRecorder?
    private let input: InputRecorder
    private var retentionTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var lastActivationCaptureAt = Date.distantPast

    public init(store: CascadeStore, observer: AppWindowObserver = AppWindowObserver(), options: Options = Options()) {
        self.store = store
        self.observer = observer
        self.options = options
        self.input = InputRecorder(store: store)
        let permissions = PermissionProbe.currentStatus()
        status = ContextRecorderStatus(
            running: false,
            permissions: permissions,
            latestContext: nil,
            message: permissions.canRecordContext ? "Ready to record local context." : "Screen Recording is required before context recording starts."
        )
    }

    nonisolated static func captureAuditDetail(appName: String, axChars: Int? = nil, ocrChars: Int? = nil) -> String {
        var parts = [AuditIdentity.descriptor("app", appName)]
        if let axChars { parts.append("axChars=\(axChars)") }
        if let ocrChars { parts.append("ocrChars=\(ocrChars)") }
        return parts.joined(separator: " ")
    }

    public func refreshPermissions() {
        let permissions = PermissionProbe.currentStatus()
        status.permissions = permissions
        if !permissions.canRecordContext {
            stopEngine()
            status.running = false
            status.message = "Screen Recording is required before context recording starts."
        }
    }

    /// Starts continuous, always-on recording: an SCStream (~1fps) that dedupes,
    /// OCRs, and stores only changed frames, plus a background retention prune.
    /// `interval` is ignored (kept for source compatibility with the old timer API).
    public func start(interval: TimeInterval = 1.0) {
        refreshPermissions()
        guard status.permissions.canRecordContext else {
            status.message = "Open Settings to grant Screen Recording before recording."
            return
        }
        guard rewind == nil else { return }
        status.running = true
        status.message = "Recording local context."

        let recorder = RewindRecorder(
            store: store,
            indexWorkGraph: options.indexWorkGraph,
            structuredContent: options.structuredContent
        ) { [weak self] context in
            Task { @MainActor in
                guard let self else { return }
                self.status.latestContext = context
                if self.status.running { self.status.message = "Recording local context." }
            }
        }
        rewind = recorder
        Task { @MainActor in
            do {
                try await recorder.start()
            } catch {
                self.status.message = "Could not start recording: \(error.localizedDescription)"
                self.stopEngine()
                self.status.running = false
            }
        }
        // Best-effort: records real clicks/keys for workflow learning. Self-gates
        // (fail-closed) on Input Monitoring + Accessibility, independent of screen
        // recording.
        input.start()
        startRetention()
        startActivationCapture()
    }

    /// Event-driven capture: the moment the user switches apps is exactly the
    /// moment worth recording — don't wait up to a second for the stream clock.
    /// Also the hook that lets the rewind stream follow the cursor across
    /// monitors. Debounced so ⌘-tabbing through five apps costs one capture.
    private func startActivationCapture() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAppActivated() }
        }
    }

    private func handleAppActivated() {
        guard status.running else { return }
        Task { await rewind?.followCursorDisplay() }
        guard Date().timeIntervalSince(lastActivationCaptureAt) > 1.5 else { return }
        lastActivationCaptureAt = Date()
        captureOnce()
    }

    public func pause() {
        stopEngine()
        status.running = false
        status.message = "Recording paused."
    }

    private func stopEngine() {
        retentionTask?.cancel()
        retentionTask = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        input.stop()
        guard let recorder = rewind else { return }
        rewind = nil
        Task { @MainActor in await recorder.stop() }
    }

    /// Background loop enforcing local retention (7 days / ≤5GB by default): prune
    /// the DB and delete the frame files it reports, on launch and then hourly.
    private func startRetention() {
        retentionTask?.cancel()
        let store = self.store
        retentionTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                if let removed = try? await store.prune() {
                    for path in removed { FrameStore.delete(path) }
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    public func captureOnce() {
        Task { _ = await captureNow() }
    }

    /// Awaitable single capture — used by the autonomous agent loop so it can
    /// observe the current screen (and its OCR) before planning the next step.
    @discardableResult
    public func captureNow() async -> RecordedContext? {
        let snapshot = observer.refresh()
        // Same privacy boundary as the continuous recorder — the one-shot path
        // must not store what the rewind would refuse. Pre-OCR gate on app/window…
        guard !PrivacyRules.isSensitive(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle
        ) else {
            status.message = "Skipped a sensitive moment."
            return nil
        }
        let canCaptureScreen = status.permissions.canRecordContext
        var ocrText: String?
        var imagePath: String?
        var capturedImageData: Data?
        var source: ContextSource = .app
        var isCursorScreen = false
        if canCaptureScreen,
           let sample = await ScreenCaptureUtility.captureCursorScreenContext(includeImage: true) {
            source = .screen
            isCursorScreen = sample.isCursorScreen
            if sample.hasText { ocrText = sample.ocrText }
            if let png = sample.imagePNG {
                capturedImageData = png
                imagePath = Self.saveFrame(png)
            }
        }
        let structuredMetadata: StructuredContentExporter.Metadata? = if options.structuredContent, let capturedImageData {
            StructuredContentExporter.metadata(from: ScreenContentStructurer.structure(
                ScreenTextRecognizer.recognizeBoxes(inImageData: capturedImageData),
                topLeftOrigin: false
            ))
        } else {
            nil
        }
        // Same exact-text channel as the continuous recorder: AX text leads,
        // OCR fills in what the tree can't see.
        if let pid = snapshot.processIdentifier {
            let axText = await Task.detached { AXTextHarvester.text(forWindowOfPID: pid) }.value
            let merged = AXTextHarvester.merge(ax: axText, ocr: ocrText ?? "")
            if !merged.isEmpty { ocrText = merged }
        }

        let metadata = RecorderMetadataJSON.capture(
            processIdentifier: snapshot.processIdentifier,
            cursorScreen: isCursorScreen,
            structured: structuredMetadata
        )
        let context = RecordedContext(
            source: source,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            ocrText: ocrText,
            imagePath: imagePath,
            metadataJSON: metadata
        )
        // …and the full gate once OCR text exists: a sensitive frame is deleted,
        // never stored.
        if PrivacyRules.isSensitive(context) {
            if let imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
            status.message = "Skipped a sensitive moment."
            return nil
        }
        do {
            let inserted = try await store.insert(context, indexWorkGraph: options.indexWorkGraph)
            let detail = Self.captureAuditDetail(appName: inserted.appName, ocrChars: ocrText?.count)
            _ = try await store.appendAudit(AuditEvent(actor: "system", action: "context.capture", detail: detail))
            status.latestContext = inserted
            status.message = status.running ? "Recording local context." : "Captured one context sample."
            return inserted
        } catch {
            status.message = "Could not write context: \(error.localizedDescription)"
            return nil
        }
    }

    /// Persists a captured frame (from the single-shot path, which produces PNG
    /// bytes) so the Rewind can show the real screenshot per moment. Re-encodes to
    /// JPEG via `FrameStore` to match the continuous recorder's on-disk format and
    /// cut disk use. Returns the file path, or nil on failure.
    private nonisolated static func saveFrame(_ png: Data) -> String? {
        FrameStore.save(imageData: png)
    }
}
