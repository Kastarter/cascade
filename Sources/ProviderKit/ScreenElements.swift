import Foundation

/// One frontmost-window control as the agent's perception lane reports it.
/// `frame` is in capture-screen points, top-left origin — the provider has
/// already mapped AX's global coordinates onto the screen the agent watches;
/// the renderer scales into the model's screenshot-pixel space.
public struct CUScreenElement: Sendable {
    public let role: String
    public let label: String
    public let value: String
    public let enabled: Bool
    public let frame: CGRect

    public init(role: String, label: String, value: String, enabled: Bool, frame: CGRect) {
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.frame = frame
    }
}

/// What a read_screen_elements call found — controls, or the reason there are
/// none worth trusting (canvas app, privacy rule, stopped run).
public enum CUScreenElementsResult: Sendable {
    case elements([CUScreenElement])
    case unavailable(String)
}

/// Renders harvested elements into the compact text the model reads. Pure —
/// the coordinate mapping (screen points → screenshot pixels, the space the
/// model clicks in) is pinned by tests; getting it wrong would send every
/// AX-guided click to the wrong place.
public enum CUScreenElementRenderer {
    static let maxValueChars = 120
    static let maxOutputChars = 10_000

    public static func render(
        _ result: CUScreenElementsResult,
        resW: Int, resH: Int, displayW: Int, displayH: Int
    ) -> String {
        switch result {
        case .unavailable(let reason):
            return reason
        case .elements(let elements):
            guard !elements.isEmpty else {
                return "No accessibility elements are visible — this app draws its own canvas. Work from the screenshot."
            }
            guard displayW > 0, displayH > 0 else { return "Screen size unknown — work from the screenshot." }
            let sx = Double(resW) / Double(displayW)
            let sy = Double(resH) / Double(displayH)
            var lines: [String] = [
                "Frontmost window controls (\(elements.count)). @(x,y) is each element's center in screenshot pixels — click it directly. w×h sizes are screenshot pixels too.",
            ]
            var chars = lines[0].count
            var rendered = 0
            for element in elements {
                // Partially off-screen elements would otherwise print centers
                // the click path can't reach (negative or past the edge).
                let cx = max(0, min(Int(((element.frame.midX) * sx).rounded()), resW))
                let cy = max(0, min(Int(((element.frame.midY) * sy).rounded()), resH))
                let w = Int((element.frame.width * sx).rounded())
                let h = Int((element.frame.height * sy).rounded())
                var line = element.role
                if !element.label.isEmpty { line += " “\(clip(element.label))”" }
                if !element.value.isEmpty { line += " value=“\(clip(element.value))”" }
                line += " @(\(cx),\(cy)) \(w)×\(h)"
                if !element.enabled { line += " (disabled)" }
                if chars + line.count > maxOutputChars {
                    lines.append("… +\(elements.count - rendered) more elements truncated.")
                    break
                }
                lines.append(line)
                chars += line.count
                rendered += 1
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func clip(_ text: String) -> String {
        // Newlines would break the one-line-per-element contract.
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= maxValueChars ? flat : String(flat.prefix(maxValueChars)) + "…"
    }
}
