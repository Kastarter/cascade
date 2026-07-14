@preconcurrency import AVFoundation
import Combine
import Foundation
import ProviderKit

/// Thread-safe wrapper around the Realtime WebSocket. `@unchecked Sendable` because
/// `URLSessionWebSocketTask.send/receive` are safe to call from any thread, which lets
/// the audio-capture thread push frames directly.
final class RealtimeSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    var onText: (@Sendable (String) -> Void)?
    var onClose: (@Sendable () -> Void)?

    init(task: URLSessionWebSocketTask) { self.task = task }

    func start() { task.resume(); receiveLoop() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }

    func sendEvent(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { _ in }
    }

    func appendAudio(base64: String) {
        sendEvent(["type": "input_audio_buffer.append", "audio": base64])
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.onText?(text) }
                self.receiveLoop()
            case .failure:
                self.onClose?()
            }
        }
    }
}

protocol RealtimeVoiceEventSending: AnyObject, Sendable {
    func sendEvent(_ object: [String: Any])
    func appendAudio(base64: String)
}

extension RealtimeSocket: RealtimeVoiceEventSending {}

private final class ConverterInputState: @unchecked Sendable {
    var hasFedBuffer = false
}

final class RealtimeVoiceResponseState: @unchecked Sendable {
    private static let outputSampleRate = 24_000

    private(set) var responseInFlight = false
    private var assistantAudioItemID: String?
    private var assistantAudioPlayedSamples = 0
    private var assistantAudioActive = false

    var hasActiveResponse: Bool {
        responseInFlight || assistantAudioActive || assistantAudioItemID != nil
    }

    func speechResponseEvents(for trimmedText: String) -> [[String: Any]] {
        var events: [[String: Any]] = []
        if responseInFlight {
            events.append(["type": "response.cancel"])
            clearAssistantAudio()
        }
        responseInFlight = true
        events.append([
            "type": "response.create",
            "response": [
                "instructions": "You are a text-to-speech voice. Read the following text aloud exactly as written, naturally, and add NOTHING else: \(trimmedText)",
            ],
        ])
        return events
    }

    func noteOutputAudioDelta(event: [String: Any], pcmByteCount: Int) {
        if let itemID = event["item_id"] as? String, !itemID.isEmpty {
            if assistantAudioItemID != itemID {
                assistantAudioItemID = itemID
                assistantAudioPlayedSamples = 0
            }
        }
        assistantAudioActive = true
        responseInFlight = true
        assistantAudioPlayedSamples += pcmByteCount / MemoryLayout<Int16>.size
    }

    func bargeInEvents() -> [[String: Any]] {
        var events: [[String: Any]] = []
        if let itemID = assistantAudioItemID {
            events.append([
                "type": "conversation.item.truncate",
                "item_id": itemID,
                "content_index": 0,
                "audio_end_ms": audioEndMs,
            ])
        }
        events.append(["type": "response.cancel"])
        clear()
        return events
    }

    func clear() {
        responseInFlight = false
        clearAssistantAudio()
    }

    private var audioEndMs: Int {
        max(0, assistantAudioPlayedSamples * 1_000 / Self.outputSampleRate)
    }

    private func clearAssistantAudio() {
        assistantAudioItemID = nil
        assistantAudioPlayedSamples = 0
        assistantAudioActive = false
    }
}

final class RealtimeVoiceEndpointSession: @unchecked Sendable {
    enum Mode: Equatable {
        /// Continuous server-buffer upload: preserve every frame and commit once on release.
        case passthroughRelease
        /// D-13 PTT behavior: locally gate noise, then clear/wait/commit on release.
        case gatedRelease
        /// Teach ambient behavior: keep capture open and commit every VAD-delimited turn.
        case continuousGated
    }

    enum ReleaseResult: Equatable {
        case cleared
        case committed
        case tailWait(remainingMs: Int)
    }

    private enum UploadAction {
        case append(Data)
        case commit
    }

    private let mode: Mode
    private let sender: any RealtimeVoiceEventSending
    private let policy: VoiceTurnEndpointPolicy
    private let purpose: RealtimeVoice.CapturePurpose
    private let onCommit: @Sendable (RealtimeVoice.CapturePurpose) -> String
    private var gate: LocalVoiceActivityGate
    private var pendingSamples: [Int16] = []
    /// Whether gated audio reached the server this turn. Non-speech turns clear.
    private var hasUploadedAudio = false
    private var keyUpAtMs: Int?
    private var partialTranscript = ""
    private let lock = NSLock()
    /// Serializes server-buffer mutations with terminal capture close. The audio tap
    /// runs off-main while `endTalking` releases on the main actor; without this
    /// boundary, VAD could decide `[append, commit]`, reset its turn state, and then
    /// lose the race to a close that sent `clear` between those two events.
    private let deliveryLock = NSLock()
    private var closed = false
    // Counts-only capture forensics: enough to tell a dead mic (no frames) from
    // below-threshold audio (frames but no confirmed speech) from an endpoint that
    // never commits (speech but no commits). Read via diagnosticsSummary().
    private var ingestedFrameTotal = 0
    private var uploadedFrameTotal = 0
    private var speechConfirmTotal = 0
    private var commitTotal = 0

    init(
        mode: Mode,
        sender: any RealtimeVoiceEventSending,
        purpose: RealtimeVoice.CapturePurpose = .pushToTalk,
        onCommit: @escaping @Sendable (RealtimeVoice.CapturePurpose) -> String = { _ in
            "voice-commit-\(UUID().uuidString)"
        },
        gateConfiguration: LocalVoiceActivityGate.Configuration = LocalVoiceActivityGate.Configuration(),
        endpointPolicy: VoiceTurnEndpointPolicy = VoiceTurnEndpointPolicy()
    ) {
        self.mode = mode
        self.sender = sender
        self.purpose = purpose
        self.onCommit = onCommit
        self.policy = endpointPolicy
        self.gate = LocalVoiceActivityGate(configuration: gateConfiguration)
    }

    convenience init(
        localEndpointingEnabled: Bool,
        sender: any RealtimeVoiceEventSending,
        gateConfiguration: LocalVoiceActivityGate.Configuration = LocalVoiceActivityGate.Configuration(),
        endpointPolicy: VoiceTurnEndpointPolicy = VoiceTurnEndpointPolicy()
    ) {
        self.init(
            mode: localEndpointingEnabled ? .gatedRelease : .passthroughRelease,
            sender: sender,
            gateConfiguration: gateConfiguration,
            endpointPolicy: endpointPolicy
        )
    }

    func diagnosticsSummary() -> String {
        deliveryLock.lock()
        let commits = commitTotal
        deliveryLock.unlock()
        lock.lock()
        let frames = ingestedFrameTotal
        let uploaded = uploadedFrameTotal
        let confirms = speechConfirmTotal
        lock.unlock()
        return "frames=\(frames) uploadedFrames=\(uploaded) speechConfirms=\(confirms) commits=\(commits)"
    }

    func captureBufferFrameCount(inputSampleRate: Double) -> AVAudioFrameCount {
        let frames = inputSampleRate * Double(gate.configuration.frameDurationMs) / 1_000.0
        return AVAudioFrameCount(max(1, Int(frames.rounded())))
    }

    func updatePartialTranscript(_ partial: String) {
        lock.lock()
        partialTranscript = partial
        lock.unlock()
    }

    func ingestConvertedPCM16(_ data: Data) {
        let samples: [Int16]?
        if mode == .passthroughRelease {
            samples = nil
        } else {
            let converted = data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Int16.self))
            }
            guard !converted.isEmpty else { return }
            samples = converted
        }

        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !closed else { return }

        if mode == .passthroughRelease {
            lock.lock()
            ingestedFrameTotal += 1
            uploadedFrameTotal += 1
            lock.unlock()
            sender.appendAudio(base64: data.base64EncodedString())
            return
        }

        for action in gatedUploadActions(from: samples ?? []) {
            switch action {
            case .append(let audio):
                sender.appendAudio(base64: audio.base64EncodedString())
            case .commit:
                sendCommitLocked()
            }
        }
    }

    func release() -> ReleaseResult {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !closed else { return .cleared }

        guard mode != .passthroughRelease else {
            lock.lock()
            let hadAudio = ingestedFrameTotal > 0
            lock.unlock()
            closed = true
            if hadAudio {
                sendCommitLocked()
                return .committed
            }
            sendClearLocked()
            return .cleared
        }

        switch endpointDecisionOnRelease() {
        case .commitNow:
            lock.lock()
            let hadAudio = hasUploadedAudio
            lock.unlock()
            if hadAudio {
                closed = true
                sendCommitLocked()
                return .committed
            }
            closed = true
            sendClearLocked()
            return .cleared
        case .tailWait(let remainingMs):
            return .tailWait(remainingMs: remainingMs)
        case .clear, .appendOnly:
            closed = true
            sendClearLocked()
            return .cleared
        }
    }

    private func sendCommitLocked() {
        commitTotal += 1
        let eventID = onCommit(purpose)
        sender.sendEvent([
            "type": "input_audio_buffer.commit",
            "event_id": eventID,
        ])
    }

    func clear() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !closed else { return }
        closed = true
        sendClearLocked()
    }

    private func sendClearLocked() {
        sender.sendEvent(["type": "input_audio_buffer.clear"])
    }

    /// Re-chunks converted audio into exact gate frames and preserves append/commit
    /// ordering. Continuous teach capture resets only per-turn VAD state after a
    /// commit; the AVAudioEngine tap and socket stay alive for the next utterance.
    private func gatedUploadActions(from samples: [Int16]) -> [UploadAction] {
        var actions: [UploadAction] = []
        lock.lock()
        pendingSamples.append(contentsOf: samples)
        let samplesPerFrame = gate.configuration.samplesPerFrame
        while pendingSamples.count >= samplesPerFrame {
            let frame = Array(pendingSamples.prefix(samplesPerFrame))
            pendingSamples.removeFirst(samplesPerFrame)
            let result = gate.ingestPCM16Frame(frame)
            ingestedFrameTotal += 1
            uploadedFrameTotal += result.uploadFrames.count
            if result.didConfirmSpeech { speechConfirmTotal += 1 }
            if !result.uploadFrames.isEmpty {
                hasUploadedAudio = true
                actions.append(.append(Self.pcm16Data(frames: result.uploadFrames)))
            }
            if mode == .continuousGated,
               hasUploadedAudio,
               result.snapshot.releaseDecision == .commit {
                actions.append(.commit)
                resetTurnLocked()
            }
        }
        lock.unlock()
        return actions
    }

    private func resetTurnLocked() {
        gate.reset()
        hasUploadedAudio = false
        keyUpAtMs = nil
        partialTranscript = ""
    }

    private func endpointDecisionOnRelease() -> VoiceTurnEndpointPolicy.Decision {
        lock.lock()
        if keyUpAtMs == nil {
            keyUpAtMs = gate.snapshot.totalMs
        }
        let snapshot = gate.snapshot
        let keyUpAtMs = keyUpAtMs
        let hasUnfinishedLexicalFragment = VoiceTurnEndpointPolicy.hasUnfinishedLexicalFragment(partialTranscript)
        lock.unlock()

        let lastSpeechAtMs: Int?
        let speechStartedAtMs: Int?
        if snapshot.uploadedSpeechMs > 0 {
            let lastSpeech = max(0, snapshot.totalMs - snapshot.trailingSilenceMs)
            lastSpeechAtMs = lastSpeech
            speechStartedAtMs = max(0, lastSpeech - snapshot.uploadedSpeechMs)
        } else {
            lastSpeechAtMs = nil
            speechStartedAtMs = nil
        }

        return policy.decide(VoiceTurnEndpointPolicy.Timing(
            nowMs: snapshot.totalMs,
            keyDownAtMs: 0,
            keyUpAtMs: keyUpAtMs,
            speechStartedAtMs: speechStartedAtMs,
            lastSpeechAtMs: lastSpeechAtMs,
            uploadedSpeechMs: snapshot.uploadedSpeechMs,
            hasUnfinishedLexicalFragment: hasUnfinishedLexicalFragment
        ))
    }

    private static func pcm16Data(frames: [[Int16]]) -> Data {
        var data = Data(capacity: frames.reduce(0) { $0 + $1.count * MemoryLayout<Int16>.size })
        for frame in frames {
            data.append(frame.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        return data
    }
}

/// Replaces the Apple Speech / AVSpeechSynthesizer voice with OpenAI **GPT-Realtime-2**:
/// push-to-talk audio streams up as PCM16, the user's transcript comes back and is handed
/// to Claude (`onUtterance`), and Claude's reply is spoken by the realtime voice. Same
/// small idle/listening/working surface the app model expects.
@MainActor
public final class RealtimeVoice: ObservableObject {
    public enum VoiceState: Equatable { case idle, listening, working }

    public enum CapturePurpose: Hashable, Sendable {
        case pushToTalk
        case teachAmbient(sessionID: UUID, automaticEndpointing: Bool)
        case unknown

        var teachingSessionID: UUID? {
            if case .teachAmbient(let sessionID, _) = self { return sessionID }
            return nil
        }
    }

    /// One physical press/open request. `CapturePurpose` says where a transcript routes;
    /// it is deliberately not identity because two rapid PTT presses share that purpose.
    private struct CaptureRequest: Equatable, Sendable {
        let generation: UInt64
        let purpose: CapturePurpose
    }

    public struct CompletedUtterance: Equatable, Sendable {
        public let text: String
        public let itemID: String
        public let purpose: CapturePurpose

        public init(text: String, itemID: String, purpose: CapturePurpose) {
            self.text = text
            self.itemID = itemID
            self.purpose = purpose
        }
    }

    public enum TranscriptionDrainResult: String, Equatable, Sendable {
        case drained
        case timedOut = "timed_out"
        case disconnected
    }

    @Published public private(set) var state: VoiceState = .idle
    @Published public private(set) var transcript = ""
    /// Live mic loudness (0…1, smoothed) while listening — drives the notch's
    /// speech-reactive waveform so the user SEES their voice being heard.
    @Published public private(set) var inputLevel: Float = 0

    /// Spoken phrase handed off to Claude when the user releases the talk key.
    public var onUtterance: ((CompletedUtterance) -> Void)?

    /// Counts-only capture lifecycle forensics ("started"/"failed"/"closed" with the
    /// endpoint session's frame/speech/commit tallies). The teach narration loss was
    /// invisible because every link in this chain failed silently; the app audits
    /// these lines so the next silent demo names the dead link.
    public var onCaptureDiagnostics: ((String) -> Void)?
    private var lastPrepareFailureReason = "unknown"

    private static func purposeTag(_ purpose: CapturePurpose) -> String {
        switch purpose {
        case .pushToTalk: return "ptt"
        case .teachAmbient: return "teach"
        case .unknown: return "unknown"
        }
    }

    private func emitCaptureDiagnostics(_ event: String, purpose: CapturePurpose, extra: String = "") {
        let tail = extra.isEmpty ? "" : " " + extra
        onCaptureDiagnostics?("purpose=\(Self.purposeTag(purpose)) event=\(event)" + tail)
    }
    /// Live transcript prefix for UI and safe warmups only. Completed transcripts
    /// remain the only path to execution.
    public var onPartialUtterance: ((String) -> Void)?
    /// The user barged in while the agent was responding.
    public var onInterrupt: (() -> Void)?

    public nonisolated static let experimentalLocalVoiceEndpointingKey = "cascade.experimentalLocalVoiceEndpointing"
    public nonisolated static let teachAmbientVoiceEndpointingKey = "cascade.teachAmbientVoiceEndpointing"

    private let keyStore = OpenAIKeyStore()
    private var urlSession: URLSession?
    private var socket: RealtimeSocket?
    private var connected = false
    private var connectWaiters: [CheckedContinuation<Bool, Never>] = []
    private var micAuthorized = false
    private var permissionMessage: String?

    // Audio
    private let audioEnabled: Bool
    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private let localVoiceEndpointingEnabled: Bool
    private var endpointSession: RealtimeVoiceEndpointSession?
    private var endpointCommitTask: Task<Void, Never>?
    private let responseState = RealtimeVoiceResponseState()
    let transcriptionTracker = RealtimeVoiceTranscriptionTracker()
    private var partialTranscriptsByItemID: [String: String] = [:]
    /// Request identity spans the async connect → capture handshake. Purpose still
    /// prevents Right Command from closing teach capture, while generation prevents a
    /// stale waiter/tail task from mutating a newer press with the same purpose.
    private var nextCaptureGeneration: UInt64 = 0
    private var requestedCapture: CaptureRequest?
    private var activeCapture: CaptureRequest?
    var requestedCapturePurpose: CapturePurpose? { requestedCapture?.purpose }
    var activeCapturePurpose: CapturePurpose? { activeCapture?.purpose }
    var requestedCaptureGeneration: UInt64? { requestedCapture?.generation }
    var activeCaptureGeneration: UInt64? { activeCapture?.generation }

    /// Narrow headless capture seam: tests exercise the real request/endpoint state
    /// machine while replacing only microphone authorization, socket bring-up, and the
    /// hardware tap. Production leaves both values nil.
    private var capturePreparationOverride: (@Sendable () async -> Bool)?
    private var captureSenderOverride: (any RealtimeVoiceEventSending)?

    private static let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2")!

    public nonisolated static func experimentalLocalVoiceEndpointingEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: experimentalLocalVoiceEndpointingKey)
    }

    public nonisolated static func teachAmbientVoiceEndpointingEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: teachAmbientVoiceEndpointingKey) as? Bool) ?? false
    }

    public init(
        audioEnabled: Bool = true,
        defaults: UserDefaults = .standard,
        localEndpointingEnabled: Bool? = nil
    ) {
        self.audioEnabled = audioEnabled
        self.localVoiceEndpointingEnabled = localEndpointingEnabled
            ?? Self.experimentalLocalVoiceEndpointingEnabled(defaults: defaults)
        guard audioEnabled else { return }
        let captureEngine = AVAudioEngine()
        let playbackEngine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        guard let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false) else {
            permissionMessage = "No audio output is available."
            return
        }
        self.captureEngine = captureEngine
        self.playbackEngine = playbackEngine
        self.playerNode = playerNode
        self.playbackFormat = playbackFormat
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
    }

    convenience init(
        testingEventSender: any RealtimeVoiceEventSending,
        localEndpointingEnabled: Bool,
        prepareCapture: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.init(audioEnabled: false, localEndpointingEnabled: localEndpointingEnabled)
        self.captureSenderOverride = testingEventSender
        self.capturePreparationOverride = prepareCapture
    }

    public var hint: String {
        switch state {
        case .idle: return permissionMessage ?? "Hold right ⌘ to talk"
        case .listening: return transcript.isEmpty ? "Listening…" : transcript
        case .working: return "Thinking…"
        }
    }

    // MARK: - Push-to-talk

    public func beginTalking(purpose: CapturePurpose = .pushToTalk) {
        if let activeCapture {
            guard activeCapture.purpose == purpose else { return }
            // A locally-endpointed PTT release can still own the mic during its short
            // tail wait. A genuinely new press must cancel that old generation before
            // opening another; a repeat key-down while actively listening stays a no-op.
            guard purpose == .pushToTalk, state == .working else { return }
            abandonCaptureForNewPushToTalk(activeCapture)
        }
        if let requestedCapture {
            guard requestedCapture.purpose == purpose else { return }
            return
        }
        cancelPendingEndpointCommit(clearBufferedAudio: true)
        nextCaptureGeneration &+= 1
        let request = CaptureRequest(generation: nextCaptureGeneration, purpose: purpose)
        requestedCapture = request
        // Barge-in: cut the agent off and listen.
        if state == .working || (playerNode?.isPlaying ?? false) || responseState.hasActiveResponse {
            for event in responseState.bargeInEvents() {
                socket?.sendEvent(event)
            }
            stopPlayback()
            onInterrupt?()
        }
        guard state != .listening else { return }
        state = .idle
        Task { @MainActor in
            guard await prepareCapture() else {
                emitCaptureDiagnostics("failed", purpose: request.purpose, extra: "reason=\(lastPrepareFailureReason)")
                if requestedCapture == request { requestedCapture = nil }
                return
            }
            // Cold WebSocket: the user may have already released the key while we
            // were connecting. Starting a capture they can no longer end would
            // wedge state at .listening and make the NEXT press a no-op. Bail and
            // settle back to idle instead. (Main-actor serialized, so this guard
            // and startCapture can't be split by a release.)
            guard requestedCapture == request else { return }
            startCapture(request: request)
        }
    }

    public func endTalking(purpose: CapturePurpose = .pushToTalk) {
        if requestedCapture?.purpose == purpose { requestedCapture = nil }
        guard let activeCapture, activeCapture.purpose == purpose else { return }
        guard state == .listening else { return }
        transcriptionTracker.captureWillClose(purpose)
        guard let endpointSession else {
            stopCapture()
            if let sender = captureEventSender {
                let eventID = transcriptionTracker.noteCommit(from: purpose)
                sender.sendEvent([
                    "type": "input_audio_buffer.commit",
                    "event_id": eventID,
                ])
            }
            self.activeCapture = nil
            transcriptionTracker.captureDidClose(purpose)
            state = .working
            return
        }

        switch endpointSession.release() {
        case .cleared:
            finishCapture(activeCapture, state: .idle)
        case .committed:
            finishCapture(activeCapture, state: .working)
        case .tailWait(let remainingMs):
            state = .working
            scheduleEndpointTailWait(endpointSession, request: activeCapture, initialDelayMs: remainingMs)
        }
        // The transcript arrives via conversation.item.input_audio_transcription.completed.
    }

    public func done() { if state == .working { state = .idle } }

    public func drainTranscriptions(
        forTeachingSession sessionID: UUID,
        timeout: Duration = .seconds(90)
    ) async -> TranscriptionDrainResult {
        await transcriptionTracker.drain(teachingSessionID: sessionID, timeout: timeout)
    }

    public func speak(_ text: String) {
        guard audioEnabled else { return }
        guard state != .listening else { return }
        // NOTE: speak() must not touch `state` — mid-run narration would flip
        // .working → .idle and collapse the notch while the agent still works;
        // done() owns the return to idle.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            guard await ensureConnected() else { return }
            for event in responseState.speechResponseEvents(for: trimmed) {
                socket?.sendEvent(event)
            }
        }
    }

    // MARK: - Connection

    private var captureEventSender: (any RealtimeVoiceEventSending)? {
        captureSenderOverride ?? socket
    }

    private func prepareCapture() async -> Bool {
        if let capturePreparationOverride {
            return await capturePreparationOverride()
        }
        guard await ensureMic() else { return false }
        return await ensureConnected()
    }

    private func ensureConnected() async -> Bool {
        if connected { return true }
        guard let key = keyStore.readKey(), !key.isEmpty else {
            permissionMessage = "Add your OpenAI key in Settings to use voice."
            lastPrepareFailureReason = "no_openai_key"
            return false
        }
        if socket == nil { openSocket(key: key) }
        let connectedNow = await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
        }
        if !connectedNow { lastPrepareFailureReason = "connect_failed" }
        return connectedNow
    }

    private func openSocket(key: String) {
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        let sock = RealtimeSocket(task: task)
        sock.onText = { [weak self] text in Task { @MainActor in self?.handle(text) } }
        sock.onClose = { [weak self] in Task { @MainActor in self?.handleClose() } }
        urlSession = session
        socket = sock
        sock.start()
    }

    private func handleClose() {
        if let activeCapture {
            emitCaptureDiagnostics("closed", purpose: activeCapture.purpose, extra: "reason=socket_closed " + (endpointSession?.diagnosticsSummary() ?? ""))
        }
        cancelPendingEndpointCommit(clearBufferedAudio: false)
        stopCapture()
        endpointSession = nil
        requestedCapture = nil
        activeCapture = nil
        partialTranscriptsByItemID.removeAll()
        transcriptionTracker.disconnect()
        responseState.clear()
        connected = false
        socket = nil
        let waiters = connectWaiters
        connectWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
        if state != .idle { permissionMessage = "Voice disconnected — try again."; state = .idle }
    }

    private func sessionUpdate() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": "You are the spoken voice of Cascade. When asked to read text, read it verbatim and add nothing.",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "turn_detection": NSNull(),
                        // Lock transcription to English — without it the model
                        // mis-rendered English speech as Arabic phonetics, spawning
                        // garbled assist.task goals that superseded live runs.
                        "transcription": ["model": "gpt-4o-transcribe", "language": "en"],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": "marin",
                    ],
                ],
            ],
        ]
    }

    // MARK: - Incoming events

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String != nil else { return }
        handleServerEvent(json)
    }

    /// Internal event seam used by tests to exercise the real commit/transcription
    /// lifecycle without a live WebSocket.
    func handleServerEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "session.created":
            socket?.sendEvent(sessionUpdate())
            connected = true
            transcriptionTracker.connected()
            let waiters = connectWaiters
            connectWaiters.removeAll()
            waiters.forEach { $0.resume(returning: true) }

        case "input_audio_buffer.committed":
            if let itemID = json["item_id"] as? String {
                transcriptionTracker.bindNextCommit(toItemID: itemID)
            }

        case "conversation.item.input_audio_transcription.completed":
            let itemID = json["item_id"] as? String ?? ""
            let purpose = transcriptionTracker.purpose(forItemID: itemID) ?? .unknown
            let said = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            partialTranscriptsByItemID.removeValue(forKey: itemID)
            transcript = ""
            if said.count > 1 {
                let continuingTeachCapture: Bool
                if case .teachAmbient = purpose {
                    continuingTeachCapture = activeCapturePurpose == purpose && state == .listening
                } else {
                    continuingTeachCapture = false
                }
                if state == .listening, !continuingTeachCapture { state = .working }
                // Deliver before settling: a drain waiter may resume immediately when
                // this is the final item, and the model must have buffered the text first.
                onUtterance?(CompletedUtterance(text: said, itemID: itemID, purpose: purpose))
            } else if state == .working, activeCapturePurpose == nil {
                state = .idle
            }
            transcriptionTracker.settle(itemID: itemID)

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String {
                let itemID = json["item_id"] as? String ?? "unbound"
                partialTranscriptsByItemID[itemID, default: ""] += delta
                let partial = partialTranscriptsByItemID[itemID, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if state == .listening { transcript = partial }
                if activeCapturePurpose == .pushToTalk {
                    endpointSession?.updatePartialTranscript(partial)
                }
                if !partial.isEmpty {
                    onPartialUtterance?(partial)
                }
            }

        case "conversation.item.input_audio_transcription.failed":
            let itemID = json["item_id"] as? String ?? ""
            partialTranscriptsByItemID.removeValue(forKey: itemID)
            transcriptionTracker.settle(itemID: itemID)
            if state == .working, activeCapturePurpose == nil { state = .idle }

        case "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                responseState.noteOutputAudioDelta(event: json, pcmByteCount: pcm.count)
                playPCM16(pcm)
            } else {
                responseState.noteOutputAudioDelta(event: json, pcmByteCount: 0)
            }

        case "response.output_audio.done", "response.done", "response.cancelled":
            responseState.clear()

        case "error":
            responseState.clear()
            if let error = json["error"] as? [String: Any] {
                let failedEventID = (error["event_id"] as? String)
                    ?? (json["event_id"] as? String)
                if let failedEventID,
                   transcriptionTracker.failCommit(eventID: failedEventID) != nil,
                   state == .working,
                   activeCapture == nil {
                    state = .idle
                }
                if let message = error["message"] as? String {
                    permissionMessage = message
                }
            }

        default:
            break
        }
    }

    // MARK: - Capture

    private func startCapture(request: CaptureRequest) {
        guard let sender = captureEventSender else {
            permissionMessage = "No microphone input is available."
            emitCaptureDiagnostics("failed", purpose: request.purpose, extra: "reason=no_sender")
            if requestedCapture == request { requestedCapture = nil }
            state = .idle
            return
        }
        cancelPendingEndpointCommit(clearBufferedAudio: false)
        transcript = ""
        partialTranscriptsByItemID.removeAll()
        let endpointSession = RealtimeVoiceEndpointSession(
            mode: endpointMode(for: request.purpose),
            sender: sender,
            purpose: request.purpose,
            onCommit: { [transcriptionTracker] purpose in
                transcriptionTracker.noteCommit(from: purpose)
            }
        )
        self.endpointSession = endpointSession
        sender.sendEvent(["type": "input_audio_buffer.clear"])
        do {
            if captureSenderOverride == nil {
                guard audioEnabled, let captureEngine else {
                    throw NSError(domain: "Cascade.Voice", code: 3)
                }
                try Self.installCaptureTap(engine: captureEngine, endpointSession: endpointSession) { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.state == .listening else { return }
                        // Light smoothing so the bars breathe instead of flickering.
                        self.inputLevel = self.inputLevel * 0.6 + level * 0.4
                    }
                }
            }
            requestedCapture = nil
            activeCapture = request
            state = .listening
            emitCaptureDiagnostics("started", purpose: request.purpose, extra: "mode=\(endpointMode(for: request.purpose))")
        } catch {
            self.endpointSession = nil
            if requestedCapture == request { requestedCapture = nil }
            permissionMessage = "No microphone input is available."
            emitCaptureDiagnostics("failed", purpose: request.purpose, extra: "reason=tap_install")
            state = .idle
        }
    }

    private func endpointMode(for purpose: CapturePurpose) -> RealtimeVoiceEndpointSession.Mode {
        switch purpose {
        case .pushToTalk:
            return localVoiceEndpointingEnabled ? .gatedRelease : .passthroughRelease
        case .teachAmbient(_, let automaticEndpointing):
            return automaticEndpointing ? .continuousGated : .passthroughRelease
        case .unknown:
            return .passthroughRelease
        }
    }

    private func stopCapture() {
        guard let captureEngine else { return }
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        inputLevel = 0
    }

    /// Feeds the same endpoint session as the hardware tap for deterministic ownership
    /// and tail-wait tests. The production capture path never calls this seam.
    func ingestCapturedPCM16ForTesting(_ data: Data) {
        endpointSession?.ingestConvertedPCM16(data)
    }

    private func cancelPendingEndpointCommit(clearBufferedAudio: Bool) {
        endpointCommitTask?.cancel()
        endpointCommitTask = nil
        if clearBufferedAudio, endpointSession != nil, state != .listening {
            endpointSession?.clear()
            endpointSession = nil
            stopCapture()
            state = .idle
        }
    }

    private func abandonCaptureForNewPushToTalk(_ request: CaptureRequest) {
        emitCaptureDiagnostics("abandoned", purpose: request.purpose, extra: endpointSession?.diagnosticsSummary() ?? "")
        endpointCommitTask?.cancel()
        endpointCommitTask = nil
        endpointSession?.clear()
        guard activeCapture == request else { return }
        stopCapture()
        endpointSession = nil
        activeCapture = nil
        transcriptionTracker.captureDidClose(request.purpose)
        state = .idle
    }

    private func scheduleEndpointTailWait(
        _ endpointSession: RealtimeVoiceEndpointSession,
        request: CaptureRequest,
        initialDelayMs: Int
    ) {
        endpointCommitTask = Task { @MainActor [weak self, endpointSession] in
            var delayMs = initialDelayMs
            while true {
                try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
                guard !Task.isCancelled, let self, self.endpointSession === endpointSession else { return }
                switch endpointSession.release() {
                case .tailWait(let remainingMs):
                    delayMs = remainingMs
                    continue
                case .committed:
                    self.endpointCommitTask = nil
                    self.finishCapture(request, state: .working)
                    return
                case .cleared:
                    self.endpointCommitTask = nil
                    self.finishCapture(request, state: .idle)
                    return
                }
            }
        }
    }

    private func finishCapture(_ request: CaptureRequest, state newState: VoiceState) {
        guard activeCapture == request else { return }
        emitCaptureDiagnostics("closed", purpose: request.purpose, extra: endpointSession?.diagnosticsSummary() ?? "")
        stopCapture()
        endpointSession = nil
        activeCapture = nil
        transcriptionTracker.captureDidClose(request.purpose)
        state = newState
    }

    /// Installs the mic tap from a `nonisolated` context (the audio render thread must
    /// not touch main-actor state) and streams converted PCM16/24k frames to the socket.
    nonisolated private static func installCaptureTap(
        engine: AVAudioEngine,
        endpointSession: RealtimeVoiceEndpointSession,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Cascade.Voice", code: 1)
        }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Cascade.Voice", code: 2)
        }
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: endpointSession.captureBufferFrameCount(inputSampleRate: inFormat.sampleRate),
            format: inFormat
        ) { buffer, _ in
            // Cheap RMS on the raw float buffer (sampled, not every frame) so the
            // notch waveform tracks the user's actual speech.
            if let floats = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                if frames > 0 {
                    var sum: Float = 0
                    let stride = max(1, frames / 256)
                    var count = 0
                    var i = 0
                    while i < frames {
                        sum += floats[i] * floats[i]
                        count += 1
                        i += stride
                    }
                    let rms = (sum / Float(max(count, 1))).squareRoot()
                    // Map speech RMS (~0.01–0.3) into 0…1 with a soft knee.
                    onLevel(min(1, rms * 6))
                }
            }
            let ratio = 24_000.0 / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            let inputState = ConverterInputState()
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if inputState.hasFedBuffer {
                    status.pointee = .noDataNow
                    return nil
                }
                inputState.hasFedBuffer = true
                status.pointee = .haveData
                return buffer
            }
            var error: NSError?
            converter.convert(to: out, error: &error, withInputFrom: inputBlock)
            guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
            let data = Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
            endpointSession.ingestConvertedPCM16(data)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - Playback

    private func playPCM16(_ data: Data) {
        guard let playbackFormat, let playbackEngine, let playerNode else { return }
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<frames { out[i] = max(-1, min(1, Float(ints[i]) / 32_768.0)) }
        }
        if !playbackEngine.isRunning { try? playbackEngine.start() }
        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func stopPlayback() {
        guard let playerNode else { return }
        if playerNode.isPlaying { playerNode.stop() }
    }

    // MARK: - Mic auth

    private func ensureMic() async -> Bool {
        guard audioEnabled else {
            lastPrepareFailureReason = "audio_disabled"
            return false
        }
        if micAuthorized { return true }
        let granted = await Self.requestMic()
        micAuthorized = granted
        if !granted {
            permissionMessage = "Allow Microphone in Settings"
            lastPrepareFailureReason = "mic_denied"
        }
        return granted
    }

    nonisolated private static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }
}
