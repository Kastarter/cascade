import CoreGraphics
import Foundation

public enum GrounderEndpointClass: String, Codable, Equatable, Sendable, CaseIterable {
    case hosted
    case local
    case byo
    case claude
}

public enum GrounderLicenseClass: String, Codable, Equatable, Sendable {
    case apache2 = "Apache-2.0"
    case mit = "MIT"
    case research = "research/check license"
    case proprietary = "proprietary"
    case unknown
}

public struct GrounderPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let modelID: String
    public let source: GroundingSource
    public let promptTemplate: String
    public let parser: String
    public let coordinateSpace: UITARSGrounder.CoordSpace
    public let endpointClass: GrounderEndpointClass
    public let modelSize: String
    public let quantization: String
    public let license: GrounderLicenseClass
    public let note: String

    public init(
        id: String,
        displayName: String,
        modelID: String,
        source: GroundingSource = .uiTars,
        promptTemplate: String = "click(start_box='(x,y)')",
        parser: String = "ui-tars-box",
        coordinateSpace: UITARSGrounder.CoordSpace,
        endpointClass: GrounderEndpointClass,
        modelSize: String,
        quantization: String,
        license: GrounderLicenseClass,
        note: String
    ) {
        self.id = id
        self.displayName = displayName
        self.modelID = modelID
        self.source = source
        self.promptTemplate = promptTemplate
        self.parser = parser
        self.coordinateSpace = coordinateSpace
        self.endpointClass = endpointClass
        self.modelSize = modelSize
        self.quantization = quantization
        self.license = license
        self.note = note
    }
}

public struct GrounderCoordinateProbe: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case passed
        case failed
        case parseMiss
    }

    public let status: Status
    public let expected: CGPoint
    public let actual: CGPoint?
    public let errorPoints: Double?
    public let coordSpace: UITARSGrounder.CoordSpace

    public init(
        status: Status,
        expected: CGPoint,
        actual: CGPoint?,
        errorPoints: Double?,
        coordSpace: UITARSGrounder.CoordSpace
    ) {
        self.status = status
        self.expected = expected
        self.actual = actual
        self.errorPoints = errorPoints
        self.coordSpace = coordSpace
    }
}

public enum GrounderRegistry {
    public static let defaultPresetID = "ui-tars"
    public static let defaultHostedEndpoint = "https://openrouter.ai/api/v1/chat/completions"

    public static let presets: [GrounderPreset] = [
        GrounderPreset(
            id: "ui-tars",
            displayName: "UI-TARS 1.5 7B",
            modelID: GUIGrounderModel.uiTars15_7b,
            coordinateSpace: .smartResize,
            endpointClass: .hosted,
            modelSize: "7B",
            quantization: "hosted / BYO",
            license: .apache2,
            note: "Default hosted visual grounder; Qwen2.5-VL smart-resize coordinates."
        ),
        GrounderPreset(
            id: "ui-venus",
            displayName: "UI-Venus 1.5 (canvas)",
            modelID: GUIGrounderModel.uiVenus15_8b,
            coordinateSpace: .sent,
            endpointClass: .byo,
            modelSize: "2B / 8B",
            quantization: "self-host (vLLM/SGLang)",
            license: .research,
            note: "d18 canvas grounder: self-host via vLLM/SGLang (crop+query → point/confidence); "
                + "sent-image coordinates. NOT on OpenRouter — see the endpoint contract in "
                + "docs/research/AX_FIRST_GROUNDING_PLAN.md."
        ),
        GrounderPreset(
            id: "gui-aima",
            displayName: "GUI-AIMA",
            modelID: "gui-aima-3b",
            coordinateSpace: .normalized,
            endpointClass: .byo,
            modelSize: "3B",
            quantization: "BYO host",
            license: .research,
            note: "Attention-anchor UI grounder preset; parser expects Qwen normalized points."
        ),
        GrounderPreset(
            id: "holo",
            displayName: "Holo 1.5",
            modelID: GUIGrounderModel.holo15_7b,
            coordinateSpace: .sent,
            endpointClass: .byo,
            modelSize: "3B / 7B",
            quantization: "BYO host",
            license: .research,
            note: "Hosted/BYO specialist candidate; verify license before redistribution."
        ),
        GrounderPreset(
            id: "showui",
            displayName: "ShowUI 2B",
            modelID: "showlab/ShowUI-2B",
            coordinateSpace: .normalized,
            endpointClass: .local,
            modelSize: "2B",
            quantization: "local/BYO",
            license: .apache2,
            note: "Local experiment candidate; normalized coordinate parser."
        ),
        GrounderPreset(
            id: "uground",
            displayName: "UGround",
            modelID: "osunlp/UGround",
            coordinateSpace: .normalized,
            endpointClass: .byo,
            modelSize: "varies",
            quantization: "BYO host",
            license: .research,
            note: "BYO endpoint only; no bundled weights."
        ),
        GrounderPreset(
            id: "os-atlas",
            displayName: "OS-Atlas",
            modelID: "OS-Copilot/OS-Atlas-4B",
            coordinateSpace: .normalized,
            endpointClass: .local,
            modelSize: "4B / 7B",
            quantization: "local/BYO",
            license: .research,
            note: "Useful normalized-output preset for local coordinate-space tests."
        ),
        GrounderPreset(
            id: "jedi",
            displayName: "Jedi",
            modelID: "jedi-grounder",
            coordinateSpace: .normalized,
            endpointClass: .byo,
            modelSize: "varies",
            quantization: "BYO host",
            license: .research,
            note: "Jedi-style training/corpus-compatible preset; BYO endpoint."
        ),
        GrounderPreset(
            id: "claude",
            displayName: "Claude fallback",
            modelID: "claude-visual-locator",
            source: .claude,
            promptTemplate: "ElementLocator",
            parser: "element-locator",
            coordinateSpace: .sent,
            endpointClass: .claude,
            modelSize: "hosted",
            quantization: "n/a",
            license: .proprietary,
            note: "Fallback through Cascade's existing ElementLocator."
        ),
    ]

    public static func preset(id: String?) -> GrounderPreset {
        presets.first { $0.id == id } ?? presets.first { $0.id == defaultPresetID }!
    }

    public static func makeGrounder(
        presetID: String?,
        apiKey: String?,
        endpointOverride: String?,
        modelOverride: String?,
        coordSpaceOverride: String?
    ) -> (any VisualGrounder)? {
        let preset = preset(id: presetID)
        if preset.endpointClass == .claude {
            return ClaudeVisualGrounder()
        }
        if preset.endpointClass == .hosted {
            guard let apiKey, !apiKey.isEmpty else { return nil }
        }
        let endpoint = endpointOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? endpointOverride!
            : (preset.endpointClass == .hosted ? defaultHostedEndpoint : "http://localhost:8000/v1/chat/completions")
        guard let url = URL(string: endpoint) else { return nil }
        let coordSpace = coordSpaceOverride.flatMap(UITARSGrounder.CoordSpace.init(rawValue:)) ?? preset.coordinateSpace
        return UITARSGrounder(
            baseURL: url,
            model: modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? modelOverride! : preset.modelID,
            apiKey: apiKey,
            coordSpace: coordSpace,
            enableRegionBudgeting: preset.endpointClass != .hosted
        )
    }

    // MARK: - d18 canvas grounder (UI-Venus-1.5, self-hosted)

    /// The preset that owns canvas-concept targets when a self-host endpoint is
    /// explicitly configured. UI-TARS-1.5-7B stays the BASELINE for every other
    /// visual call.
    public static let canvasPresetID = "ui-venus"

    /// Builds the OPTIONAL canvas grounder — the specialist consulted only for
    /// targets that name a drawn surface (`GroundingRouter.namesCanvasConcept`),
    /// where AX has nothing faithful to offer and the baseline grounder is
    /// weakest (ScreenSpot-Pro-style targets).
    ///
    /// The endpoint contract is deliberately NARROW (documented in
    /// docs/research/AX_FIRST_GROUNDING_PLAN.md): one crop + one query in →
    /// one point/bbox + confidence out, over the OpenAI-compatible
    /// `/v1/chat/completions` surface that `vllm serve` / SGLang expose — so the
    /// existing `UITARSGrounder` client speaks it unchanged (`coordSpace: .sent`
    /// for the Qwen3-VL family; probe with `probeCoordSpace` before trusting a
    /// click).
    ///
    /// Returns nil — meaning the baseline owns EVERY visual call, byte-identical
    /// to shipped — unless an explicit self-host endpoint is configured:
    ///  • no endpoint (or blank/invalid) → nil. There is deliberately NO
    ///    localhost fallback here: a silently-assumed local server would add a
    ///    failing round trip to every canvas target.
    ///  • an OpenRouter endpoint → nil. No reliable OpenRouter deployment
    ///    serves UI-Venus; routing there would ground with the wrong model. No
    ///    code path may assume OpenRouter hosts the canvas grounder.
    ///  • a `hosted`/`claude`-class preset → nil. The canvas contract is a
    ///    self-host (byo/local) point-grounding endpoint only.
    public static func makeCanvasGrounder(
        presetID: String? = nil,
        endpoint: String?,
        apiKey: String? = nil,
        modelOverride: String? = nil,
        coordSpaceOverride: String? = nil
    ) -> (any VisualGrounder)? {
        let preset = preset(id: presetID?.isEmpty == false ? presetID : canvasPresetID)
        guard preset.endpointClass == .byo || preset.endpointClass == .local else { return nil }
        guard let endpoint = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty,
              let url = URL(string: endpoint) else { return nil }
        if let host = url.host?.lowercased(),
           host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") {
            return nil
        }
        let coordSpace = coordSpaceOverride.flatMap(UITARSGrounder.CoordSpace.init(rawValue:))
            ?? preset.coordinateSpace
        let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UITARSGrounder(
            baseURL: url,
            model: model?.isEmpty == false ? model! : preset.modelID,
            apiKey: apiKey,
            coordSpace: coordSpace,
            enableRegionBudgeting: true
        )
    }

    public static func probeCoordSpace(
        coordSpace: UITARSGrounder.CoordSpace,
        modelOutput: String,
        sentWidth: Int = 1280,
        sentHeight: Int = 800,
        displayWidth: Int = 1280,
        displayHeight: Int = 800,
        expected: CGPoint = CGPoint(x: 640, y: 400),
        tolerance: Double = 8
    ) -> GrounderCoordinateProbe {
        guard let parsed = UITARSGrounder.parseBox(modelOutput) else {
            return GrounderCoordinateProbe(
                status: .parseMiss,
                expected: expected,
                actual: nil,
                errorPoints: nil,
                coordSpace: coordSpace
            )
        }
        let image = UITARSGrounder.resolveImageSpace(parsed: parsed, sentW: sentWidth, sentH: sentHeight, space: coordSpace)
        let actual = UITARSGrounder.toDisplayPoint(
            imagePoint: image.point,
            imageW: image.imageW,
            imageH: image.imageH,
            displayW: displayWidth,
            displayH: displayHeight
        )
        let error = hypot(actual.x - expected.x, actual.y - expected.y)
        return GrounderCoordinateProbe(
            status: error <= tolerance ? .passed : .failed,
            expected: expected,
            actual: actual,
            errorPoints: error,
            coordSpace: coordSpace
        )
    }

    public static func syntheticProbeOutput(for coordSpace: UITARSGrounder.CoordSpace) -> String {
        switch coordSpace {
        case .smartResize:
            let resized = UITARSGrounder.smartResize(width: 1280, height: 800)
            return "click(start_box='(\(resized.w / 2),\(resized.h / 2))')"
        case .sent:
            return "click(start_box='(640,400)')"
        case .normalized:
            return "click(start_box='(500,500)')"
        }
    }
}
