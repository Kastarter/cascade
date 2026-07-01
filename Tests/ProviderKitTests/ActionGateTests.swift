import Foundation
import Testing

import CascadeMemory
@testable import ProviderKit

/// Pins the structural gates added after the Keynote title-page incident
/// (2026-06-11): the agent pressed a bare cmd+v (pasting the USER's clipboard
/// into the title), undid its own real text, then "repaired" the slide with an
/// AppleScript while the user watched — both moves were prompt-banned, and
/// neither ban held. These gates make the bans structural.
struct ActionGateTests {
    @Test func pasteCombosAreRecognizedAcrossModifierSpellings() {
        #expect(ComputerUseAgent.isPasteCombo("cmd+v"))
        #expect(ComputerUseAgent.isPasteCombo("command+v"))
        #expect(ComputerUseAgent.isPasteCombo("ctrl+v"))
        #expect(ComputerUseAgent.isPasteCombo("CMD+V"))
        // paste-and-match-style is still the user's clipboard
        #expect(ComputerUseAgent.isPasteCombo("shift+cmd+v"))
        #expect(!ComputerUseAgent.isPasteCombo("cmd+c"))
        #expect(!ComputerUseAgent.isPasteCombo("v"))
        #expect(!ComputerUseAgent.isPasteCombo("shift+v"))
        #expect(!ComputerUseAgent.isPasteCombo("cmd+shift+4"))
    }

    @Test func copyAndCutCombosUnlockTheClipboard() {
        #expect(ComputerUseAgent.isCopyCombo("cmd+c"))
        #expect(ComputerUseAgent.isCopyCombo("cmd+x"))
        #expect(ComputerUseAgent.isCopyCombo("ctrl+c"))
        #expect(!ComputerUseAgent.isCopyCombo("cmd+v"))
        #expect(!ComputerUseAgent.isCopyCombo("c"))
    }

    @Test func clipboardGoalsAllowBarePaste() {
        #expect(ComputerUseAgent.goalMentionsClipboard("paste my clipboard into Notes"))
        #expect(ComputerUseAgent.goalMentionsClipboard("copy the table into Numbers"))
        #expect(ComputerUseAgent.goalMentionsClipboard("insert what I copied"))
        // The incident goal — no clipboard wording, paste stays gated.
        #expect(!ComputerUseAgent.goalMentionsClipboard("title page for market entry readout for Cascade"))
        #expect(!ComputerUseAgent.goalMentionsClipboard("make a donut in Blender"))
    }

    @Test func appleScriptTargetsAreExtractedFromTellBlocks() {
        let incident = """
        tell application "Keynote"
            tell front document
                tell slide 1
                    set object text of text item 1 to "CascadeSkills Market Entry Readout"
                end tell
            end tell
        end tell
        """
        #expect(AgentHarness.scriptedAppTargets(in: incident) == ["Keynote"])
        #expect(AgentHarness.scriptedAppTargets(in: #"tell app "Finder" to reveal it"#) == ["Finder"])
        // Keynote 15.x scripts address the app by bundle id (the app's NAME
        // isn't "Keynote" on this Mac) — the id's last component is the target.
        #expect(AgentHarness.scriptedAppTargets(in: #"tell application id "com.apple.Keynote" to activate"#) == ["Keynote"])
    }

    @Test func plainShellCommandsNameNoScriptTargets() {
        #expect(AgentHarness.scriptedAppTargets(in: "ls -la ~/Desktop").isEmpty)
        #expect(AgentHarness.scriptedAppTargets(in: "textutil -convert docx /tmp/t.txt").isEmpty)
    }

    // MARK: - Irreversible-action gate (default-off "look before you leap")

    @Test func irreversibleCombosAreRecognizedAcrossSpellings() {
        // Quit / log out (cmd+Q, cmd+shift+Q) — abandons the running task surface.
        #expect(ComputerUseAgent.isIrreversibleCombo("cmd+q"))
        #expect(ComputerUseAgent.isIrreversibleCombo("command+q"))
        #expect(ComputerUseAgent.isIrreversibleCombo("CMD+Q"))
        #expect(ComputerUseAgent.isIrreversibleCombo("cmd+shift+q"))
        // Force quit (cmd+option+esc), every option/esc spelling.
        #expect(ComputerUseAgent.isIrreversibleCombo("cmd+option+esc"))
        #expect(ComputerUseAgent.isIrreversibleCombo("cmd+alt+escape"))
        #expect(ComputerUseAgent.isIrreversibleCombo("cmd+opt+esc"))
        // Empty Trash (cmd+shift+Delete / Backspace) — no cmd+z.
        #expect(ComputerUseAgent.isIrreversibleCombo("cmd+shift+delete"))
        #expect(ComputerUseAgent.isIrreversibleCombo("command+shift+backspace"))
    }

    @Test func reversibleEditingKeysAreNeverGated() {
        // The gate is deliberately narrow — cmd+z covers in-document edits, and a
        // false positive here would block normal work.
        #expect(!ComputerUseAgent.isIrreversibleCombo("delete"))        // backspace while typing
        #expect(!ComputerUseAgent.isIrreversibleCombo("backspace"))
        #expect(!ComputerUseAgent.isIrreversibleCombo("cmd+delete"))    // delete-line / move-to-Trash (recoverable)
        #expect(!ComputerUseAgent.isIrreversibleCombo("cmd+w"))         // close window/tab — usually a dialog
        #expect(!ComputerUseAgent.isIrreversibleCombo("cmd+a"))
        #expect(!ComputerUseAgent.isIrreversibleCombo("cmd+s"))
        #expect(!ComputerUseAgent.isIrreversibleCombo("q"))             // a bare keystroke, not a quit
        #expect(!ComputerUseAgent.isIrreversibleCombo("shift+delete"))  // forward-delete, no cmd
        #expect(!ComputerUseAgent.isIrreversibleCombo("esc"))           // bare escape just dismisses
        #expect(!ComputerUseAgent.isIrreversibleCombo("option+esc"))    // no cmd — not force-quit
    }

    @Test func destructionGoalsStandTheGateDown() {
        // The user's own words sanction the action — the gate must stand down, just
        // as a clipboard goal unlocks a bare paste.
        #expect(ComputerUseAgent.goalMentionsDestruction("quit Slack when you're done"))
        #expect(ComputerUseAgent.goalMentionsDestruction("close the extra windows"))
        #expect(ComputerUseAgent.goalMentionsDestruction("empty the trash"))
        #expect(ComputerUseAgent.goalMentionsDestruction("delete the old screenshots"))
        #expect(ComputerUseAgent.goalMentionsDestruction("log me out of every account"))
        // Ordinary build/edit goals carry no such sanction — the gate stays armed.
        #expect(!ComputerUseAgent.goalMentionsDestruction("title page for the market entry readout"))
        #expect(!ComputerUseAgent.goalMentionsDestruction("make a donut in Blender"))
        #expect(!ComputerUseAgent.goalMentionsDestruction("summarize today's meetings into Notes"))
    }

    @Test func actionCriticTriggersOnPowerHarnessAndAmbiguousGrounding() {
        #expect(ComputerUseAgent.shouldTriggerActionCritic(harnessToolName: "run_command"))
        #expect(ComputerUseAgent.shouldTriggerActionCritic(harnessToolName: "run_applescript"))
        #expect(ComputerUseAgent.shouldTriggerActionCritic(alternativeCount: 2))
        #expect(ComputerUseAgent.shouldTriggerActionCritic(lowConfidenceGrounding: true))
        #expect(ComputerUseAgent.shouldTriggerActionCritic(noEffectCount: 2))
        #expect(!ComputerUseAgent.shouldTriggerActionCritic(harnessToolName: "read_file"))
    }

    @Test func promptActionCriticParsesVerdictsAndFailureKind() {
        let critique = PromptActionCritic.parse("""
        {"verdict":"ask_user","reason":"Needs confirmation","saferInstruction":"Ask first","failureKind":"unsafe_action"}
        """)

        #expect(critique?.verdict == .askUser)
        #expect(critique?.reason == "Needs confirmation")
        #expect(critique?.saferInstruction == "Ask first")
        #expect(critique?.failureKind == CascadeMemory.AgentFailureKind.unsafeAction)
        #expect(PromptActionCritic.parse(#"{"verdict":"approve","reason":"ok"}"#)?.verdict == .approve)
    }

    @Test func preActionVerifierClassifiesRiskyHarnessURLAndGroundingSignals() {
        let shell = PreActionVerifier.verify(harnessToolName: "run_command")
        #expect(shell.risk == .high)
        #expect(shell.failureKind == .unsafeAction)
        #expect(shell.triggerReasons.contains("shell"))
        #expect(shell.triggerReasons.contains("power_harness_tool"))

        let write = PreActionVerifier.verify(harnessToolName: "write_file")
        #expect(write.risk == .high)
        #expect(write.failureKind == .unsafeAction)
        #expect(write.triggerReasons.contains("file_write"))

        let externalURL = PreActionVerifier.verify(action: .openURL("https://example.com/dashboard"))
        #expect(externalURL.risk == .high)
        #expect(externalURL.failureKind == .unsafeAction)
        #expect(externalURL.triggerReasons.contains("external_url"))

        let grounding = PreActionVerifier.verify(lowConfidenceGrounding: true, alternativeCount: 2)
        #expect(grounding.risk == .high)
        #expect(grounding.failureKind == .groundingMiss)
        #expect(grounding.triggerReasons.contains("low_confidence_grounding"))
        #expect(grounding.triggerReasons.contains("ambiguous_grounding"))
    }
}
