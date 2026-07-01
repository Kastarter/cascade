import Foundation
import Testing

@testable import AppShell

private func responsePCM16(samples: Int) -> Data {
    [Int16](repeating: 1_000, count: samples).withUnsafeBufferPointer { pointer in
        Data(buffer: pointer)
    }
}

private func eventTypes(_ events: [[String: Any]]) -> [String] {
    events.compactMap { $0["type"] as? String }
}

struct RealtimeVoiceResponseStateTests {
    @Test func bargeInEmitsTruncateBeforeCancel() {
        let state = RealtimeVoiceResponseState()
        state.noteOutputAudioDelta(
            event: ["type": "response.output_audio.delta", "item_id": "assistant-item-1"],
            pcmByteCount: responsePCM16(samples: 2_400).count
        )

        let events = state.bargeInEvents()

        #expect(eventTypes(events) == ["conversation.item.truncate", "response.cancel"])
        #expect(events[0]["item_id"] as? String == "assistant-item-1")
        #expect(events[0]["content_index"] as? Int == 0)
        #expect(events[0]["audio_end_ms"] as? Int == 100)
        #expect(!state.hasActiveResponse)
    }

    @Test func speakIsSingleFlightAndCancelsBeforeSecondCreate() {
        let state = RealtimeVoiceResponseState()

        let first = state.speechResponseEvents(for: "First")
        let second = state.speechResponseEvents(for: "Second")

        #expect(eventTypes(first) == ["response.create"])
        #expect(eventTypes(second) == ["response.cancel", "response.create"])
        #expect(state.responseInFlight)
    }

    @Test func responseCompletionClearsInFlightFlag() {
        let state = RealtimeVoiceResponseState()

        _ = state.speechResponseEvents(for: "Hello")
        #expect(state.responseInFlight)

        state.clear()

        #expect(!state.responseInFlight)
        #expect(!state.hasActiveResponse)
    }
}
