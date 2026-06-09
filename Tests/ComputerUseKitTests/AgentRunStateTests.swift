import ComputerUseKit
import Testing

@Test
func agentRunStateStopsAndResets() {
    let state = AgentRunState()
    #expect(!state.isStopRequested)
    state.requestStop()
    #expect(state.isStopRequested)
    state.reset()
    #expect(!state.isStopRequested)
}
