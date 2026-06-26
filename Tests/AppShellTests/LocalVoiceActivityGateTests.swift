import Foundation
import Testing

@testable import AppShell

private let config = LocalVoiceActivityGate.Configuration(
    sampleRate: 24_000,
    frameDurationMs: 30,
    prefixPaddingMs: 300,
    minSpeechMs: 210,
    hangoverMs: 240
)

private func silenceFrame(_ configuration: LocalVoiceActivityGate.Configuration = config) -> [Int16] {
    [Int16](repeating: 0, count: configuration.samplesPerFrame)
}

private func speechFrame(
    amplitude: Int16 = 8_000,
    configuration: LocalVoiceActivityGate.Configuration = config
) -> [Int16] {
    let quarter = max(1, configuration.samplesPerFrame / 4)
    return (0..<configuration.samplesPerFrame).map { index in
        switch (index / quarter) % 4 {
        case 0: return amplitude
        case 1: return amplitude / 2
        case 2: return -amplitude
        default: return -(amplitude / 2)
        }
    }
}

private func clickFrame(_ configuration: LocalVoiceActivityGate.Configuration = config) -> [Int16] {
    var frame = silenceFrame(configuration)
    frame[configuration.samplesPerFrame / 2] = 31_000
    return frame
}

@discardableResult
private func feed(
    _ gate: inout LocalVoiceActivityGate,
    frames: [[Int16]]
) -> LocalVoiceActivityGate.FrameResult? {
    var last: LocalVoiceActivityGate.FrameResult?
    for frame in frames {
        last = gate.ingestPCM16Frame(frame)
    }
    return last
}

struct LocalVoiceActivityGateTests {
    @Test func silenceClearsWithoutUploadingAudio() {
        var gate = LocalVoiceActivityGate(configuration: config)

        feed(&gate, frames: Array(repeating: silenceFrame(), count: 20))

        #expect(gate.releaseDecision() == .clear)
        #expect(gate.snapshot.uploadedSpeechMs == 0)
        #expect(gate.snapshot.uploadedAudioMs == 0)
        #expect(gate.snapshot.prefixBufferedMs == 300)
    }

    @Test func keyClickBurstClearsAsImpulseNoise() {
        var gate = LocalVoiceActivityGate(configuration: config)

        let last = feed(
            &gate,
            frames: [clickFrame(), clickFrame()] + Array(repeating: silenceFrame(), count: 6)
        )

        #expect(last?.kind == .silence)
        #expect(gate.releaseDecision() == .clear)
        #expect(gate.snapshot.uploadedSpeechMs == 0)
        #expect(gate.snapshot.uploadedAudioMs == 0)
    }

    @Test func shortCoughUnderMinimumSpeechClears() {
        var gate = LocalVoiceActivityGate(configuration: config)

        feed(
            &gate,
            frames: Array(repeating: speechFrame(amplitude: 14_000), count: 5)
                + Array(repeating: silenceFrame(), count: 8)
        )

        #expect(gate.releaseDecision() == .clear)
        #expect(gate.snapshot.confirmedSpeechMs == 0)
        #expect(gate.snapshot.uploadedSpeechMs == 0)
    }

    @Test func shortStopCommitsAfterHangoverSilence() {
        var gate = LocalVoiceActivityGate(configuration: config)

        feed(
            &gate,
            frames: Array(repeating: speechFrame(), count: 9)
                + Array(repeating: silenceFrame(), count: 10)
        )

        #expect(gate.releaseDecision() == .commit)
        #expect(gate.snapshot.confirmedSpeechMs == 270)
        #expect(gate.snapshot.uploadedSpeechMs == 270)
        #expect(gate.snapshot.trailingSilenceMs == 300)
    }

    @Test func normalCommandUploadsPrefixSpeechAndHangoverThenCommits() {
        var gate = LocalVoiceActivityGate(configuration: config)

        feed(
            &gate,
            frames: Array(repeating: silenceFrame(), count: 10)
                + Array(repeating: speechFrame(), count: 30)
                + Array(repeating: silenceFrame(), count: 10)
        )

        #expect(gate.releaseDecision() == .commit)
        #expect(gate.snapshot.uploadedSpeechMs == 900)
        #expect(gate.snapshot.uploadedAudioMs == 1_440)
        #expect(gate.snapshot.uploadedAudioMs > gate.snapshot.uploadedSpeechMs)
    }

    @Test func earlyReleaseWithTrailingPhonemeWaitsForTail() {
        var gate = LocalVoiceActivityGate(configuration: config)

        feed(&gate, frames: Array(repeating: speechFrame(), count: 8))

        #expect(gate.releaseDecision() == .tailWait(remainingMs: 240))
        #expect(gate.snapshot.uploadedSpeechMs == 240)
        #expect(gate.snapshot.trailingSilenceMs == 0)
    }

    @Test func twentyMillisecondFramesUseTheSameTurnGate() {
        let twentyMs = LocalVoiceActivityGate.Configuration(
            sampleRate: 24_000,
            frameDurationMs: 20,
            prefixPaddingMs: 100,
            minSpeechMs: 200,
            hangoverMs: 200
        )
        var gate = LocalVoiceActivityGate(configuration: twentyMs)

        feed(
            &gate,
            frames: Array(repeating: silenceFrame(twentyMs), count: 5)
                + Array(repeating: speechFrame(configuration: twentyMs), count: 12)
                + Array(repeating: silenceFrame(twentyMs), count: 10)
        )

        #expect(twentyMs.samplesPerFrame == 480)
        #expect(gate.releaseDecision() == .commit)
        #expect(gate.snapshot.uploadedSpeechMs == 240)
        #expect(gate.snapshot.uploadedAudioMs == 540)
    }
}
