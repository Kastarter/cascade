import CascadeMemory
import Foundation

public enum BatchCompletionPhase: String, CaseIterable, Codable, Sendable {
    case enumerateSource
    case readSourceFields
    case measureDestination
    case diffByIdentity
    case applyMissingItems
    case verifyEachItem
    case reportCounts
}

public struct BatchCompletionFieldBinding: Sendable, Equatable, Codable {
    public let label: String
    public let keyHash: String
    public let kind: RecipeParameterKind?
    public let sourceOrders: [Int]
    public let targetOrder: Int
    public let sourceSurfaceHashes: [String]
    public let targetSurfaceHash: String
    public let transform: String?

    public init(
        label: String,
        keyHash: String,
        kind: RecipeParameterKind?,
        sourceOrders: [Int],
        targetOrder: Int,
        sourceSurfaceHashes: [String],
        targetSurfaceHash: String,
        transform: String?
    ) {
        self.label = label
        self.keyHash = keyHash
        self.kind = kind
        self.sourceOrders = sourceOrders
        self.targetOrder = targetOrder
        self.sourceSurfaceHashes = sourceSurfaceHashes
        self.targetSurfaceHash = targetSurfaceHash
        self.transform = transform
    }
}

/// A pure, auditable plan for the "watch me do a few, then finish the rest from
/// the source list" class of workflows. It does not enumerate real source rows
/// itself; it makes the deployed agent run a bounded worklist loop instead of
/// exact-replaying the demonstrated rows.
public struct BatchCompletionPlan: Sendable, Equatable, Codable {
    public static let schemaVersion = "batch-completion-plan.v1"

    public let schemaVersion: String
    public let goalHash: String
    public let recipeStepCount: Int
    public let sourceSurfaceHashes: [String]
    public let destinationSurfaceHashes: [String]
    public let fieldBindings: [BatchCompletionFieldBinding]
    public let identityFieldKeyHash: String
    public let phases: [BatchCompletionPhase]
    public let maxItems: Int
    public let maxPages: Int
    public let maxFailures: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, goalHash, recipeStepCount, sourceSurfaceHashes, destinationSurfaceHashes
        case fieldBindings, identityFieldKeyHash, phases, maxItems, maxPages, maxFailures
    }

    public init(
        schemaVersion: String = Self.schemaVersion,
        goalHash: String,
        recipeStepCount: Int,
        sourceSurfaceHashes: [String],
        destinationSurfaceHashes: [String],
        fieldBindings: [BatchCompletionFieldBinding],
        identityFieldKeyHash: String,
        phases: [BatchCompletionPhase] = BatchCompletionPhase.allCases,
        maxItems: Int = 50,
        maxPages: Int = 20,
        maxFailures: Int = 3
    ) {
        self.schemaVersion = schemaVersion
        self.goalHash = goalHash
        self.recipeStepCount = recipeStepCount
        self.sourceSurfaceHashes = sourceSurfaceHashes
        self.destinationSurfaceHashes = destinationSurfaceHashes
        self.fieldBindings = fieldBindings
        self.identityFieldKeyHash = identityFieldKeyHash
        self.phases = phases
        self.maxItems = maxItems
        self.maxPages = maxPages
        self.maxFailures = maxFailures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        self.goalHash = try container.decode(String.self, forKey: .goalHash)
        self.recipeStepCount = try container.decode(Int.self, forKey: .recipeStepCount)
        self.sourceSurfaceHashes = try container.decode([String].self, forKey: .sourceSurfaceHashes)
        self.destinationSurfaceHashes = try container.decode([String].self, forKey: .destinationSurfaceHashes)
        self.fieldBindings = try container.decode([BatchCompletionFieldBinding].self, forKey: .fieldBindings)
        self.identityFieldKeyHash = try container.decode(String.self, forKey: .identityFieldKeyHash)
        self.phases = try container.decodeIfPresent([BatchCompletionPhase].self, forKey: .phases) ?? BatchCompletionPhase.allCases
        self.maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems) ?? 50
        self.maxPages = try container.decodeIfPresent(Int.self, forKey: .maxPages) ?? 20
        self.maxFailures = try container.decodeIfPresent(Int.self, forKey: .maxFailures) ?? 3
    }

    public var identityFieldLabel: String {
        fieldBindings.first { $0.keyHash == identityFieldKeyHash }?.label
            ?? fieldBindings.first?.label
            ?? "item name"
    }

    public func runtimeInstruction() -> String {
        let fieldList = fieldBindings.prefix(6).map(\.label).joined(separator: ", ")
        let fields = fieldList.isEmpty ? "the fields demonstrated by the user" : fieldList
        return """
        Batch completion mode:
        - Treat the source surface as the worklist. Enumerate every visible, scroll-loaded, or paginated source record/item before adding more.
        - For each source record/item, read these fields from the source: \(fields).
        - Measure the destination first and match existing destination records/items by \(identityFieldLabel) so you do not create duplicates.
        - For each missing record/item, use the recorded procedure as the template, substituting that source record/item's current field values into the destination fields.
        - Verify each record/item appears in the destination before moving to the next record/item.
        - Report counts at the end: added, already present, skipped with reason, and total seen in the source. Stop honestly if enumeration or matching is uncertain.
        """
    }

    public func auditDetail(issueCodes: [String] = []) -> String {
        var fields = [
            "schema=\(schemaVersion)",
            "goalHash=\(goalHash)",
            "stepCount=\(recipeStepCount)",
            "sourceSurfaceCount=\(sourceSurfaceHashes.count)",
            "sourceSurfaceHash=\(AuditIdentity.hash(sourceSurfaceHashes.joined(separator: "|")))",
            "destinationSurfaceCount=\(destinationSurfaceHashes.count)",
            "destinationSurfaceHash=\(AuditIdentity.hash(destinationSurfaceHashes.joined(separator: "|")))",
            "fieldBindingCount=\(fieldBindings.count)",
            "fieldBindingHash=\(AuditIdentity.hash(fieldBindings.map(\.keyHash).joined(separator: "|")))",
            "identityFieldKeyHash=\(identityFieldKeyHash)",
            "phaseCount=\(phases.count)",
            "phaseHash=\(AuditIdentity.hash(phases.map(\.rawValue).joined(separator: "|")))",
            "maxItems=\(maxItems)",
            "maxPages=\(maxPages)",
            "maxFailures=\(maxFailures)",
        ]
        if !issueCodes.isEmpty {
            fields.append("issueCount=\(issueCodes.count)")
            fields.append("issueCodes=\(issueCodes.map(AuditIdentity.safeToken).joined(separator: ","))")
        }
        return fields.joined(separator: " ")
    }
}

public struct BatchCompletionPlanner: Sendable {
    public init() {}

    public func plan(from curated: CuratedAgent) -> BatchCompletionPlan? {
        plan(goal: curated.goal, recipe: curated.source.recipe, apps: curated.source.apps)
    }

    public func plan(for agent: CascadeAgent) -> BatchCompletionPlan? {
        let goal = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        return plan(goal: goal?.isEmpty == false ? goal! : agent.name, recipe: agent.recipe, apps: agent.apps)
    }

    public func plan(goal: String, recipe: AgentRecipe, apps: [String]) -> BatchCompletionPlan? {
        guard Self.looksLikeBatchIntent(goal) else { return nil }
        let steps = recipe.steps.sorted { $0.order < $1.order }
        guard !steps.isEmpty else { return nil }
        let byOrder = Dictionary(uniqueKeysWithValues: steps.map { ($0.order, $0) })
        let bindings = Self.fieldBindings(in: steps, byOrder: byOrder)
        guard !bindings.isEmpty else { return nil }
        let sourceSurfaceHashes = Self.unique(bindings.flatMap(\.sourceSurfaceHashes))
        let destinationSurfaceHashes = Self.unique(bindings.map(\.targetSurfaceHash))
        let crossesSurface = bindings.contains { binding in
            !binding.sourceSurfaceHashes.isEmpty && !binding.sourceSurfaceHashes.contains(binding.targetSurfaceHash)
        } || Set(apps.map(AuditIdentity.safeToken)).count > 1
        guard crossesSurface else { return nil }
        let identity = Self.identityBinding(in: bindings)
        return BatchCompletionPlan(
            goalHash: AuditIdentity.hash(goal),
            recipeStepCount: steps.count,
            sourceSurfaceHashes: sourceSurfaceHashes,
            destinationSurfaceHashes: destinationSurfaceHashes,
            fieldBindings: bindings,
            identityFieldKeyHash: identity.keyHash
        )
    }

    private static func fieldBindings(
        in steps: [RecipeStep],
        byOrder: [Int: RecipeStep]
    ) -> [BatchCompletionFieldBinding] {
        steps.compactMap { target in
            guard isLiveFieldTarget(target) else { return nil }
            let sourceOrders = target.sourceStepIDs.sorted()
            guard !sourceOrders.isEmpty else { return nil }
            let sources = sourceOrders.compactMap { byOrder[$0] }
            guard !sources.isEmpty else { return nil }
            let key = target.parameterKey ?? target.dataflowEdgeID ?? target.ocrAnchor ?? "step-\(target.order)"
            return BatchCompletionFieldBinding(
                label: fieldLabel(for: target, fallbackIndex: target.order),
                keyHash: AuditIdentity.hash(key),
                kind: target.parameterKind,
                sourceOrders: sourceOrders,
                targetOrder: target.order,
                sourceSurfaceHashes: unique(sources.map(surfaceHash)),
                targetSurfaceHash: surfaceHash(target),
                transform: target.transform.map(AuditIdentity.safeToken)
            )
        }
    }

    private static func isLiveFieldTarget(_ step: RecipeStep) -> Bool {
        step.isParameter && (step.kind == .type || isPasteShortcut(step) || !step.sourceStepIDs.isEmpty)
    }

    private static func isPasteShortcut(_ step: RecipeStep) -> Bool {
        guard step.kind == .key, step.key?.lowercased() == "v" else { return false }
        let modifiers = Set(step.modifiers.map { $0.lowercased() })
        return modifiers.contains("command") || modifiers.contains("cmd") || modifiers.contains("control") || modifiers.contains("ctrl")
    }

    private static func identityBinding(in bindings: [BatchCompletionFieldBinding]) -> BatchCompletionFieldBinding {
        let priorityTerms = ["name", "title", "record", "item", "row", "entry", "email", "url", "id", "number"]
        return bindings.first { binding in
            let normalized = binding.label.lowercased()
            return priorityTerms.contains { normalized.contains($0) }
        } ?? bindings[0]
    }

    private static func looksLikeBatchIntent(_ goal: String) -> Bool {
        let tokens = Set(goal
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init))
        let batchTokens: Set<String> = [
            "all", "batch", "complete", "each",
            "every", "finish", "items", "list",
            "missing", "records", "remainder", "remaining", "rest", "rows", "sync"
        ]
        return !tokens.intersection(batchTokens).isEmpty
    }

    private static func fieldLabel(for step: RecipeStep, fallbackIndex: Int) -> String {
        if let key = step.parameterKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return prettify(key)
        }
        if let kind = step.parameterKind {
            return prettify(kind.rawValue)
        }
        return "field \(fallbackIndex)"
    }

    private static func prettify(_ raw: String) -> String {
        let withWordBreaks = raw.reduce(into: "") { result, character in
            if character == "_" || character == "-" || character == "." || character == "/" {
                result.append(" ")
            } else if character.isUppercase, result.last?.isWhitespace == false {
                result.append(" ")
                result.append(character)
            } else {
                result.append(character)
            }
        }
        let words = withWordBreaks
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() }
        let label = words.joined(separator: " ")
        return label.isEmpty ? "field" : String(label.prefix(48))
    }

    private static func surfaceHash(_ step: RecipeStep) -> String {
        AuditIdentity.hash(surfaceIdentity(step))
    }

    private static func surfaceIdentity(_ step: RecipeStep) -> String {
        let surface = step.surface?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let surface, !surface.isEmpty { return surface }
        return step.appName
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

public struct BatchCompletionPlanValidator: Sendable {
    public init() {}

    public func validate(_ plan: BatchCompletionPlan) throws {
        var issues: [String] = []
        if plan.schemaVersion != BatchCompletionPlan.schemaVersion { issues.append("unsupported_schema") }
        if plan.recipeStepCount <= 0 { issues.append("empty_recipe") }
        if plan.sourceSurfaceHashes.isEmpty { issues.append("empty_source_surfaces") }
        if plan.destinationSurfaceHashes.isEmpty { issues.append("empty_destination_surfaces") }
        if plan.fieldBindings.isEmpty { issues.append("empty_field_bindings") }
        if plan.identityFieldKeyHash == AuditIdentity.hash(nil) { issues.append("empty_identity_field") }
        if !plan.fieldBindings.contains(where: { $0.keyHash == plan.identityFieldKeyHash }) {
            issues.append("identity_binding_missing")
        }
        if plan.maxItems <= 0 { issues.append("invalid_max_items") }
        if plan.maxPages <= 0 { issues.append("invalid_max_pages") }
        if plan.maxFailures <= 0 { issues.append("invalid_max_failures") }
        if plan.phases.count != BatchCompletionPhase.allCases.count ||
            Set(plan.phases.map(\.rawValue)) != Set(BatchCompletionPhase.allCases.map(\.rawValue)) {
            issues.append("missing_required_phase")
        }
        for binding in plan.fieldBindings {
            if binding.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("empty_field_label")
            }
            if binding.sourceOrders.isEmpty { issues.append("binding_missing_source") }
            if binding.sourceOrders.contains(where: { $0 >= binding.targetOrder }) {
                issues.append("binding_source_not_before_target")
            }
            if binding.sourceSurfaceHashes.isEmpty { issues.append("binding_missing_source_surface") }
            if binding.targetSurfaceHash == AuditIdentity.hash(nil) { issues.append("binding_missing_target_surface") }
        }
        if !issues.isEmpty {
            throw BatchCompletionPlanValidationError(issueCodes: Array(Set(issues)).sorted())
        }
    }
}

public struct BatchCompletionPlanValidationError: Error, LocalizedError, Sendable, Equatable {
    public let issueCodes: [String]

    public init(issueCodes: [String]) {
        self.issueCodes = issueCodes
    }

    public var errorDescription: String? {
        "Batch completion plan validation failed: \(issueCodes.joined(separator: ", "))"
    }
}
