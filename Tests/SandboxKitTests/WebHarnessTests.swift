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

@Test
func webSkillsIndexListsEverySkillWithContent() {
    let index = WebSkills.index()
    #expect(!WebSkills.names.isEmpty)
    for name in WebSkills.names {
        // Every skill the agent can pull must appear in the index it's shown, and
        // resolve to a non-trivial playbook — otherwise it's a dead catalogue entry.
        #expect(index.contains(name))
        #expect((WebSkills.content(named: name)?.count ?? 0) > 40)
    }
    #expect(WebSkills.content(named: "no-such-skill") == nil)
    #expect(WebSkills.names.contains("webmail"))
}
