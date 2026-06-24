import AppKit
import ComputerUseKit
import Foundation
import ProviderKit

// MARK: - Mixture-of-grounding (Agent-S2's specialist routing)
//
// The grounding split (see VisualGrounder.swift) moves "where is X" out of the
// reasoning model into a dedicated grounder. Agent-S2's headline finding goes one
// step further: route each target to the RIGHT grounder instead of one visual
// model for everything. Cascade already harvests the frontmost app's accessibility
// tree (AXElementResolver) — for any labeled chrome control AX can see (buttons,
// menu items, fields, checkboxes), a structural match is FREE, EXACT, and immune
// to the OpenRouter transport flakiness that stalls UI-TARS. The visual grounder
// is uniquely needed only for what AX CANNOT see: canvas elements (Keynote/Pages
// slides, Blender, design tools) and custom-drawn controls.
//
// So this wrapper tries an AX structural match FIRST and falls back to the injected
// visual grounder (UI-TARS / Claude) on any miss. It is shared by BOTH on-screen
// paths (Scout and the Opus structural loop) through `assistGrounder()`, so it
// aligns them on the same, better grounding. It directly fixes the audited Scout
// failure at Keynote's "New Document" startup chooser — AX exposes that button, so
// it now grounds for free instead of round-tripping the flaky hosted grounder.
//
// SAFETY (the canvas case must not regress — it is why the visual grounder exists):
//  • Apps whose AX tree Cascade explicitly distrusts (`axUnreliable`: Blender,
//    Figma, Photoshop) skip AX entirely — the visual grounder owns them.
//  • Only ACTIONABLE-role matches are trusted (a button/field/menu item, never a
//    static-text label or image), so naming "the title" can't hijack a chrome
//    "Title" label when the canvas placeholder is meant — that falls to visual.
//  • A match must score ≥ `minAXScore` (exact, or one string contains the other),
//    never a weak word-overlap, and must land on the captured display.
//  • The no-effect detector remains the backstop: a wrong AX click is caught and
//    re-grounded exactly like a wrong visual click.
// Toggle off with `cascade.mixtureGrounding = false` to A/B against pure visual.
// See [[cascade-cu-downgrade-research]].

/// A `VisualGrounder` that resolves a named target structurally (accessibility
/// tree) when it can, and defers to a visual grounder otherwise.
public struct MixtureGrounder: VisualGrounder {
    private let base: any VisualGrounder
    private let skills: AppSkillRegistry
    /// Minimum AX label-match score to TRUST a structural hit: 2 = one string
    /// contains the other (e.g. "the Save button" ⊇ "Save"); 3 = exact. Below
    /// this is only fuzzy word-overlap — defer to the visual grounder rather than
    /// risk a confident click on a vague match.
    private let minAXScore: Double

    /// AX roles a CLICK target may legitimately resolve to. Excludes the passive
    /// roles `AXElementResolver.find` will also match (AXStaticText, AXImage) — a
    /// label of static text is almost never the thing to click, and trusting it
    /// would let "the title" grab a chrome label instead of the canvas placeholder.
    /// Cascade's own bundle id — its UI must never be an AX grounding target.
    static let cascadeBundleID = "com.humain.cascade"

    static let clickableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField",
        "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXSlider",
    ]

    public init(base: any VisualGrounder, skills: AppSkillRegistry, minAXScore: Double = 2) {
        self.base = base
        self.skills = skills
        self.minAXScore = minAXScore
    }

    public func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        if let axPoint = await axGround(
            target: target, displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ) {
            return axPoint
        }
        return await base.ground(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        )
    }

    /// Region grounding (the "where is X" highlight) stays the base grounder's job —
    /// a marquee frames an area, which the visual grounder produces and AX point
    /// matching does not improve.
    public func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? {
        await base.groundRegion(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        )
    }

    /// Resolve `target` against the frontmost app's accessibility tree, returning a
    /// display-local AppKit point (the executor's space) — or nil to fall back to
    /// the visual grounder. AX/NSWorkspace/NSScreen are main-thread surfaces, so the
    /// whole resolve runs on the MainActor.
    @MainActor
    private func axGround(target: String, displayWidthPoints: Int, displayHeightPoints: Int) -> CGPoint? {
        // Canvas concepts are visual-only: a target named as a "placeholder" or
        // "canvas" element (Keynote/Pages slide boxes, drawing surfaces) has no
        // faithful AX node, but a short generic chrome label CAN substring-match it
        // (naming "the title placeholder" would hijack a Format-panel "Title"
        // checkbox — actionable, and toggling it even defeats the no-effect
        // backstop). Such targets go straight to the visual grounder. General, not
        // app-specific: these words denote a drawn surface in any app.
        if Self.namesCanvasConcept(target) { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        // NEVER ground Cascade's OWN UI. When Cascade's window is frontmost, AX-first
        // reads ITS tree and matches Cascade's buttons/fields (the audited
        // "Agents"/"Create new…" hijack) — the agent then clicks and types into
        // Cascade instead of the target app behind it (the "can't type" report). The
        // captured screenshot excludes Cascade's own windows, so the visual grounder
        // sees the real target — defer to it.
        if front?.bundleIdentifier == Self.cascadeBundleID { return nil }
        // Distrusted-AX apps (canvas/Electron) are the visual grounder's domain.
        if let skill = skills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier),
           skill.axUnreliable {
            return nil
        }
        guard let match = AXElementResolver.find(label: target),
              match.score >= minAXScore,
              Self.clickableRoles.contains(match.role) else { return nil }
        // Map the matched element center (CG-global, top-left) into the display-local
        // AppKit point the executor consumes. Use the display the screenshot came
        // from — the cursor's — selected by matching the declared dimensions.
        guard let bounds = Self.captureDisplayBounds(widthPoints: displayWidthPoints, heightPoints: displayHeightPoints) else {
            return nil
        }
        return Self.displayLocalPoint(
            cgGlobalCenter: match.center, displayCGBounds: bounds, displayHeightPoints: displayHeightPoints
        )
    }

    /// Words that denote a drawn surface with no faithful accessibility node, so a
    /// target naming one must be grounded visually, not by AX label match. Pure +
    /// pinned. Kept tiny and generic — these are not app-specific UI labels.
    nonisolated static func namesCanvasConcept(_ target: String) -> Bool {
        let t = target.lowercased()
        return t.contains("placeholder") || t.contains("canvas")
    }

    /// CG-global top-left element center → display-local AppKit point (bottom-left
    /// origin), mirroring `ElementLocator.guide` / `UITARSGrounder.toDisplayPoint`
    /// so an AX point and a visual point feed the IDENTICAL click path. Returns nil
    /// when the center isn't on the captured display (off-screen / another monitor),
    /// so a stray match never clicks blind. Pure + unit-pinned — a wrong number here
    /// clicks empty space.
    nonisolated static func displayLocalPoint(
        cgGlobalCenter c: CGPoint, displayCGBounds bounds: CGRect, displayHeightPoints: Int
    ) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0,
              c.x >= bounds.minX - 1, c.x <= bounds.maxX + 1,
              c.y >= bounds.minY - 1, c.y <= bounds.maxY + 1 else { return nil }
        let localX = c.x - bounds.minX
        let localYFromTop = c.y - bounds.minY
        let localYFromBottom = CGFloat(displayHeightPoints) - localYFromTop
        return CGPoint(x: localX, y: localYFromBottom)
    }

    /// CG-global bounds of the display the screenshot came from. The capture path is
    /// always the cursor's display, so prefer the screen under the mouse; among
    /// screens the dimensions must still match the declared size (so a coordinate is
    /// never mapped against the wrong monitor). nil → caller falls back to visual.
    @MainActor
    private static func captureDisplayBounds(widthPoints: Int, heightPoints: Int) -> CGRect? {
        func dims(_ s: NSScreen) -> Bool {
            Int(s.frame.width.rounded()) == widthPoints && Int(s.frame.height.rounded()) == heightPoints
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { dims($0) && NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first(where: dims)
        guard let screen else { return nil }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return CGDisplayBounds(id ?? CGMainDisplayID())
    }
}
