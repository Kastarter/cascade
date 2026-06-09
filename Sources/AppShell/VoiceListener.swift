@preconcurrency import AVFoundation
import Combine
@preconcurrency import Speech
import SwiftUI

/// Push-to-talk voice: while the talk key is held it listens (Apple Speech); on
/// release it hands off the spoken phrase, then speaks the response back. One hold
/// = one request, so there's no continuous-listening state to wedge.
@MainActor
public final class VoiceListener: ObservableObject {
    public enum VoiceState: Equatable { case idle, listening, working }

    @Published public private(set) var state: VoiceState = .idle
    @Published public private(set) var transcript = ""

    /// Invoked with the spoken phrase when the user releases the talk key.
    public var onUtterance: ((String) -> Void)?

    /// Invoked when the user barges in — starts talking while the agent is still
    /// responding — so the owner can halt the agent's in-flight task.
    public var onInterrupt: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var authed = false
    private var permissionMessage: String?

    public init() {}

    /// Talk key down → start listening (requests permission on first use). If the
    /// agent is mid-response — speaking aloud or still working — the user starting
    /// to talk *barges in*: cut the speech, cancel the in-flight task, then listen.
    public func beginTalking() {
        if synthesizer.isSpeaking || state == .working {
            synthesizer.stopSpeaking(at: .immediate)
            onInterrupt?()
        }
        guard state != .listening else { return }
        state = .idle
        Task { @MainActor in
            guard await ensureAuth() else { return }
            startListening()
        }
    }

    /// Talk key up → stop listening and hand off the spoken phrase.
    public func endTalking() {
        guard state == .listening else { return }
        let phrase = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        transcript = ""
        if phrase.count > 1 {
            state = .working
            onUtterance?(phrase)
        } else {
            state = .idle
        }
    }

    /// Owner calls this when the request finished (cursor moved / answer spoken).
    public func done() {
        if state == .working { state = .idle }
    }

    /// Short status line for the top-bar indicator.
    public var hint: String {
        switch state {
        case .idle: return permissionMessage ?? "Hold right ⌘ to talk"
        case .listening: return transcript.isEmpty ? "Listening…" : transcript
        case .working: return "Thinking…"
        }
    }

    public func speak(_ text: String) {
        // Don't talk over the user: if they've barged in and are listening, stay quiet.
        guard state != .listening else { return }
        if state == .working { state = .idle }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    private func ensureAuth() async -> Bool {
        if authed { return true }
        guard await Self.requestSpeechAuth() else {
            permissionMessage = "Allow Speech Recognition in Settings"
            return false
        }
        guard await Self.requestMicAuth() else {
            permissionMessage = "Allow Microphone in Settings"
            return false
        }
        authed = true
        permissionMessage = nil
        return true
    }

    private func startListening() {
        guard let recognizer, recognizer.isAvailable else {
            permissionMessage = "Speech recognition unavailable"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        do {
            try Self.startEngine(engine, appendingTo: request)
        } catch {
            permissionMessage = "No microphone input"
            self.request = nil
            return
        }
        transcript = ""
        state = .listening

        let onText: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                self.transcript = text
            }
        }
        task = Self.makeTask(recognizer: recognizer, request: request, onText: onText)
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    nonisolated private static func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus == .authorized)
            }
        }
    }

    nonisolated private static func requestMicAuth() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// Installs the mic tap + starts the engine from a `nonisolated` context so the
    /// audio render thread doesn't trip Swift's main-actor isolation assertion.
    nonisolated private static func startEngine(
        _ engine: AVAudioEngine,
        appendingTo request: SFSpeechAudioBufferRecognitionRequest
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "Cascade.Voice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input is available."
            ])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    nonisolated private static func makeTask(
        recognizer: SFSpeechRecognizer?,
        request: SFSpeechAudioBufferRecognitionRequest,
        onText: @escaping @Sendable (String) -> Void
    ) -> SFSpeechRecognitionTask? {
        recognizer?.recognitionTask(with: request) { result, _ in
            if let text = result?.bestTranscription.formattedString { onText(text) }
        }
    }
}
