import AgentOrchestrator
import ComputerUseKit
import ProviderKit
import Testing

@Test
func plannedActionMapsToExecutableAgentActions() {
    #expect(AgentAction(planned: .click(x: 1, y: 2)) == .computerUse(.click(x: 1, y: 2)))
    #expect(AgentAction(planned: .type("hi")) == .computerUse(.typeText("hi")))
    #expect(AgentAction(planned: .openURL("https://example.com")) == .computerUse(.openURL("https://example.com")))
}

@Test
func nonExecutablePlannedActionsMapToNil() {
    #expect(AgentAction(planned: .done("complete")) == nil)
    #expect(AgentAction(planned: .unsupported("shell")) == nil)
}
