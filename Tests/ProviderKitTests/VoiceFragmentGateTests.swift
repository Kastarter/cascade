import Testing

@testable import ProviderKit

/// Pins the transcription noise gate against the REAL fragment corpus from the
/// 2026-06-11 audit log — every "noise" case below arrived as an assist.task
/// goal and spawned (or killed) a live screen-control run.
struct VoiceFragmentGateTests {
    @Test func realFragmentCorpusIsNoise() {
        for fragment in [
            "Iii!", "Hi", "Hi.", "Hello", "so.", "مريم.", "はあ", "。\"",
            "Okay, thank you.", "Ok, thank you.", "Hmm.", "Yeah, cool.",
        ] {
            #expect(VoiceFragmentGate.classify(fragment) == .noise, "should be noise: \(fragment)")
        }
    }

    @Test func realCommandsPassUnchanged() {
        for command in [
            "Open mail and reply to the falcon invoice email and say the payment is scheduled",
            "title page for market entry readout for Cascade",
            "Can you please open Word document and create an empty document for me?",
            "click that",
            "open the second one",
        ] {
            #expect(VoiceFragmentGate.classify(command) == .goal(command), "should pass: \(command)")
        }
    }

    @Test func danglingLeadInFillerIsStrippedNotRefused() {
        // "And create a slide…" killed nothing only because the prior run was
        // already dead — the command under the conjunction must survive.
        #expect(
            VoiceFragmentGate.classify("And create a slide market entry readout for Cascade.")
                == .goal("create a slide market entry readout for Cascade.")
        )
        #expect(
            VoiceFragmentGate.classify("Now, okay, can you please open a Word document for me?")
                == .goal("can you please open a Word document for me?")
        )
    }

    @Test func strippingNeverEatsTheWholeCommand() {
        // A goal that is mostly filler words still keeps its final two tokens —
        // the gate's noise check decides, not the stripper.
        #expect(VoiceFragmentGate.classify("so so so") == .noise)
        #expect(VoiceFragmentGate.classify("ok then now what") == .goal("now what"))
    }
}
