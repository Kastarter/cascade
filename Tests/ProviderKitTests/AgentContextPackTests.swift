import CascadeMemory
import ProviderKit
import Testing

@Test
func agentContextPackRendersInDeterministicOrderAndDedupesBodies() {
    let duplicateBody = "same remembered screen text"
    let pack = AgentContextPack(sections: [
        AgentContextSection(name: "zeta", body: "last", freshness: .historical, order: 30),
        AgentContextSection(name: "alpha", body: duplicateBody, freshness: .current, order: 10),
        AgentContextSection(name: "beta", body: duplicateBody, freshness: .recent, order: 20),
        AgentContextSection(name: "middle", body: "second", freshness: .recent, order: 20)
    ])

    let rendered = pack.render()

    #expect(rendered.sections.map(\.name) == ["alpha", "middle", "zeta"])
    #expect(rendered.dedupedSectionCount == 1)
    #expect(rendered.text.range(of: "## alpha")!.lowerBound < rendered.text.range(of: "## middle")!.lowerBound)
    #expect(rendered.text.range(of: "## middle")!.lowerBound < rendered.text.range(of: "## zeta")!.lowerBound)
}

@Test
func agentContextPackAppliesPerSectionAndTotalBudgets() {
    let longBody = String(repeating: "abcdef ", count: 40)
    let rendered = AgentContextPack.render(
        sections: [
            AgentContextSection(name: "first", body: longBody, freshness: .current, order: 1),
            AgentContextSection(name: "second", body: longBody, freshness: .current, order: 2)
        ],
        budget: AgentContextBudget(totalCharacters: 120, perSectionCharacters: 45)
    )

    #expect(rendered.text.count <= 120)
    #expect(rendered.sections.first?.renderedCharacters ?? 0 <= 45)
    #expect(rendered.sections.first?.truncated == true)
    #expect(rendered.droppedSectionCount >= 0)
}

@Test
func agentContextPackAuditDescriptorHashesBodyText() {
    let rawBody = "/Users/person/private-client-path answer value"
    let rendered = AgentContextPack(sections: [
        AgentContextSection(name: "local_files", body: rawBody, freshness: .current)
    ]).render()

    #expect(rendered.auditDescriptor.contains("sourceHash=\(AuditIdentity.hash(rawBody))"))
    #expect(rendered.auditDescriptor.contains("sourceChars=\(rawBody.count)"))
    #expect(!rendered.auditDescriptor.contains(rawBody))
    #expect(!rendered.auditDescriptor.contains("/Users/person"))
}

@Test
func agentAffordanceMarksRenderAsBudgetedContextSection() {
    let rendered = AgentContextPack(
        sections: [],
        affordanceMarks: [
            AgentAffordanceMark(mark: "A2", role: "textbox", label: "Search", actionHint: #"fill_text text="Search""#, order: 2),
            AgentAffordanceMark(mark: "A1", role: "button", label: "Submit", actionHint: #"click_text text="Submit""#, order: 1),
            AgentAffordanceMark(mark: "A1", role: "button", label: "Submit", actionHint: #"click_text text="Submit""#, order: 1)
        ],
        budget: AgentContextBudget(totalCharacters: 500, perSectionCharacters: 300)
    ).render()

    #expect(rendered.sections.map(\.name) == ["affordances"])
    #expect(rendered.dedupedSectionCount == 0)
    #expect(rendered.text.contains(#"A1 [button] Submit -> click_text text="Submit""#))
    #expect(rendered.text.contains(#"A2 [textbox] Search -> fill_text text="Search""#))
    #expect(rendered.text.range(of: "A1 [button]")!.lowerBound < rendered.text.range(of: "A2 [textbox]")!.lowerBound)
}
