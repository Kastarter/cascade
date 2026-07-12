import Foundation
import Testing

@testable import AppShell

private final class LockedDrainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RealtimeVoice.TranscriptionDrainResult?

    func set(_ result: RealtimeVoice.TranscriptionDrainResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: RealtimeVoice.TranscriptionDrainResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

struct RealtimeVoiceTranscriptionTrackerTests {
    @MainActor @Test func teachDrainCannotFinishBeforeTheClosingTailCommitExists() async {
        let voice = RealtimeVoice(audioEnabled: false)
        let sessionID = UUID()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: sessionID,
            automaticEndpointing: true
        )
        voice.transcriptionTracker.captureWillClose(purpose)

        let drainResult = LockedDrainResult()
        let drainTask = Task { @MainActor in
            let result = await voice.drainTranscriptions(
                forTeachingSession: sessionID,
                timeout: .seconds(1)
            )
            drainResult.set(result)
        }
        try? await Task.sleep(for: .milliseconds(10))
        #expect(drainResult.value == nil)

        voice.transcriptionTracker.noteCommit(from: purpose)
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "tail-item"])
        voice.transcriptionTracker.captureDidClose(purpose)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(drainResult.value == nil)

        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "tail-item",
            "transcript": "the final words",
        ])
        await drainTask.value
        #expect(drainResult.value == .drained)
    }

    @MainActor @Test func teachDrainWaitsForAllItemsAndDeliversFinalCallbackBeforeResuming() async {
        let voice = RealtimeVoice(audioEnabled: false)
        let sessionID = UUID()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: sessionID,
            automaticEndpointing: true
        )
        voice.transcriptionTracker.captureWillClose(purpose)
        voice.transcriptionTracker.noteCommit(from: purpose)
        voice.transcriptionTracker.noteCommit(from: purpose)
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "teach-1"])
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "teach-2"])
        voice.transcriptionTracker.captureDidClose(purpose)

        let drainResult = LockedDrainResult()
        let drainTask = Task { @MainActor in
            let result = await voice.drainTranscriptions(
                forTeachingSession: sessionID,
                timeout: .seconds(1)
            )
            drainResult.set(result)
        }
        var callbacks: [String] = []
        var finalCallbackSawDrainPending = false
        voice.onUtterance = { utterance in
            callbacks.append(utterance.text)
            if utterance.itemID == "teach-2" {
                finalCallbackSawDrainPending = drainResult.value == nil
            }
        }

        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "teach-1",
            "transcript": "first phrase",
        ])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(drainResult.value == nil)

        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "teach-2",
            "transcript": "final phrase",
        ])
        await drainTask.value

        #expect(callbacks == ["first phrase", "final phrase"])
        #expect(finalCallbackSawDrainPending)
        #expect(drainResult.value == .drained)
    }

    @MainActor @Test func transcriptionFailureSettlesPendingTeachDrain() async {
        let voice = RealtimeVoice(audioEnabled: false)
        let sessionID = UUID()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: sessionID,
            automaticEndpointing: true
        )
        voice.transcriptionTracker.captureWillClose(purpose)
        voice.transcriptionTracker.noteCommit(from: purpose)
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "failed-item"])
        voice.transcriptionTracker.captureDidClose(purpose)

        let task = Task { @MainActor in
            await voice.drainTranscriptions(forTeachingSession: sessionID, timeout: .seconds(1))
        }
        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.failed",
            "item_id": "failed-item",
        ])

        #expect(await task.value == .drained)
    }

    @MainActor @Test func timedOutDrainRetainsTeachPurposeForLateCompletion() async {
        let voice = RealtimeVoice(audioEnabled: false)
        let sessionID = UUID()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: sessionID,
            automaticEndpointing: true
        )
        voice.transcriptionTracker.captureWillClose(purpose)
        voice.transcriptionTracker.noteCommit(from: purpose)
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "late-item"])
        voice.transcriptionTracker.captureDidClose(purpose)

        let result = await voice.drainTranscriptions(
            forTeachingSession: sessionID,
            timeout: .milliseconds(10)
        )
        #expect(result == .timedOut)

        var delivered: RealtimeVoice.CompletedUtterance?
        voice.onUtterance = { delivered = $0 }
        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "late-item",
            "transcript": "the delayed narration",
        ])

        #expect(delivered?.purpose == purpose)
        #expect(delivered?.text == "the delayed narration")
    }

    @MainActor @Test func interleavedTeachAndPushToTalkItemsKeepDistinctPurposes() {
        let voice = RealtimeVoice(audioEnabled: false)
        let teachPurpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: UUID(),
            automaticEndpointing: true
        )
        voice.transcriptionTracker.noteCommit(from: teachPurpose)
        voice.transcriptionTracker.noteCommit(from: .pushToTalk)
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "teach"])
        voice.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "ptt"])

        var delivered: [String: RealtimeVoice.CapturePurpose] = [:]
        voice.onUtterance = { delivered[$0.itemID] = $0.purpose }
        // Completion order is deliberately the reverse of commit order.
        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "ptt",
            "transcript": "fresh command",
        ])
        voice.handleServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "teach",
            "transcript": "demo narration",
        ])

        #expect(delivered["teach"] == teachPurpose)
        #expect(delivered["ptt"] == .pushToTalk)
    }

    @Test func disconnectReleasesWaitersWithoutFabricatingUtterance() async {
        let tracker = RealtimeVoiceTranscriptionTracker()
        let sessionID = UUID()
        let purpose = RealtimeVoice.CapturePurpose.teachAmbient(
            sessionID: sessionID,
            automaticEndpointing: true
        )
        tracker.captureWillClose(purpose)
        tracker.noteCommit(from: purpose)

        let task = Task {
            await tracker.drain(teachingSessionID: sessionID, timeout: .seconds(1))
        }
        await Task.yield()
        tracker.disconnect()

        #expect(await task.value == .disconnected)
    }
}
