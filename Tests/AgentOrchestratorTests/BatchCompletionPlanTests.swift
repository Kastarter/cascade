import CascadeMemory
import Foundation
import Testing
import WasteDetection

@testable import AgentOrchestrator

private func batchStep(
    _ order: Int,
    _ kind: RecipeStepKind,
    surface: String,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    anchor: String? = nil,
    isParameter: Bool = false,
    parameterKey: String? = nil,
    parameterKind: RecipeParameterKind? = nil,
    sourceStepIDs: [Int] = []
) -> RecipeStep {
    RecipeStep(
        order: order,
        kind: kind,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: "Safari",
        surface: surface,
        ocrAnchor: anchor,
        isParameter: isParameter,
        parameterKey: parameterKey,
        parameterKind: parameterKind,
        sourceStepIDs: sourceStepIDs
    )
}

private func catalogTransferRecipe() -> AgentRecipe {
    AgentRecipe(steps: [
        batchStep(0, .activateApp, surface: "Source catalog"),
        batchStep(1, .click, surface: "Source catalog", anchor: "Alpha Record"),
        batchStep(2, .click, surface: "Source catalog", anchor: "$18"),
        batchStep(3, .click, surface: "Source catalog", anchor: "Demo notes"),
        batchStep(4, .activateApp, surface: "Destination tracker"),
        batchStep(
            5,
            .type,
            surface: "Destination tracker",
            text: "Alpha Record",
            anchor: "Record name",
            isParameter: true,
            parameterKey: "record_name",
            parameterKind: .freeText,
            sourceStepIDs: [1]
        ),
        batchStep(
            6,
            .type,
            surface: "Destination tracker",
            text: "$18",
            anchor: "Amount",
            isParameter: true,
            parameterKey: "amount",
            parameterKind: .currency,
            sourceStepIDs: [2]
        ),
        batchStep(
            7,
            .type,
            surface: "Destination tracker",
            text: "Demo notes",
            anchor: "Notes",
            isParameter: true,
            parameterKey: "notes",
            parameterKind: .freeText,
            sourceStepIDs: [3]
        ),
    ])
}

@Test
func batchPlannerBuildsWorklistPlanFromSourceToDestinationRecipe() throws {
    let plan = try #require(BatchCompletionPlanner().plan(
        goal: "Finish the remaining records from the source catalog in the destination tracker",
        recipe: catalogTransferRecipe(),
        apps: ["Safari"]
    ))

    #expect(plan.schemaVersion == BatchCompletionPlan.schemaVersion)
    #expect(plan.fieldBindings.map(\.label) == ["record name", "amount", "notes"])
    #expect(plan.identityFieldLabel == "record name")
    #expect(plan.phases == BatchCompletionPhase.allCases)
    #expect(plan.maxItems == 50)
    #expect(plan.maxPages == 20)
    #expect(plan.maxFailures == 3)
    #expect(plan.sourceSurfaceHashes.count == 1)
    #expect(plan.destinationSurfaceHashes.count == 1)
    #expect(plan.sourceSurfaceHashes != plan.destinationSurfaceHashes)

    try BatchCompletionPlanValidator().validate(plan)
}

@Test
func batchPlannerDoesNotTreatOneOffCopyAsBatchCompletion() {
    let recipe = AgentRecipe(steps: [
        batchStep(0, .click, surface: "Mail", anchor: "Invoice total"),
        batchStep(
            1,
            .type,
            surface: "Numbers",
            text: "$420",
            isParameter: true,
            parameterKey: "invoice_total",
            parameterKind: .currency,
            sourceStepIDs: [0]
        ),
    ])

    let plan = BatchCompletionPlanner().plan(
        goal: "Copy the latest invoice total into Numbers",
        recipe: recipe,
        apps: ["Mail", "Numbers"]
    )

    #expect(plan == nil)
}

@Test
func batchPlannerDoesNotTreatOneOffImportAsBatchCompletion() {
    let recipe = AgentRecipe(steps: [
        batchStep(0, .click, surface: "Mail", anchor: "Invoice total"),
        batchStep(
            1,
            .type,
            surface: "Numbers",
            text: "$420",
            isParameter: true,
            parameterKey: "invoice_total",
            parameterKind: .currency,
            sourceStepIDs: [0]
        ),
    ])

    let plan = BatchCompletionPlanner().plan(
        goal: "Import this invoice total into Numbers",
        recipe: recipe,
        apps: ["Mail", "Numbers"]
    )

    #expect(plan == nil)
}

@Test
func batchPlannerDoesNotTriggerOnAmbiguousCatalogMentionAlone() {
    let recipe = AgentRecipe(steps: [
        batchStep(0, .click, surface: "Source catalog", anchor: "Current amount"),
        batchStep(
            1,
            .type,
            surface: "Destination tracker",
            text: "$18",
            isParameter: true,
            parameterKey: "catalog_amount",
            parameterKind: .currency,
            sourceStepIDs: [0]
        ),
    ])

    let plan = BatchCompletionPlanner().plan(
        goal: "Update the catalog amount in the destination tracker",
        recipe: recipe,
        apps: ["Safari"]
    )

    #expect(plan == nil)
}

@Test
func batchRuntimeInstructionDescribesEnumerateDiffVerifyReportLoop() throws {
    let plan = try #require(BatchCompletionPlanner().plan(
        goal: "Sync all records from the source catalog into the destination tracker",
        recipe: catalogTransferRecipe(),
        apps: ["Safari"]
    ))

    let instruction = plan.runtimeInstruction()

    #expect(instruction.contains("Treat the source surface as the worklist"))
    #expect(instruction.contains("Measure the destination first"))
    #expect(instruction.contains("do not create duplicates"))
    #expect(instruction.contains("Verify each record/item"))
    #expect(instruction.contains("Report counts"))
    #expect(instruction.contains("record name, amount, notes"))
    #expect(!instruction.contains("Alpha Record"))
    #expect(!instruction.contains("Demo notes"))
}

@Test
func batchRuntimeInstructionDoesNotUseRawOCRAnchorsAsFieldLabels() throws {
    let recipe = AgentRecipe(steps: [
        batchStep(0, .click, surface: "Source catalog", anchor: "Private source record"),
        batchStep(
            1,
            .type,
            surface: "Destination tracker",
            text: "Private source record",
            anchor: "Private source record",
            isParameter: true,
            sourceStepIDs: [0]
        ),
    ])

    let plan = try #require(BatchCompletionPlanner().plan(
        goal: "Finish all records from the source catalog into the destination tracker",
        recipe: recipe,
        apps: ["Safari"]
    ))

    let instruction = plan.runtimeInstruction()
    #expect(instruction.contains("field 1"))
    #expect(!instruction.contains("Private source record"))
}

@Test
func batchAuditDetailDoesNotExposeRawSourceValues() throws {
    let plan = try #require(BatchCompletionPlanner().plan(
        goal: "Import every record from the source catalog into the destination tracker",
        recipe: catalogTransferRecipe(),
        apps: ["Safari"]
    ))

    let detail = plan.auditDetail()

    #expect(detail.contains("schema=batch-completion-plan.v1"))
    #expect(detail.contains("fieldBindingCount=3"))
    #expect(detail.contains("maxItems=50"))
    #expect(detail.contains("maxPages=20"))
    #expect(detail.contains("maxFailures=3"))
    #expect(!detail.contains("Alpha Record"))
    #expect(!detail.contains("Demo notes"))
    #expect(!detail.contains("Source catalog"))
    #expect(!detail.contains("Destination tracker"))
}

@Test
func createAgentAuditsBatchPlanWhenSynthesisGateIsEnabled() async throws {
    let defaults = UserDefaults.standard
    let oldValue = defaults.object(forKey: "cascade.experimentalParameterizedMining")
    defaults.set(true, forKey: "cascade.experimentalParameterizedMining")
    defer {
        if let oldValue {
            defaults.set(oldValue, forKey: "cascade.experimentalParameterizedMining")
        } else {
            defaults.removeObject(forKey: "cascade.experimentalParameterizedMining")
        }
    }

    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchCompletionPlan-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let waste = DetectedWaste(
        title: "Catalog to tracker",
        apps: ["Safari"],
        occurrences: 1,
        estimatedSecondsPerRun: 60,
        estimatedTotalSeconds: 60,
        recipe: catalogTransferRecipe(),
        evidence: [1],
        confidence: 0.9,
        signature: "catalog-transfer"
    )
    let curated = CuratedAgent(
        source: waste,
        name: "Finish catalog import",
        why: "The rest of the records are repetitive to enter.",
        goal: "Finish all remaining records from the source catalog in the destination tracker",
        value: 0.9
    )

    _ = try await CascadeOrchestrator(store: store).createAgent(from: curated)

    let audit = try await store.recentAudit(limit: 10)
    #expect(audit.contains { $0.action == "agent.batch.plan.ready" })
    #expect(audit.first { $0.action == "agent.batch.plan.ready" }?.detail.contains("fieldBindingCount=3") == true)
}
