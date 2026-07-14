@testable import MacContextKit
import Testing

/// The OS tears the capture stream down at screen lock / display sleep, and a
/// restart attempted while the screen is still locked fails — so recovery must
/// keep retrying on a bounded backoff instead of giving up after one attempt.
/// These pins hold the backoff contract: quick first retries (a transient
/// display swap recovers in seconds), a 60s ceiling (a locked-overnight Mac
/// resumes recording within a minute of unlock), and safe clamping for any
/// attempt index.
struct RewindStreamRecoveryTests {
    @Test func recoveryBackoffDoublesFromFiveSecondsAndCapsAtSixty() {
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 0) == .seconds(5))
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 1) == .seconds(10))
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 2) == .seconds(20))
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 3) == .seconds(40))
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 4) == .seconds(60))
    }

    @Test func recoveryBackoffStaysCappedForeverAndClampsNegativeAttempts() {
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 5) == .seconds(60))
        #expect(RewindRecorder.streamRecoveryDelay(attempt: 100) == .seconds(60))
        #expect(RewindRecorder.streamRecoveryDelay(attempt: -3) == .seconds(5))
    }
}
