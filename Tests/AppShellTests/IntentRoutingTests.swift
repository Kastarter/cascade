import Testing

@testable import AppShell

/// Pins the point-vs-act routing in teach(): "where is X" / "show me X" POINT at the
/// target (the dashed marquee), while an imperative "find X" / "find it for me" ACTS —
/// the agent navigates / opens / surfaces it. The bug this guards: "find " sat in the
/// point-trigger list, so every "find …" command just highlighted instead of doing it
/// (the audit showed "Find the syllabus" → teach.region, same as "Where is it?").
struct IntentRoutingTests {
    @Test func findIsAnActionNotAWhereIsPoint() {
        // Imperative "find X" → act (navigate / open / surface it).
        #expect(CascadeAppModel.isActionRequest("Find the syllabus for this course"))
        #expect(CascadeAppModel.isActionRequest("find it for me"))
        #expect(CascadeAppModel.isActionRequest("Find the freaking syllabus"))
        #expect(CascadeAppModel.isActionRequest("open settings and turn on dark mode"))
        // Locational "where…" / "show me" → point (highlight), unchanged.
        #expect(!CascadeAppModel.isActionRequest("where is it"))
        #expect(!CascadeAppModel.isActionRequest("where can I find the syllabus at"))
        #expect(!CascadeAppModel.isActionRequest("show me the send button"))
        // highlight / mark always route to the acting agent (it owns the tool).
        #expect(CascadeAppModel.isActionRequest("highlight the total"))
    }

    @Test func howToQuestionsAreInstructionalAnswersNotPointRequests() {
        #expect(CascadeAppModel.isInstructionalQuestion("how can I export a PDF"))
        #expect(CascadeAppModel.isInstructionalQuestion("how do I create a chart"))
        #expect(!CascadeAppModel.refersToScreen("how can I export a PDF"))
        #expect(!CascadeAppModel.refersToScreen("how do I create a chart"))
    }

    @Test func screenLocationQuestionsStillPointAtTheScreen() {
        #expect(CascadeAppModel.refersToScreen("where is the export button"))
        #expect(CascadeAppModel.refersToScreen("show me the settings menu"))
        #expect(CascadeAppModel.refersToScreen("locate the toolbar icon"))
    }
}
