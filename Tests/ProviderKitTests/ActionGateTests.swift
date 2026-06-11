import Foundation
import Testing

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
}
