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

private final class ConverterInputState: @unchecked Sendable {
    var hasFedBuffer = false
}

/// Replaces the Apple Speech / AVSpeechSynthesizer voice with OpenAI **GPT-Realtime-2**:
/// push-to-talk audio streams up as PCM16, the user's transcript comes back and is handed
/// to Claude (`onUtterance`), and Claude's reply is spoken by the realtime voice. Same
/// small idle/listening/working surface the app model expects.
@MainActor
public final class RealtimeVoice: ObservableObject {
    public enum VoiceState: Equatable { case idle, listening, working }

    @Published public private(set) var state: VoiceState = .idle
    @Published public private(set) var transcript = ""
    /// Live mic loudness (0…1, smoothed) while listening — drives the notch's
    /// speech-reactive waveform so the user SEES their voice being heard.
    @Published public private(set) var inputLevel: Float = 0

    /// Spoken phrase handed off to Claude when the user releases the talk key.
    public var onUtterance: ((String) -> Void)?
    /// The user barged in while the agent was responding.
    public var onInterrupt: (() -> Void)?

    private let keyStore = OpenAIKeyStore()
    private var urlSession: URLSession?
    private var socket: RealtimeSocket?
    private var connected = false
    private var connectWaiters: [CheckedContinuation<Bool, Never>] = []
    private var micAuthorized = false
    private var permissionMessage: String?

    // Audio
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    private static let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2")!

    public init() {
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
    }

    public var hint: String {
        switch state {
        case .idle: return permissionMessage ?? "Hold right ⌘ to talk"
        case .listening: return transcript.isEmpty ? "Listening…" : transcript
        case .working: return "Thinking…"
        }
    }

    // MARK: - Push-to-talk

    public func beginTalking() {
        // Barge-in: cut the agent off and listen.
        if state == .working || playerNode.isPlaying {
            stopPlayback()
            socket?.sendEvent(["type": "response.cancel"])
            onInterrupt?()
        }
        guard state != .listening else { return }
        state = .idle
        Task { @MainActor in
            guard await ensureMic() else { return }
            guard await ensureConnected() else { return }
            startCapture()
        }
    }

    public func endTalking() {
        guard state == .listening else { return }
        stopCapture()
        socket?.sendEvent(["type": "input_audio_buffer.commit"])
        state = .working
        // The transcript arrives via conversation.item.input_audio_transcription.completed.
    }

    public func done() { if state == .working { state = .idle } }

    public func speak(_ text: String) {
        guard state != .listening else { return }
        if state == .working { state = .idle }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            guard await ensureConnected() else { return }
            socket?.sendEvent([
                "type": "response.create",
                "response": [
                    "instructions": "You are a text-to-speech voice. Read the following text aloud exactly as written, naturally, and add NOTHING else: \(trimmed)",
                ],
            ])
        }
    }

    // MARK: - Connection

    private func ensureConnected() async -> Bool {
        if connected { return true }
        guard let key = keyStore.readKey(), !key.isEmpty else {
            permissionMessage = "Add your OpenAI key in Settings to use voice."
            return false
        }
        if socket == nil { openSocket(key: key) }
        return await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
        }
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
                        "transcription": ["model": "gpt-4o-transcribe"],
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
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created":
            socket?.sendEvent(sessionUpdate())
            connected = true
            let waiters = connectWaiters
            connectWaiters.removeAll()
            waiters.forEach { $0.resume(returning: true) }

        case "conversation.item.input_audio_transcription.completed":
            let said = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = ""
            if said.count > 1 {
                if state == .listening { state = .working }
                onUtterance?(said)
            } else if state == .working {
                state = .idle
            }

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, state == .listening { transcript += delta }

        case "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) { playPCM16(pcm) }

        case "error":
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                permissionMessage = message
            }

        default:
            break
        }
    }

    // MARK: - Capture

    private func startCapture() {
        transcript = ""
        socket?.sendEvent(["type": "input_audio_buffer.clear"])
        do {
            try Self.installCaptureTap(engine: captureEngine, sender: socket!) { [weak self] level in
                Task { @MainActor in
                    guard let self, self.state == .listening else { return }
                    // Light smoothing so the bars breathe instead of flickering.
                    self.inputLevel = self.inputLevel * 0.6 + level * 0.4
                }
            }
            state = .listening
        } catch {
            permissionMessage = "No microphone input is available."
            state = .idle
        }
    }

    private func stopCapture() {
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        inputLevel = 0
    }

    /// Installs the mic tap from a `nonisolated` context (the audio render thread must
    /// not touch main-actor state) and streams converted PCM16/24k frames to the socket.
    nonisolated private static func installCaptureTap(
        engine: AVAudioEngine,
        sender: RealtimeSocket,
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
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
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
            sender.appendAudio(base64: data.base64EncodedString())
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - Playback

    private func playPCM16(_ data: Data) {
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
        if playerNode.isPlaying { playerNode.stop() }
    }

    // MARK: - Mic auth

    private func ensureMic() async -> Bool {
        if micAuthorized { return true }
        let granted = await Self.requestMic()
        micAuthorized = granted
        if !granted { permissionMessage = "Allow Microphone in Settings" }
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
