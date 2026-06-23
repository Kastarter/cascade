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
}
