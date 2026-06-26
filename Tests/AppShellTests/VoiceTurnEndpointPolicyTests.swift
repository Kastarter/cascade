import Foundation
import Testing

@testable import AppShell

private let settings = VoiceTurnEndpointPolicy.Settings(
    minSpeechMs: 210,
    hangoverMs: 240,
    maxTailMs: 600,
    lexicalFragmentWaitMs: 120
)

private let policy = VoiceTurnEndpointPolicy(settings: settings)

private func timing(
    nowMs: Int,
    keyDownAtMs: Int = 0,
    keyUpAtMs: Int?,
    speechStartedAtMs: Int?,
    lastSpeechAtMs: Int?,
    uploadedSpeechMs: Int,
    hasUnfinishedLexicalFragment: Bool = false
) -> VoiceTurnEndpointPolicy.Timing {
    VoiceTurnEndpointPolicy.Timing(
        nowMs: nowMs,
        keyDownAtMs: keyDownAtMs,
        keyUpAtMs: keyUpAtMs,
        speechStartedAtMs: speechStartedAtMs,
        lastSpeechAtMs: lastSpeechAtMs,
        uploadedSpeechMs: uploadedSpeechMs,
        hasUnfinishedLexicalFragment: hasUnfinishedLexicalFragment
    )
}

struct VoiceTurnEndpointPolicyTests {
    @Test func silenceClearsAfterRelease() {
        let decision = policy.decide(timing(
            nowMs: 400,
            keyUpAtMs: 400,
            speechStartedAtMs: nil,
            lastSpeechAtMs: nil,
            uploadedSpeechMs: 0
        ))

        #expect(decision == .clear)
    }

    @Test func keyTapClearsAfterRelease() {
        let decision = policy.decide(timing(
            nowMs: 40,
            keyUpAtMs: 40,
            speechStartedAtMs: nil,
            lastSpeechAtMs: nil,
            uploadedSpeechMs: 0
        ))

        #expect(decision == .clear)
    }

    @Test func shortCoughUnderMinimumSpeechClears() {
        let decision = policy.decide(timing(
            nowMs: 360,
            keyUpAtMs: 360,
            speechStartedAtMs: 80,
            lastSpeechAtMs: 160,
            uploadedSpeechMs: 150
        ))

        #expect(decision == .clear)
    }

    @Test func validSpeechCommitsAfterHangover() {
        let decision = policy.decide(timing(
            nowMs: 1_000,
            keyUpAtMs: 1_000,
            speechStartedAtMs: 100,
            lastSpeechAtMs: 700,
            uploadedSpeechMs: 600
        ))

        #expect(decision == .commitNow)
    }

    @Test func earlyPTTReleaseWaitsForTail() {
        let decision = policy.decide(timing(
            nowMs: 500,
            keyUpAtMs: 500,
            speechStartedAtMs: 120,
            lastSpeechAtMs: 470,
            uploadedSpeechMs: 360
        ))

        #expect(decision == .tailWait(remainingMs: 210))
    }

    @Test func staleTailCommitsAtMaxDuration() {
        let decision = policy.decide(timing(
            nowMs: 1_120,
            keyUpAtMs: 500,
            speechStartedAtMs: 120,
            lastSpeechAtMs: 470,
            uploadedSpeechMs: 360
        ))

        #expect(decision == .commitNow)
    }

    @Test func unfinishedLexicalFragmentRequestsShortWait() {
        let decision = policy.decide(timing(
            nowMs: 900,
            keyUpAtMs: 900,
            speechStartedAtMs: 100,
            lastSpeechAtMs: 500,
            uploadedSpeechMs: 420,
            hasUnfinishedLexicalFragment: true
        ))

        #expect(decision == .tailWait(remainingMs: 120))
    }

    @Test func ongoingKeyDownAppendsOnly() {
        let decision = policy.decide(timing(
            nowMs: 520,
            keyUpAtMs: nil,
            speechStartedAtMs: 100,
            lastSpeechAtMs: 500,
            uploadedSpeechMs: 420
        ))

        #expect(decision == .appendOnly)
    }
}
