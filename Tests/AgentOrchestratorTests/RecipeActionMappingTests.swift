import AgentOrchestrator
import CascadeMemory
import Testing

@Test
func activateAppStepIsNotDirectlyExecutable() {
    #expect(AgentAction(recipeStep: RecipeStep(order: 0, kind: .activateApp, appName: "Mail")) == nil)
}

@Test
func clickStepMapsToClickAction() {
    let action = AgentAction(recipeStep: RecipeStep(order: 1, kind: .click, x: 10, y: 20, appName: "Mail"))
    guard case .computerUse(.click(let x, let y))? = action else {
        Issue.record("expected a click action")
        return
    }
    #expect(x == 10 && y == 20)
}

@Test
func clickWithoutCoordinatesIsNil() {
    #expect(AgentAction(recipeStep: RecipeStep(order: 2, kind: .click, appName: "Mail")) == nil)
}

@Test
func typeAndKeyStepsMap() {
    let typeAction = AgentAction(recipeStep: RecipeStep(order: 3, kind: .type, text: "hi", appName: "Mail"))
    guard case .computerUse(.typeText(let text))? = typeAction else {
        Issue.record("expected a type action")
        return
    }
    #expect(text == "hi")

    let keyAction = AgentAction(recipeStep: RecipeStep(order: 4, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"))
    guard case .computerUse(.key(let key, let modifiers))? = keyAction else {
        Issue.record("expected a key action")
        return
    }
    #expect(key == "c" && modifiers == ["command"])
}
