import CoreGraphics
import Foundation

/// Locates an on-screen element by description and returns its click point in
/// MODEL-PIXEL space (top-left origin, the resolution the agent's computer tool
/// declares). This is the GROUNDING half of the planner/grounder split the
/// GUI-agent literature converges on: a focused, single-purpose "where is X"
/// call is measurably more accurate than a generalist planner producing
/// coordinates inline (SeeAct-V, OS-Atlas, Agent-S2 Mixture-of-Grounding). It is
/// also the macOS CANVAS answer — the 2026-06-22 audit proved Keynote/Blender
/// expose only chrome to AX, so the slide placeholders can ONLY be grounded
/// visually.
///
/// The protocol is the swap seam: `ClaudeVisualGrounder` works today (frontier
/// vision call); a local MLX grounder (UGround-2B / UI-TARS-1.5-7B) drops in
/// later to remove the per-find frontier call — the downgrade lever.
public protocol VisualGrounder: Sendable {
    /// Center of `target` in model-pixel coords (top-left, AgentResolution.best
    /// for the display), or nil if it isn't confidently visible.
    func locate(
        target: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint?
}

/// Claude-vision grounder: wraps `ElementLocator`'s forced-`computer`-tool call
/// (which activates Claude's pixel-counting training and always returns a
/// coordinate) and converts the result into model-pixel space so the planner can
/// click it directly.
public struct ClaudeVisualGrounder: VisualGrounder {
    private let locator: ElementLocator

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), model: String = AnthropicModel.sonnet) {
        self.locator = ElementLocator(keyStore: keyStore, model: model)
    }

    public func locate(
        target: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        let guidance = await locator.guide(
            screenshot: screenshot,
            question: "Point to \(target) and click its exact center.",
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        guard let appKit = guidance.point else { return nil }
        return Self.modelPixel(
            fromDisplayAppKit: appKit,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        )
    }

    /// Display-local AppKit (bottom-left) → model-pixel (top-left,
    /// AgentResolution.best). The exact inverse of ElementLocator's own scaling,
    /// so the round trip recovers the resolution pixel the model needs. Pure +
    /// unit-tested — a wrong flip here sends the agent clicking the wrong row.
    static func modelPixel(
        fromDisplayAppKit point: CGPoint, displayWidthPoints: Int, displayHeightPoints: Int
    ) -> CGPoint {
        guard displayWidthPoints > 0, displayHeightPoints > 0 else { return .zero }
        let res = AgentResolution.best(forWidth: displayWidthPoints, height: displayHeightPoints)
        let fx = point.x / Double(displayWidthPoints)
        let fyFromBottom = point.y / Double(displayHeightPoints)
        return CGPoint(
            x: fx * Double(res.w),
            y: (1 - fyFromBottom) * Double(res.h)   // bottom-left fraction → top-left pixel
        )
    }
}
