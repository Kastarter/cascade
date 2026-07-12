import Testing

@testable import ProviderKit

@MainActor @Test
func resourceCatalogPromptIsDefaultOff() {
    let implicit = ComputerUseAgent.renderedSystemPrompt(
        structural: false,
        harnessTier: .readOnly,
        recallEnabled: true
    )
    let explicit = ComputerUseAgent.renderedSystemPrompt(
        structural: false,
        harnessTier: .readOnly,
        recallEnabled: true,
        resourceCatalogEnabled: false
    )

    #expect(implicit == explicit)
    #expect(implicit.contains("You also have direct file tools"))
    #expect(implicit.contains("You can also recall the user's recorded screen history"))
    #expect(!implicit.contains("<resource_catalog>"))
}

@MainActor @Test
func resourceCatalogPromptReplacesSeparateFileAndRecallBlocks() {
    let prompt = ComputerUseAgent.renderedSystemPrompt(
        structural: false,
        harnessTier: .readOnly,
        recallEnabled: true,
        resourceCatalogEnabled: true
    )

    #expect(prompt.components(separatedBy: "<resource_catalog>").count == 2)
    #expect(prompt.contains("onScreen [available]"))
    #expect(prompt.contains("recordedMemory [available]"))
    #expect(prompt.contains("localFiles [available]"))
    #expect(prompt.contains("web [available]"))
    #expect(!prompt.contains("You also have direct file tools"))
    #expect(!prompt.contains("You can also recall the user's recorded screen history"))
}
