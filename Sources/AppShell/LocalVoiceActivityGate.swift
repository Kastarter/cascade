import Foundation

/// Pure Swift local turn gate for push-to-talk audio.
///
/// This is intentionally heuristic-only for now: it rechunks already-converted PCM16
/// frames into turn state, keeps a prefix ring, and decides whether release should
/// clear, commit, or briefly wait for the speech tail. WebRTC/Silero can replace the
/// `isSpeechLike` rule later without changing the state machine.
public struct LocalVoiceActivityGate: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let sampleRate: Int
        public let frameDurationMs: Int
        public let prefixPaddingMs: Int
        public let minSpeechMs: Int
        public let hangoverMs: Int
        public let speechRMS: Double
        public let minSpeechPeak: Double
        public let impulsePeak: Double
        public let impulseCrestFactor: Double

        public init(
            sampleRate: Int = 24_000,
            frameDurationMs: Int = 30,
            prefixPaddingMs: Int = 300,
            minSpeechMs: Int = 210,
            hangoverMs: Int = 240,
            speechRMS: Double = 0.02,
            minSpeechPeak: Double = 0.05,
            impulsePeak: Double = 0.65,
            impulseCrestFactor: Double = 12
        ) {
            precondition(frameDurationMs == 20 || frameDurationMs == 30, "LocalVoiceActivityGate expects fixed 20 ms or 30 ms frames.")
            precondition(sampleRate > 0, "LocalVoiceActivityGate sampleRate must be positive.")
            self.sampleRate = sampleRate
            self.frameDurationMs = frameDurationMs
            self.prefixPaddingMs = max(0, prefixPaddingMs)
            self.minSpeechMs = max(frameDurationMs, minSpeechMs)
            self.hangoverMs = max(0, hangoverMs)
            self.speechRMS = speechRMS
            self.minSpeechPeak = minSpeechPeak
            self.impulsePeak = impulsePeak
            self.impulseCrestFactor = impulseCrestFactor
        }

        public var samplesPerFrame: Int {
            sampleRate * frameDurationMs / 1_000
        }

        var prefixFrameCapacity: Int {
            guard prefixPaddingMs > 0 else { return 0 }
            return Int(ceil(Double(prefixPaddingMs) / Double(frameDurationMs)))
        }
    }

    public enum FrameKind: Equatable, Sendable {
        case silence
        case impulse
        case candidateSpeech
        case confirmedSpeech
        case invalidFrame
    }

    public enum ReleaseDecision: Equatable, Sendable {
        case clear
        case commit
        case tailWait(remainingMs: Int)
    }

    public struct FrameResult: Equatable, Sendable {
        public let kind: FrameKind
        public let isSpeechLike: Bool
        public let didConfirmSpeech: Bool
        public let uploadFrames: [[Int16]]
        public let snapshot: Snapshot

        public var shouldUpload: Bool { !uploadFrames.isEmpty }
        public var uploadedAudioMs: Int { uploadFrames.count * snapshot.frameDurationMs }
    }

    public struct Snapshot: Equatable, Sendable {
        public let frameDurationMs: Int
        public let totalMs: Int
        public let prefixBufferedMs: Int
        public let candidateSpeechMs: Int
        public let confirmedSpeechMs: Int
        public let uploadedSpeechMs: Int
        public let uploadedAudioMs: Int
        public let trailingSilenceMs: Int
        public let releaseDecision: ReleaseDecision
    }

    public let configuration: Configuration

    private var prefixFrames: [[Int16]] = []
    private var candidateFrames: [[Int16]] = []
    private var totalMs = 0
    private var candidateSpeechMs = 0
    private var confirmedSpeechMs = 0
    private var uploadedSpeechMs = 0
    private var uploadedAudioMs = 0
    private var trailingSilenceMs = 0
    private var hasConfirmedSpeech = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var snapshot: Snapshot {
        Snapshot(
            frameDurationMs: configuration.frameDurationMs,
            totalMs: totalMs,
            prefixBufferedMs: prefixFrames.count * configuration.frameDurationMs,
            candidateSpeechMs: candidateSpeechMs,
            confirmedSpeechMs: confirmedSpeechMs,
            uploadedSpeechMs: uploadedSpeechMs,
            uploadedAudioMs: uploadedAudioMs,
            trailingSilenceMs: trailingSilenceMs,
            releaseDecision: releaseDecision()
        )
    }

    public mutating func reset() {
        prefixFrames.removeAll(keepingCapacity: true)
        candidateFrames.removeAll(keepingCapacity: true)
        totalMs = 0
        candidateSpeechMs = 0
        confirmedSpeechMs = 0
        uploadedSpeechMs = 0
        uploadedAudioMs = 0
        trailingSilenceMs = 0
        hasConfirmedSpeech = false
    }

    public mutating func ingestPCM16Frame(_ data: Data) -> FrameResult {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return ingestPCM16Frame(samples)
    }

    public mutating func ingestPCM16Frame(_ samples: [Int16]) -> FrameResult {
        guard samples.count == configuration.samplesPerFrame else {
            return FrameResult(
                kind: .invalidFrame,
                isSpeechLike: false,
                didConfirmSpeech: false,
                uploadFrames: [],
                snapshot: snapshot
            )
        }

        totalMs += configuration.frameDurationMs

        let features = Self.features(samples)
        let isImpulse = features.peak >= configuration.impulsePeak
            && features.crestFactor >= configuration.impulseCrestFactor
        let isSpeechLike = features.rms >= configuration.speechRMS
            && features.peak >= configuration.minSpeechPeak
            && !isImpulse

        if isSpeechLike {
            return ingestSpeechFrame(samples)
        } else {
            return ingestNonSpeechFrame(samples, kind: isImpulse ? .impulse : .silence)
        }
    }

    public func releaseDecision() -> ReleaseDecision {
        guard hasConfirmedSpeech, uploadedSpeechMs >= configuration.minSpeechMs else {
            return .clear
        }
        guard trailingSilenceMs < configuration.hangoverMs else {
            return .commit
        }
        return .tailWait(remainingMs: configuration.hangoverMs - trailingSilenceMs)
    }

    private mutating func ingestSpeechFrame(_ samples: [Int16]) -> FrameResult {
        var uploadFrames: [[Int16]] = []
        var didConfirmSpeech = false

        if hasConfirmedSpeech {
            trailingSilenceMs = 0
            confirmedSpeechMs += configuration.frameDurationMs
            uploadedSpeechMs += configuration.frameDurationMs
            uploadedAudioMs += configuration.frameDurationMs
            uploadFrames = [samples]
        } else {
            candidateFrames.append(samples)
            candidateSpeechMs += configuration.frameDurationMs

            if candidateSpeechMs >= configuration.minSpeechMs {
                hasConfirmedSpeech = true
                didConfirmSpeech = true
                trailingSilenceMs = 0
                confirmedSpeechMs = candidateSpeechMs
                uploadedSpeechMs += candidateSpeechMs
                uploadFrames = prefixFrames + candidateFrames
                uploadedAudioMs += uploadFrames.count * configuration.frameDurationMs
                prefixFrames.removeAll(keepingCapacity: true)
                candidateFrames.removeAll(keepingCapacity: true)
                candidateSpeechMs = 0
            }
        }

        return FrameResult(
            kind: hasConfirmedSpeech ? .confirmedSpeech : .candidateSpeech,
            isSpeechLike: true,
            didConfirmSpeech: didConfirmSpeech,
            uploadFrames: uploadFrames,
            snapshot: snapshot
        )
    }

    private mutating func ingestNonSpeechFrame(_ samples: [Int16], kind: FrameKind) -> FrameResult {
        var uploadFrames: [[Int16]] = []

        if hasConfirmedSpeech {
            trailingSilenceMs += configuration.frameDurationMs
            if trailingSilenceMs <= configuration.hangoverMs {
                uploadFrames = [samples]
                uploadedAudioMs += configuration.frameDurationMs
            }
        } else {
            candidateFrames.removeAll(keepingCapacity: true)
            candidateSpeechMs = 0
            appendPrefixFrame(samples)
        }

        return FrameResult(
            kind: kind,
            isSpeechLike: false,
            didConfirmSpeech: false,
            uploadFrames: uploadFrames,
            snapshot: snapshot
        )
    }

    private mutating func appendPrefixFrame(_ samples: [Int16]) {
        guard configuration.prefixFrameCapacity > 0 else { return }
        prefixFrames.append(samples)
        if prefixFrames.count > configuration.prefixFrameCapacity {
            prefixFrames.removeFirst(prefixFrames.count - configuration.prefixFrameCapacity)
        }
    }

    private static func features(_ samples: [Int16]) -> (rms: Double, peak: Double, crestFactor: Double) {
        guard !samples.isEmpty else { return (0, 0, 0) }

        var sumSquares = 0.0
        var peak = 0.0
        for sample in samples {
            let normalized = Double(abs(Int(sample))) / 32_768.0
            sumSquares += normalized * normalized
            peak = max(peak, normalized)
        }

        let rms = sqrt(sumSquares / Double(samples.count))
        return (rms, peak, rms > 0 ? peak / rms : 0)
    }
}
