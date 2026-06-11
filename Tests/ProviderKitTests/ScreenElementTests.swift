import Foundation
import Testing

@testable import ProviderKit

/// Pins the AX perception lane (read_screen_elements): the renderer's
/// coordinate mapping is the contract that makes AX-guided clicks land —
/// elements are reported in capture-screen points (top-left origin) and must
/// come out in screenshot pixels, the space the model clicks in. A silent
/// regression here would send every guided click to the wrong place.
struct ScreenElementTests {
    private func render(_ result: CUScreenElementsResult) -> String {
        // A 1440×900 screen captured at 1280×800 — the common laptop case.
        CUScreenElementRenderer.render(result, resW: 1280, resH: 800, displayW: 1440, displayH: 900)
    }

    @Test func centersScaleIntoScreenshotPixels() {
        let element = CUScreenElement(
            role: "AXButton", label: "Save", value: "", enabled: true,
            frame: CGRect(x: 710, y: 440, width: 20, height: 20)  // center (720, 450) in points
        )
        let output = render(.elements([element]))
        // 720 × 1280/1440 = 640; 450 × 800/900 = 400.
        #expect(output.contains("AXButton “Save” @(640,400)"))
        #expect(output.contains("18×18"))  // 20 points × scale ≈ 17.8 → 18 px
    }

    @Test func valuesAndDisabledStateRender() {
        let checkbox = CUScreenElement(
            role: "AXCheckBox", label: "Title", value: "0", enabled: true,
            frame: CGRect(x: 100, y: 100, width: 18, height: 18)
        )
        let grayed = CUScreenElement(
            role: "AXButton", label: "Paste", value: "", enabled: false,
            frame: CGRect(x: 100, y: 200, width: 60, height: 24)
        )
        let output = render(.elements([checkbox, grayed]))
        #expect(output.contains("AXCheckBox “Title” value=“0”"))
        #expect(output.contains("(disabled)"))
    }

    @Test func halfOffscreenCentersClampIntoTheScreenshot() {
        let element = CUScreenElement(
            role: "AXButton", label: "Edge", value: "", enabled: true,
            frame: CGRect(x: -40, y: -30, width: 20, height: 20)  // center off both edges
        )
        let output = render(.elements([element]))
        #expect(output.contains("@(0,0)"))
    }

    @Test func emptyTreeSaysCanvasNotSilence() {
        let output = render(.elements([]))
        #expect(output.contains("canvas"))
        #expect(output.contains("screenshot"))
    }

    @Test func unavailablePassesTheReasonThrough() {
        let output = render(.unavailable("Blender's accessibility tree is unreliable — work from the screenshot instead."))
        #expect(output == "Blender's accessibility tree is unreliable — work from the screenshot instead.")
    }

    @Test func longValuesClipAndFlatten() {
        let element = CUScreenElement(
            role: "AXTextArea", label: "Notes", value: String(repeating: "a", count: 300) + "\nsecond line",
            enabled: true, frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let output = render(.elements([element]))
        #expect(!output.contains(String(repeating: "a", count: 121)))
        #expect(output.contains("…"))
        // Newlines inside a value must not break the one-line-per-element contract.
        let elementLines = output.split(separator: "\n").filter { $0.contains("AXTextArea") }
        #expect(elementLines.count == 1)
    }

    @Test func oversizedListsTruncateLoudly() {
        let elements = (0..<400).map { index in
            CUScreenElement(
                role: "AXStaticText", label: "Row \(index) with some longer label text to fill the budget",
                value: "value \(index)", enabled: true,
                frame: CGRect(x: 10, y: Double(index), width: 200, height: 16)
            )
        }
        let output = render(.elements(elements))
        #expect(output.count < CUScreenElementRenderer.maxOutputChars + 200)
        #expect(output.contains("more elements truncated"))
    }

    @Test @MainActor func toolDefinitionAndNoteAgreeOnTheName() {
        let name = ComputerUseAgent.screenElementsToolDefinition["name"] as? String
        #expect(name == "read_screen_elements")
        #expect(ComputerUseAgent.axPerceptionNote.contains("read_screen_elements"))
        // The description must teach the coordinate contract — click the center.
        let description = ComputerUseAgent.screenElementsToolDefinition["description"] as? String ?? ""
        #expect(description.contains("screenshot coordinates"))
    }
}
