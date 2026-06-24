import Foundation
import Testing

@testable import ProviderKit

/// Pins the Scout brain's contract with the runtime — parsing the model's JSON
/// action (the part that, if wrong, drives the wrong action). The live loop is
/// runtime-unverified (no Scout/UI-TARS in CI). See [[cascade-cu-downgrade-research]].
struct ScoutAgentTests {
    @Test func parsesClickWithNamedTarget() {
        let a = ScoutAgent.parseScoutAction(#"{"thought":"open it","action":"click","target":"the Save button"}"#)
        #expect(a?.kind == .click)
        #expect(a?.target == "the Save button")
        #expect(a?.thought == "open it")
    }

    @Test func parsesTypeWithTargetAndText() {
        let a = ScoutAgent.parseScoutAction(#"{"action":"type","target":"the subtitle placeholder","text":"Market Entry"}"#)
        #expect(a?.kind == .type)
        #expect(a?.target == "the subtitle placeholder")
        #expect(a?.text == "Market Entry")
    }

    @Test func parsesKeyAndScroll() {
        #expect(ScoutAgent.parseScoutAction(#"{"action":"key","key":"cmd+s"}"#)?.key == "cmd+s")
        let s = ScoutAgent.parseScoutAction(#"{"action":"scroll","direction":"down","amount":5}"#)
        #expect(s?.kind == .scroll)
        #expect(s?.direction == "down")
        #expect(s?.amount == 5)
    }

    @Test func parsesDoneWithReason() {
        let a = ScoutAgent.parseScoutAction(#"{"action":"done","thought":"the title slide is filled"}"#)
        #expect(a?.kind == .done)
        #expect(a?.thought == "the title slide is filled")
    }

    @Test func toleratesCodeFencesAndProse() {
        let fenced = "Here's my action:\n```json\n{\"action\":\"click\",\"target\":\"X\"}\n```"
        #expect(ScoutAgent.parseScoutAction(fenced)?.target == "X")
    }

    @Test func mapsActionAliases() {
        #expect(ScoutAgent.parseScoutAction(#"{"action":"left_click","target":"x"}"#)?.kind == .click)
        #expect(ScoutAgent.parseScoutAction(#"{"action":"double_click","target":"x"}"#)?.kind == .doubleClick)
        #expect(ScoutAgent.parseScoutAction(#"{"action":"goto","target":"https://x.com"}"#)?.kind == .openURL)
        #expect(ScoutAgent.parseScoutAction(#"{"action":"finish"}"#)?.kind == .done)
    }

    @Test func emptyTargetBecomesNil() {
        let a = ScoutAgent.parseScoutAction(#"{"action":"type","target":"  ","text":"hi"}"#)
        #expect(a?.target == nil)
        #expect(a?.text == "hi")
    }

    @Test func unknownOrMissingActionIsNil() {
        #expect(ScoutAgent.parseScoutAction(#"{"action":"teleport","target":"x"}"#) == nil)
        #expect(ScoutAgent.parseScoutAction(#"{"thought":"no action here"}"#) == nil)
        #expect(ScoutAgent.parseScoutAction("not json at all") == nil)
    }

    // MARK: parseScoutActions — batched turns

    @Test func parsesBatchedActionsWithCarriedThought() {
        let r = #"{"thought":"fill the slide","actions":[{"action":"type","target":"title","text":"Hi"},{"action":"type","target":"subtitle","text":"Yo"}]}"#
        let a = ScoutAgent.parseScoutActions(r)
        #expect(a.count == 2)
        #expect(a[0].kind == .type && a[0].target == "title" && a[0].text == "Hi")
        #expect(a[1].target == "subtitle" && a[1].text == "Yo")
        // The outer thought is carried onto an element that lacks its own.
        #expect(a[0].thought == "fill the slide")
    }

    @Test func parseActionsHandlesSingleObject() {
        let a = ScoutAgent.parseScoutActions(#"{"action":"click","target":"Save"}"#)
        #expect(a.count == 1 && a[0].kind == .click && a[0].target == "Save")
    }

    @Test func perElementThoughtWinsOverOuter() {
        let r = #"{"thought":"outer","actions":[{"action":"key","key":"return","thought":"inner"}]}"#
        #expect(ScoutAgent.parseScoutActions(r).first?.thought == "inner")
    }

    @Test func parseActionsEmptyOnGarbage() {
        #expect(ScoutAgent.parseScoutActions("nope").isEmpty)
    }

    // MARK: parseRawActions — tool calls keep arbitrary input; tools aren't screen actions

    @Test func rawActionsKeepToolInputFields() {
        let r = #"{"action":"read_file","path":"~/x.txt"}"#
        let raw = ScoutAgent.parseRawActions(r)
        #expect(raw.count == 1)
        #expect(raw[0]["action"] as? String == "read_file")
        #expect(raw[0]["path"] as? String == "~/x.txt")
        // A tool call is NOT a screen action, so parseScoutActions drops it.
        #expect(ScoutAgent.parseScoutActions(r).isEmpty)
    }

    @Test func rawActionsBatchSkipsNonObjectElements() {
        let r = #"{"actions":[{"action":"click","target":"Save"}, 5, "x"]}"#
        let raw = ScoutAgent.parseRawActions(r)
        #expect(raw.count == 1 && raw[0]["target"] as? String == "Save")
    }
}
