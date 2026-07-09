import AgentOrchestrator
import CascadeMemory
import Testing

@testable import SandboxKit

private actor BatchWebDriverLog {
    private var events: [String] = []
    private var appliedNames: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func applied(_ value: String) {
        appliedNames.append(value)
    }

    func snapshot() -> (events: [String], appliedNames: [String]) {
        (events, appliedNames)
    }
}

private func webDriverPlan() -> BatchCompletionPlan {
    let key = AuditIdentity.hash("item_name")
    return BatchCompletionPlan(
        goalHash: AuditIdentity.hash("sync all items"),
        recipeStepCount: 3,
        sourceSurfaceHashes: [AuditIdentity.hash("source")],
        destinationSurfaceHashes: [AuditIdentity.hash("destination")],
        fieldBindings: [
            BatchCompletionFieldBinding(
                label: "item name",
                keyHash: key,
                kind: .freeText,
                sourceOrders: [0],
                targetOrder: 2,
                sourceSurfaceHashes: [AuditIdentity.hash("source")],
                targetSurfaceHash: AuditIdentity.hash("destination"),
                transform: nil
            )
        ],
        identityFieldKeyHash: key
    )
}

@Test
func batchWebWorkflowDriverDelegatesToGenericBatchProtocols() async throws {
    let plan = webDriverPlan()
    let log = BatchWebDriverLog()
    let driver = BatchWebWorkflowDriver(
        enumerate: { plan, _ in
            await log.append("enumerate")
            return BatchSourceEnumeration(items: [
                BatchSourceItem.fromObservedFields(
                    ordinal: 0,
                    bindings: plan.fieldBindings,
                    observedFields: ["item name": "Alpha Record"]
                ),
                BatchSourceItem.fromObservedFields(
                    ordinal: 1,
                    bindings: plan.fieldBindings,
                    observedFields: ["item name": "Beta Record"]
                ),
            ])
        },
        measure: { plan, _ in
            await log.append("measure")
            return BatchDestinationSnapshot(identityFieldKeyHash: plan.identityFieldKeyHash, existingIdentityValues: ["beta record"])
        },
        apply: { item, plan in
            await log.append("apply:\(item.ordinal)")
            await log.applied(item.fieldValue(for: plan.identityFieldKeyHash)?.rawValue ?? "")
            return BatchApplyResult(status: "ok")
        },
        verify: { item, _, _ in
            await log.append("verify:\(item.ordinal)")
            return BatchVerificationResult(verified: true)
        }
    )

    let report = try await BatchWorklistEngine().run(
        plan: plan,
        source: driver,
        destination: driver,
        applier: driver,
        verifier: driver
    )

    let snapshot = await log.snapshot()
    #expect(report.totalSeen == 2)
    #expect(report.alreadyPresent == 1)
    #expect(report.added == 1)
    #expect(report.verified == 1)
    #expect(snapshot.events == ["enumerate", "measure", "apply:0", "verify:0"])
    #expect(snapshot.appliedNames == ["Alpha Record"])
}

@Test
func batchWebStructuralControlLoopTaskIsOneHashOnlySubtask() {
    let plan = webDriverPlan()
    let subtask = BatchWebWorkflowDriver.structuralControlLoopTask(
        for: plan,
        originalTask: "Sync every missing record from Source Site into Destination Tracker"
    )

    #expect(subtask.task.contains("structural batch/list control loop"))
    #expect(subtask.task.contains("taskHash="))
    #expect(subtask.task.contains("Sync every missing record from Source Site into Destination Tracker"))
    #expect(subtask.task.contains("maxItems=50"))
    #expect(!subtask.task.contains("Alpha Record"))
}
