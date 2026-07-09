import CascadeMemory
import Foundation
import Testing

@testable import AgentOrchestrator

private func engineStep(
    _ order: Int,
    _ kind: RecipeStepKind,
    surface: String,
    text: String? = nil,
    anchor: String? = nil,
    parameterKey: String? = nil,
    parameterKind: RecipeParameterKind? = nil,
    sourceStepIDs: [Int] = []
) -> RecipeStep {
    RecipeStep(
        order: order,
        kind: kind,
        text: text,
        appName: "Safari",
        surface: surface,
        ocrAnchor: anchor,
        isParameter: parameterKey != nil,
        parameterKey: parameterKey,
        parameterKind: parameterKind,
        sourceStepIDs: sourceStepIDs
    )
}

private func engineRecipeWithDemoLiteral() -> AgentRecipe {
    AgentRecipe(steps: [
        engineStep(0, .click, surface: "Source catalog", anchor: "Alpha Record"),
        engineStep(1, .click, surface: "Source catalog", anchor: "$18"),
        engineStep(2, .click, surface: "Source catalog", anchor: "Demo notes"),
        engineStep(3, .type, surface: "Destination tracker", text: "Alpha Record", parameterKey: "record_name", parameterKind: .freeText, sourceStepIDs: [0]),
        engineStep(4, .type, surface: "Destination tracker", text: "$18", parameterKey: "amount", parameterKind: .currency, sourceStepIDs: [1]),
        engineStep(5, .type, surface: "Destination tracker", text: "Demo notes", parameterKey: "notes", parameterKind: .freeText, sourceStepIDs: [2]),
    ])
}

private func enginePlan(maxItems: Int = 50, maxPages: Int = 20, maxFailures: Int = 3) throws -> BatchCompletionPlan {
    var plan = try #require(BatchCompletionPlanner().plan(
        goal: "Import all remaining records from the source catalog into the destination tracker",
        recipe: engineRecipeWithDemoLiteral(),
        apps: ["Safari"]
    ))
    plan = BatchCompletionPlan(
        goalHash: plan.goalHash,
        recipeStepCount: plan.recipeStepCount,
        sourceSurfaceHashes: plan.sourceSurfaceHashes,
        destinationSurfaceHashes: plan.destinationSurfaceHashes,
        fieldBindings: plan.fieldBindings,
        identityFieldKeyHash: plan.identityFieldKeyHash,
        phases: plan.phases,
        maxItems: maxItems,
        maxPages: maxPages,
        maxFailures: maxFailures
    )
    return plan
}

private func sourceItem(_ ordinal: Int, plan: BatchCompletionPlan, name: String, amount: String = "$10", notes: String = "notes") -> BatchSourceItem {
    BatchSourceItem.fromObservedFields(
        ordinal: ordinal,
        bindings: plan.fieldBindings,
        observedFields: [
            "record name": name,
            "amount": amount,
            "notes": notes,
        ]
    )
}

private actor BatchTestLog {
    private var events: [String] = []
    private var appliedNames: [String] = []
    private var auditDetails: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func recordApply(_ item: BatchSourceItem, identityFieldKeyHash: String) {
        events.append("apply:\(item.ordinal)")
        appliedNames.append(item.fieldValue(for: identityFieldKeyHash)?.rawValue ?? "")
    }

    func recordAudit(_ detail: String) {
        auditDetails.append(detail)
    }

    func snapshot() -> (events: [String], appliedNames: [String], auditDetails: [String]) {
        (events, appliedNames, auditDetails)
    }
}

private struct FakeBatchSource: BatchSourceEnumerating {
    let items: [BatchSourceItem]
    let completed: Bool
    let log: BatchTestLog

    init(items: [BatchSourceItem], completed: Bool = true, log: BatchTestLog) {
        self.items = items
        self.completed = completed
        self.log = log
    }

    func enumerateBatchSourceItems(plan: BatchCompletionPlan, limits: BatchWorkflowLimits) async throws -> BatchSourceEnumeration {
        await log.append("enumerate")
        return BatchSourceEnumeration(items: items, completed: completed, pagesVisited: 1, issueCode: completed ? nil : "uncertain_pages")
    }
}

private struct FakeBatchDestination: BatchDestinationMeasuring {
    let existing: [String]
    let log: BatchTestLog

    func measureBatchDestination(plan: BatchCompletionPlan, limits: BatchWorkflowLimits) async throws -> BatchDestinationSnapshot {
        await log.append("measure")
        return BatchDestinationSnapshot(identityFieldKeyHash: plan.identityFieldKeyHash, existingIdentityValues: existing)
    }
}

private struct FakeBatchApplier: BatchItemApplying {
    let log: BatchTestLog

    func applyBatchItem(_ item: BatchSourceItem, plan: BatchCompletionPlan) async throws -> BatchApplyResult {
        await log.recordApply(item, identityFieldKeyHash: plan.identityFieldKeyHash)
        return BatchApplyResult(status: "ok", effectHash: "effect-\(item.ordinal)")
    }
}

private struct FakeBatchVerifier: BatchItemVerifying {
    let failingOrdinals: Set<Int>
    let log: BatchTestLog

    init(failingOrdinals: Set<Int> = [], log: BatchTestLog) {
        self.failingOrdinals = failingOrdinals
        self.log = log
    }

    func verifyBatchItem(_ item: BatchSourceItem, applyResult: BatchApplyResult, plan: BatchCompletionPlan) async throws -> BatchVerificationResult {
        await log.append("verify:\(item.ordinal)")
        return BatchVerificationResult(verified: !failingOrdinals.contains(item.ordinal), reasonCode: "not_visible")
    }
}

private struct RecordingBatchAuditSink: BatchAuditSink {
    let log: BatchTestLog

    func recordBatchAudit(action: String, detail: String) async {
        await log.recordAudit("\(action) \(detail)")
    }
}

@Test
func engineDiffsAppliesAndVerifiesFakeSourceValuesInsteadOfDemoLiterals() async throws {
    let plan = try enginePlan()
    let log = BatchTestLog()
    let items = [
        sourceItem(0, plan: plan, name: "Beta Record", amount: "$21", notes: "first"),
        sourceItem(1, plan: plan, name: "Gamma Record", amount: "$12", notes: "second"),
        sourceItem(2, plan: plan, name: "Delta Record", amount: "$19", notes: "third"),
    ]

    let report = try await BatchWorklistEngine().run(
        plan: plan,
        source: FakeBatchSource(items: items, log: log),
        destination: FakeBatchDestination(existing: ["gamma record"], log: log),
        applier: FakeBatchApplier(log: log),
        verifier: FakeBatchVerifier(log: log),
        audit: RecordingBatchAuditSink(log: log)
    )

    let snapshot = await log.snapshot()
    #expect(report.totalSeen == 3)
    #expect(report.alreadyPresent == 1)
    #expect(report.added == 2)
    #expect(report.verified == 2)
    #expect(snapshot.appliedNames == ["Beta Record", "Delta Record"])
    #expect(!snapshot.appliedNames.contains("Alpha Record"))
}

@Test
func engineOrdersEnumerationMeasurementApplyAndVerificationPhases() async throws {
    let plan = try enginePlan()
    let log = BatchTestLog()
    let items = [
        sourceItem(0, plan: plan, name: "Already There"),
        sourceItem(1, plan: plan, name: "First Missing"),
        sourceItem(2, plan: plan, name: "Second Missing"),
    ]

    _ = try await BatchWorklistEngine().run(
        plan: plan,
        source: FakeBatchSource(items: items, log: log),
        destination: FakeBatchDestination(existing: ["already there"], log: log),
        applier: FakeBatchApplier(log: log),
        verifier: FakeBatchVerifier(log: log),
        audit: RecordingBatchAuditSink(log: log)
    )

    let events = await log.snapshot().events
    #expect(events == ["enumerate", "measure", "apply:1", "verify:1", "apply:2", "verify:2"])
}

@Test
func engineSuppressesDuplicateAndMissingSourceIdentities() async throws {
    let plan = try enginePlan()
    let log = BatchTestLog()
    let nameless = BatchSourceItem(ordinal: 2, fields: [
        BatchFieldValue(fieldKeyHash: plan.fieldBindings[1].keyHash, kind: .currency, rawValue: "$8")
    ])
    let items = [
        sourceItem(0, plan: plan, name: "Duplicate Record"),
        sourceItem(1, plan: plan, name: "duplicate record"),
        nameless,
        sourceItem(3, plan: plan, name: "Solo Record"),
    ]

    let report = try await BatchWorklistEngine().run(
        plan: plan,
        source: FakeBatchSource(items: items, log: log),
        destination: FakeBatchDestination(existing: [], log: log),
        applier: FakeBatchApplier(log: log),
        verifier: FakeBatchVerifier(log: log),
        audit: RecordingBatchAuditSink(log: log)
    )

    let snapshot = await log.snapshot()
    #expect(report.totalSeen == 4)
    #expect(report.added == 1)
    #expect(report.verified == 1)
    #expect(report.skipped == 3)
    #expect(snapshot.appliedNames == ["Solo Record"])
}

@Test
func engineStopsApplyingAfterVerificationFailureLimit() async throws {
    let plan = try enginePlan(maxFailures: 1)
    let log = BatchTestLog()
    let items = [
        sourceItem(0, plan: plan, name: "First Missing"),
        sourceItem(1, plan: plan, name: "Second Missing"),
    ]

    let report = try await BatchWorklistEngine().run(
        plan: plan,
        source: FakeBatchSource(items: items, log: log),
        destination: FakeBatchDestination(existing: [], log: log),
        applier: FakeBatchApplier(log: log),
        verifier: FakeBatchVerifier(failingOrdinals: [0], log: log),
        audit: RecordingBatchAuditSink(log: log)
    )

    let events = await log.snapshot().events
    #expect(events == ["enumerate", "measure", "apply:0", "verify:0"])
    #expect(report.status == .stoppedFailureLimit)
    #expect(report.added == 0)
    #expect(report.verified == 0)
    #expect(report.skipped == 1)
    #expect(report.uncertain == 1)
}

@Test
func engineFailsClosedWhenEnumerationIsUncertain() async throws {
    let plan = try enginePlan()
    let log = BatchTestLog()
    let items = [sourceItem(0, plan: plan, name: "Uncertain Item")]

    let report = try await BatchWorklistEngine().run(
        plan: plan,
        source: FakeBatchSource(items: items, completed: false, log: log),
        destination: FakeBatchDestination(existing: [], log: log),
        applier: FakeBatchApplier(log: log),
        verifier: FakeBatchVerifier(log: log),
        audit: RecordingBatchAuditSink(log: log)
    )

    let events = await log.snapshot().events
    #expect(events == ["enumerate"])
    #expect(report.status == .uncertain)
    #expect(report.added == 0)
    #expect(report.skipped == 1)
    #expect(report.uncertain == 1)
}

@Test
func engineAuditAndReportDescriptorsArePrivacySafe() async throws {
    let plan = try enginePlan()
    let log = BatchTestLog()
    let item = sourceItem(0, plan: plan, name: "Private Source Record", amount: "$27", notes: "secret notes")

    let report = try await BatchWorklistEngine().run(
        plan: plan,
        source: FakeBatchSource(items: [item], log: log),
        destination: FakeBatchDestination(existing: [], log: log),
        applier: FakeBatchApplier(log: log),
        verifier: FakeBatchVerifier(log: log),
        audit: RecordingBatchAuditSink(log: log)
    )

    let snapshot = await log.snapshot()
    let combined = ([report.auditDetail] + report.decisions.map(\.auditDescriptor) + snapshot.auditDetails).joined(separator: "\n")
    #expect(combined.contains("totalSeen=1"))
    #expect(combined.contains("identityHash="))
    #expect(combined.contains("valueHash=") || combined.contains("fieldHash="))
    for raw in ["Alpha Record", "Private Source Record", "$27", "secret notes", "Source catalog", "Destination tracker"] {
        #expect(!combined.contains(raw))
    }
}
