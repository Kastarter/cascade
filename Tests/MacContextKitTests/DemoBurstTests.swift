import CascadeMemory
import Foundation
import Testing

@testable import MacContextKit

// Teach-once demo burst: while the user demonstrates a task, the rewind stream
// runs denser (2fps, 0.5s persistence gap, tighter dedup) so transient demo
// states become moments. These pins hold the burst contract without a live stream.

@Test
func demoBurstTightensCadenceAndDedup() {
    let mode = RewindRecorder.demoBurstParameters(baseFPS: 1, baseThreshold: 6, burst: true)
    #expect(mode.fps == 2)
    #expect(mode.threshold == 2)
    #expect(mode.heartbeatGap == 0.5)
}

@Test
func demoBurstOffPassesBaseParametersThrough() {
    let mode = RewindRecorder.demoBurstParameters(baseFPS: 1, baseThreshold: 6, burst: false)
    #expect(mode.fps == 1)
    #expect(mode.threshold == 6)
    #expect(mode.heartbeatGap == CaptureScheduler.streamHeartbeatInterval)
}

@Test
func demoBurstNeverLoosensAnAlreadyDenseRecorder() {
    // Burst is a floor on density, never a ceiling: a recorder configured denser
    // than the burst keeps its own rate and its own tighter dedup.
    let mode = RewindRecorder.demoBurstParameters(baseFPS: 4, baseThreshold: 1, burst: true)
    #expect(mode.fps == 4)
    #expect(mode.threshold == 1)
    #expect(mode.heartbeatGap == 0.5)
}

@MainActor @Test
func contextRecorderRemembersDemoBurstWhileRecordingIsOff() throws {
    // The facade records the DESIRED state even with no live stream (recording
    // off, or teach begun before the stream is up) — a recorder started
    // mid-demonstration must come up bursting.
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeDemoBurst-\(UUID().uuidString).sqlite").path
    let recorder = ContextRecorder(store: try CascadeStore(path: path))
    #expect(!recorder.demoBurstEnabled)
    recorder.setDemoBurst(true)
    #expect(recorder.demoBurstEnabled)
    recorder.setDemoBurst(false)
    #expect(!recorder.demoBurstEnabled)
}
