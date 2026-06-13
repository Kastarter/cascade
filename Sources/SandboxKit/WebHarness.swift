import Foundation

/// The web analog of the Mac `AgentHarness`: instant DOM tools the background web
/// agent calls instead of poking pixel coordinates. They resolve in-process (no
/// screenshot round-trip), so reading content and clicking/filling named controls
/// is fast + reliable — the "harnessed like the cursor agent" half for the sandbox.
public enum WebHarness {
    /// Tool definitions handed to `ComputerUseAgent(extraTools:)`. Routed back to
    /// `run(_:_:sandbox:)` via the agent's `harnessProvider`. A func (not a stored
    /// static) because `[[String: Any]]` isn't Sendable.
    public static func toolDefinitions() -> [[String: Any]] {[
        [
            "name": "read_page",
            "description": "Read the current page's title, URL, and visible text instantly — no screenshot. Use this to read content (prices, names, results, confirmations) rather than relying on the screenshot.",
            "input_schema": ["type": "object", "properties": [:]] as [String: Any],
        ],
        [
            "name": "list_interactives",
            "description": "List the page's visible clickable + fillable elements (links, buttons, inputs) with their labels, instantly. Use it to discover what you can click or fill, then act with click_text / fill_field.",
            "input_schema": ["type": "object", "properties": [:]] as [String: Any],
        ],
        [
            "name": "click_text",
            "description": "Click the element whose visible label best matches `text` (a link, button, or control). Instant + reliable — PREFER this over clicking pixel coordinates.",
            "input_schema": [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "the element's visible text / label"]],
                "required": ["text"],
            ] as [String: Any],
        ],
        [
            "name": "fill_field",
            "description": "Type `value` into the input or textarea whose label, placeholder, or name best matches `field` (or the only field on the page). Instant — PREFER over clicking then typing.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "field": ["type": "string", "description": "the field's label / placeholder / name"],
                    "value": ["type": "string", "description": "what to type"],
                ],
                "required": ["field", "value"],
            ] as [String: Any],
        ],
    ]}

    public static let toolNames: Set<String> = ["read_page", "list_interactives", "click_text", "fill_field"]

    /// Executes one DOM tool against `sandbox`, returning the result text the model
    /// sees as the tool_result.
    @MainActor
    public static func run(_ name: String, _ input: [String: Any], sandbox: WebSandbox) async -> String {
        switch name {
        case "read_page":
            return await sandbox.readPageText()
        case "list_interactives":
            return await sandbox.listInteractives()
        case "click_text":
            guard let text = input["text"] as? String, !text.isEmpty else { return "click_text needs a non-empty \"text\"." }
            return await sandbox.clickByText(text)
        case "fill_field":
            guard let field = input["field"] as? String, let value = input["value"] as? String else {
                return "fill_field needs \"field\" and \"value\"."
            }
            return await sandbox.fillField(field, value: value)
        default:
            return "Unknown web tool \(name)."
        }
    }
}
