import Foundation
import Testing

@testable import ProviderKit

/// d18: the canvas grounder (self-hosted UI-Venus-1.5) activates ONLY on an
/// explicit self-host endpoint. The shipped default and every misconfiguration
/// resolve to nil, so the baseline (UI-TARS) keeps owning all visual calls —
/// and NO code path may assume OpenRouter hosts UI-Venus.
struct GrounderRegistryCanvasTests {
    private let selfHostEndpoint = "http://192.168.4.20:8500/v1/chat/completions"

    @Test func noExplicitEndpointMeansNoCanvasGrounder() {
        // No silent localhost fallback: an assumed-but-absent local server
        // would add a failing round trip to every canvas target.
        #expect(GrounderRegistry.makeCanvasGrounder(endpoint: nil) == nil)
        #expect(GrounderRegistry.makeCanvasGrounder(endpoint: "") == nil)
        #expect(GrounderRegistry.makeCanvasGrounder(endpoint: "   ") == nil)
    }

    @Test func openRouterEndpointsAreRefused() {
        // No reliable OpenRouter deployment serves UI-Venus; routing there
        // would ground with the wrong model.
        #expect(GrounderRegistry.makeCanvasGrounder(endpoint: GrounderRegistry.defaultHostedEndpoint) == nil)
        #expect(GrounderRegistry.makeCanvasGrounder(
            endpoint: "https://openrouter.ai/api/v1/chat/completions"
        ) == nil)
        #expect(GrounderRegistry.makeCanvasGrounder(
            endpoint: "https://gateway.openrouter.ai/api/v1/chat/completions"
        ) == nil)
    }

    @Test func explicitSelfHostEndpointBuildsTheGrounder() {
        let grounder = GrounderRegistry.makeCanvasGrounder(endpoint: selfHostEndpoint)
        // The narrow contract rides the existing OpenAI-compatible client.
        #expect((grounder as? UITARSGrounder) != nil)
    }

    @Test func canvasPresetIsUIVenusAndBaselineStaysUITARS() {
        #expect(GrounderRegistry.canvasPresetID == "ui-venus")
        #expect(GrounderRegistry.defaultPresetID == "ui-tars")
        let preset = GrounderRegistry.preset(id: GrounderRegistry.canvasPresetID)
        // Self-host (byo) + sent-image coordinates: the Qwen3-VL convention the
        // plan-doc contract pins.
        #expect(preset.endpointClass == .byo)
        #expect(preset.coordinateSpace == .sent)
        // nil / unknown preset ids resolve to the UI-Venus canvas preset, not
        // to the hosted baseline.
        #expect(GrounderRegistry.makeCanvasGrounder(presetID: nil, endpoint: selfHostEndpoint) != nil)
    }

    @Test func hostedAndClaudePresetsAreNotCanvasGrounders() {
        // The canvas contract is a self-host point-grounding endpoint; the
        // hosted baseline and the Claude locator never take this slot.
        #expect(GrounderRegistry.makeCanvasGrounder(presetID: "ui-tars", endpoint: selfHostEndpoint) == nil)
        #expect(GrounderRegistry.makeCanvasGrounder(presetID: "claude", endpoint: selfHostEndpoint) == nil)
    }
}
