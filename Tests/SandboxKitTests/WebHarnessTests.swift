import Testing

@testable import SandboxKit

@Test
func webHarnessToolDefinitionsMatchTheToolNames() {
    let defs = WebHarness.toolDefinitions()
    let names = Set(defs.compactMap { $0["name"] as? String })
    // The names offered to the model must be exactly the names the dispatcher (and
    // ComputerUseAgent's extraToolNames routing) recognizes — a mismatch would offer
    // a tool that then falls through to a "unknown tool" / coordinate-click path.
    #expect(names == WebHarness.toolNames)
    #expect(names == ["read_page", "list_interactives", "click_text", "fill_field"])
}

@Test
func webHarnessToolDefinitionsAreWellFormed() {
    for def in WebHarness.toolDefinitions() {
        #expect(def["name"] as? String != nil)
        #expect(def["description"] as? String != nil)
        #expect(def["input_schema"] != nil)
    }
}
