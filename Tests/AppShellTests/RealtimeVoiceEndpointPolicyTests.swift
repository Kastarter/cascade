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

private final class BlockingRealtimeVoiceEventSender: RealtimeVoiceEventSending, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var shouldBlockAppend = true
    private let appendEntered = DispatchSemaphore(value: 0)
    private let resumeAppend = DispatchSemaphore(value: 0)

    func sendEvent(_ object: [String: Any]) {
        lock.lock()
        events.append(object)
        lock.unlock()
    }

    func appendAudio(base64: String) {
        let block: Bool
        lock.lock()
        events.append(["type": "input_audio_buffer.append", "audio": base64])
        block = shouldBlockAppend
        shouldBlockAppend = false
        lock.unlock()

        if block {
            appendEntered.signal()
            _ = resumeAppend.wait(timeout: .now() + 5)
        }
    }

    func waitForBlockedAppend() -> Bool {
        appendEntered.wait(timeout: .now() + 5) == .success
    }

    func allowAppendToFinish() {
        resumeAppend.signal()
    }

    var eventTypes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { $0["type"] as? String }
    }
}

private final class ReleaseResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RealtimeVoiceEndpointSession.ReleaseResult?

    func record(_ result: RealtimeVoiceEndpointSession.ReleaseResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: RealtimeVoiceEndpointSession.ReleaseResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
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

private func realtimeClickFrame() -> [Int16] {
    var frame = realtimeSilenceFrame()
    frame[realtimeEndpointGateConfig.samplesPerFrame / 2] = 31_000
    return frame
}

private func realtimeFrameData(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { pointer in
        Data(buffer: pointer)
    }
}

private func appendedSampleCount(_ sender: FakeRealtimeVoiceEventSender) -> Int {
    sender.events
        .filter { $0["type"] as? String == "input_audio_buffer.append" }
        .compactMap { $0["audio"] as? String }
        .compactMap { Data(base64Encoded: $0) }
        .reduce(0) { $0 + $1.count / MemoryLayout<Int16>.size }
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

private func makeRealtimeEndpointSession(
    mode: RealtimeVoiceEndpointSession.Mode,
    sender: FakeRealtimeVoiceEventSender,
    purpose: RealtimeVoice.CapturePurpose = .pushToTalk
) -> RealtimeVoiceEndpointSession {
    RealtimeVoiceEndpointSession(
        mode: mode,
        sender: sender,
        purpose: purpose,
        gateConfiguration: realtimeEndpointGateConfig,
        endpointPolicy: realtimeEndpointPolicy
    )
}

struct RealtimeVoiceEndpointPolicyTests {
    @Test func localEndpointingFlagDefaultsOff() {
        let defaults = UserDefaults(suiteName: "RealtimeVoiceEndpointDefault-\(UUID().uuidString)")!

        #expect(!RealtimeVoice.experimentalLocalVoiceEndpointingEnabled(defaults: defaults))
    }

    @Test func teachAmbientEndpointingDefaultsOnWithEscapeHatch() {
        let defaults = UserDefaults(suiteName: "RealtimeVoiceTeachEndpoint-\(UUID().uuidString)")!

        #expect(RealtimeVoice.teachAmbientVoiceEndpointingEnabled(defaults: defaults))

        defaults.set(false, forKey: RealtimeVoice.teachAmbientVoiceEndpointingKey)
        #expect(!RealtimeVoice.teachAmbientVoiceEndpointingEnabled(defaults: defaults))
    }

    @Test func teachAmbientCommitsAtEachSpeechHangoverAndContinuesCapture() {
        let sender = FakeRealtimeVoiceEventSender()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: UUID(),
            automaticEndpointing: true
        )
        let session = makeRealtimeEndpointSession(
            mode: .continuousGated,
            sender: sender,
            purpose: purpose
        )
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        let utterance = Array(repeating: realtimeSpeechFrame(), count: 8)
            + Array(repeating: realtimeSilenceFrame(), count: 8)
        feedRealtimeEndpoint(session, frames: utterance + utterance)

        #expect(sender.eventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 2)
        let firstCommit = sender.eventTypes.firstIndex(of: "input_audio_buffer.commit")
        let secondCommit = sender.eventTypes.lastIndex(of: "input_audio_buffer.commit")
        #expect(firstCommit != nil)
        #expect(secondCommit != nil)
        #expect(firstCommit != secondCommit)
        // The session is still alive after two automatic turns; closing an empty
        // current turn clears rather than fabricating a third transcript.
        #expect(session.release() == .cleared)
        #expect(sender.eventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 2)
    }

    @Test func concurrentHangoverCommitCompletesBeforeCaptureCloseCanClear() async {
        let sender = BlockingRealtimeVoiceEventSender()
        let tracker = RealtimeVoiceTranscriptionTracker()
        let sessionID = UUID()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: sessionID,
            automaticEndpointing: true
        )
        let session = RealtimeVoiceEndpointSession(
            mode: .continuousGated,
            sender: sender,
            purpose: purpose,
            onCommit: { tracker.noteCommit(from: $0) },
            gateConfiguration: realtimeEndpointGateConfig,
            endpointPolicy: realtimeEndpointPolicy
        )
        let frames = Array(repeating: realtimeSpeechFrame(), count: 8)
            + Array(repeating: realtimeSilenceFrame(), count: 8)
        let data = realtimeFrameData(frames.flatMap { $0 })

        let ingestTask = Task.detached {
            session.ingestConvertedPCM16(data)
        }
        #expect(sender.waitForBlockedAppend())

        let releaseProbe = ReleaseResultProbe()
        let releaseTask = Task.detached {
            let result = session.release()
            releaseProbe.record(result)
            return result
        }
        try? await Task.sleep(for: .milliseconds(30))
        // Close must be waiting behind the already-decided append+commit delivery.
        #expect(releaseProbe.result == nil)

        sender.allowAppendToFinish()
        await ingestTask.value
        #expect(await releaseTask.value == .cleared)

        let types = sender.eventTypes
        let commitIndex = types.firstIndex(of: "input_audio_buffer.commit")
        let clearIndex = types.firstIndex(of: "input_audio_buffer.clear")
        #expect(commitIndex != nil)
        #expect(clearIndex != nil)
        if let commitIndex, let clearIndex {
            #expect(commitIndex < clearIndex)
        }

        // The commit is registered before close becomes observable, so drain cannot
        // falsely report completion while its server item/transcript is outstanding.
        #expect(await tracker.drain(teachingSessionID: sessionID, timeout: .milliseconds(10)) == .timedOut)
        tracker.bindNextCommit(toItemID: "concurrent-final-item")
        tracker.settle(itemID: "concurrent-final-item")
        #expect(await tracker.drain(teachingSessionID: sessionID, timeout: .milliseconds(10)) == .drained)
    }

    @Test func teachAmbientEscapeHatchFallsBackToOneCommitOnRelease() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(mode: .passthroughRelease, sender: sender)
        let utterance = Array(repeating: realtimeSpeechFrame(), count: 8)
            + Array(repeating: realtimeSilenceFrame(), count: 8)

        feedRealtimeEndpoint(session, frames: utterance + utterance)
        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))

        #expect(session.release() == .committed)
        #expect(sender.eventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 1)
    }

    @Test func pushToTalkNeverAutoCommitsWhileHeld() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(mode: .gatedRelease, sender: sender)
        let utterance = Array(repeating: realtimeSpeechFrame(), count: 8)
            + Array(repeating: realtimeSilenceFrame(), count: 8)

        feedRealtimeEndpoint(session, frames: utterance + utterance)

        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))
        #expect(session.release() == .committed)
        #expect(sender.eventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 1)
    }

    @Test func teachAmbientNoiseAndShortSpeechNeverCommit() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(mode: .continuousGated, sender: sender)

        feedRealtimeEndpoint(
            session,
            frames: [realtimeClickFrame(), realtimeClickFrame()]
                + Array(repeating: realtimeSpeechFrame(), count: 5)
                + Array(repeating: realtimeSilenceFrame(), count: 10)
        )

        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))
        #expect(session.release() == .cleared)
    }

    @MainActor @Test func pushToTalkReleaseDoesNotCancelTeachOwnedHandshake() {
        let voice = RealtimeVoice(audioEnabled: false)
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: UUID(),
            automaticEndpointing: true
        )

        voice.beginTalking(purpose: purpose)
        #expect(voice.requestedCapturePurpose == purpose)

        voice.endTalking()
        #expect(voice.requestedCapturePurpose == purpose)
    }

    @Test func enabledShortSpeechReleaseClearsWithoutAppending() {
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
        #expect(!sender.eventTypes.contains("input_audio_buffer.append"))
        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))
        #expect(sender.eventTypes.last == "input_audio_buffer.clear")
    }

    @Test func enabledQuietSpeechReleaseClearsWithoutAppending() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: true, sender: sender)
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        // Peak ~0.006 — well under minSpeechPeak (0.05), so the gate never confirms.
        feedRealtimeEndpoint(session, frames: Array(repeating: realtimeSpeechFrame(amplitude: 200), count: 20))
        let result = session.release()

        #expect(result == .cleared)
        #expect(!sender.eventTypes.contains("input_audio_buffer.append"))
        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))
        #expect(sender.eventTypes.last == "input_audio_buffer.clear")
    }

    @Test func enabledClickBurstReleaseClearsWithoutAppending() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: true, sender: sender)
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        feedRealtimeEndpoint(
            session,
            frames: [realtimeClickFrame(), realtimeClickFrame()]
                + Array(repeating: realtimeSilenceFrame(), count: 6)
        )
        let result = session.release()

        #expect(result == .cleared)
        #expect(!sender.eventTypes.contains("input_audio_buffer.append"))
        #expect(!sender.eventTypes.contains("input_audio_buffer.commit"))
    }

    @Test func enabledEmptyReleaseClears() {
        // No audio captured at all (key tapped and released instantly): nothing to
        // transcribe, so clear rather than commit an empty buffer.
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: true, sender: sender)
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        let result = session.release()

        #expect(result == .cleared)
        #expect(!sender.eventTypes.contains("input_audio_buffer.append"))
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
        let samplesBeforeTail = appendedSampleCount(sender)

        feedRealtimeEndpoint(session, frames: [realtimeSilenceFrame()])
        let final = session.release()

        #expect(final == .committed)
        #expect(appendedSampleCount(sender) == samplesBeforeTail + realtimeEndpointGateConfig.samplesPerFrame)
        #expect(sender.eventTypes.last == "input_audio_buffer.commit")
    }

    @Test func enabledNormalSpeechUploadsPrefixSpeechAndHangoverFrames() {
        let sender = FakeRealtimeVoiceEventSender()
        let session = makeRealtimeEndpointSession(enabled: true, sender: sender)
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        feedRealtimeEndpoint(
            session,
            frames: Array(repeating: realtimeSilenceFrame(), count: 10)
                + Array(repeating: realtimeSpeechFrame(), count: 8)
        )
        let result = session.release()
        #expect(result == .tailWait(remainingMs: 30))

        feedRealtimeEndpoint(session, frames: [realtimeSilenceFrame()])
        let final = session.release()

        #expect(final == .committed)
        #expect(appendedSampleCount(sender) == realtimeEndpointGateConfig.samplesPerFrame * 19)
        #expect(sender.eventTypes.last == "input_audio_buffer.commit")
    }

    @Test func unfinishedPartialTranscriptRequestsLexicalTailWait() {
        let sender = FakeRealtimeVoiceEventSender()
        let lexicalPolicy = VoiceTurnEndpointPolicy(settings: VoiceTurnEndpointPolicy.Settings(
            minSpeechMs: 210,
            hangoverMs: 30,
            maxTailMs: 300,
            lexicalFragmentWaitMs: 120
        ))
        let session = RealtimeVoiceEndpointSession(
            localEndpointingEnabled: true,
            sender: sender,
            gateConfiguration: realtimeEndpointGateConfig,
            endpointPolicy: lexicalPolicy
        )
        sender.sendEvent(["type": "input_audio_buffer.clear"])

        feedRealtimeEndpoint(
            session,
            frames: Array(repeating: realtimeSpeechFrame(), count: 8)
                + [realtimeSilenceFrame()]
        )
        session.updatePartialTranscript("can you")

        #expect(session.release() == .tailWait(remainingMs: 120))

        session.updatePartialTranscript("can you open Keynote")

        #expect(session.release() == .committed)
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
