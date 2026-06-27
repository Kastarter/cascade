import Foundation
import Testing

@testable import AppShell

private final class FakeRealtimeVoiceEventSender: RealtimeVoiceEventSending, @unchecked Sendable {
    private(set) var events: [[String: Any]] = []

    func sendEvent(_ object: [String: Any]) {
        events.append(object)
    }

    func appendAudio(base64: String) {
        sendEvent(["type": "input_audio_buffer.append", "audio": base64])
    }

    var eventTypes: [String] {
        events.compactMap { $0["type"] as? String }
    }
}

private let realtimeEndpointGateConfig = LocalVoiceActivityGate.Configuration(
    sampleRate: 24_000,
    frameDurationMs: 30,
    prefixPaddingMs: 300,
    minSpeechMs: 210,
    hangoverMs: 240
)

private let realtimeEndpointPolicy = VoiceTurnEndpointPolicy(settings: VoiceTurnEndpointPolicy.Settings(
    minSpeechMs: 210,
    hangoverMs: 30,
    maxTailMs: 90,
    lexicalFragmentWaitMs: 0
))

private func realtimeSilenceFrame() -> [Int16] {
    [Int16](repeating: 0, count: realtimeEndpointGateConfig.samplesPerFrame)
}

private func realtimeSpeechFrame(amplitude: Int16 = 8_000) -> [Int16] {
    let quarter = max(1, realtimeEndpointGateConfig.samplesPerFrame / 4)
    return (0..<realtimeEndpointGateConfig.samplesPerFrame).map { index in
        switch (index / quarter) % 4 {
        case 0: return amplitude
        case 1: return amplitude / 2
        case 2: return -amplitude
        default: return -(amplitude / 2)
        }
    }
}

private func realtimeFrameData(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { pointer in
        Data(buffer: pointer)
    }
}

private func feedRealtimeEndpoint(_ session: RealtimeVoiceEndpointSession, frames: [[Int16]]) {
    for frame in frames {
        session.ingestConvertedPCM16(realtimeFrameData(frame))
    }
}

private func makeRealtimeEndpointSession(
    enabled: Bool,
    sender: FakeRealtimeVoiceEventSender
) -> RealtimeVoiceEndpointSession {
    RealtimeVoiceEndpointSession(
        localEndpointingEnabled: enabled,
        sender: sender,
        gateConfiguration: realtimeEndpointGateConfig,
        endpointPolicy: realtimeEndpointPolicy
    )
}

struct RealtimeVoiceEndpointPolicyTests {
    @Test func localEndpointingFlagDefaultsOff() {
        let defaults = UserDefaults(suiteName: "RealtimeVoiceEndpointDefault-\(UUID().uuidString)")!

        #expect(!RealtimeVoice.experimentalLocalVoiceEndpointingEnabled(defaults: defaults))
    }

    @Test func enabledShortNoiseReleaseClearsInsteadOfCommit() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: true, sender: sender)
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        feedRealtimeEndpoint(
            session,
            frames: Array(repeating: realtimeSpeechFrame(amplitude: 14_000), count: 5)
                + Array(repeating: realtimeSilenceFrame(), count: 8)
        )
        let result = session.release()

        #expect(result == .cleared)
        #expect(sender.eventTypes == ["input_audio_buffer.clear", "input_audio_buffer.clear"])
        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))
    }

    @Test func enabledSpeechPlusTailCommitsAfterPolicyDelay() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: true, sender: sender)
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        feedRealtimeEndpoint(session, frames: Array(repeating: realtimeSpeechFrame(), count: 8))
        let result = session.release()

        #expect(result == .tailWait(remainingMs: 30))
        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))

        session.commit()

        #expect(sender.eventTypes.last == "input_audio_buffer.commit")
    }

    @Test func disabledPathKeepsLegacyClearAppendCommitSequence() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: false, sender: sender)
        let frame = realtimeFrameData(realtimeSpeechFrame())
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        session.ingestConvertedPCM16(frame)
        let result = session.release()

        #expect(result == .committed)
        #expect(sender.eventTypes == [
            "input_audio_buffer.clear",
            "input_audio_buffer.append",
            "input_audio_buffer.commit"
        ])
        #expect(sender.events[1]["audio"] as? String == frame.base64EncodedString())
    }
}
