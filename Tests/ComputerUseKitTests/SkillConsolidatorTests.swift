import Foundation
import Testing
@testable import ComputerUseKit

private func parsedSkill(
    name: String,
    useWhen: String,
    appNames: [String] = ["Blender"],
    bundles: [String] = ["org.blenderfoundation.blender"],
    explicitAskOnly: Bool = false
) throws -> AppSkill {
    var frontmatter = """
    ---
    name: \(name)
    description: \(useWhen)
    useWhen: \(useWhen)
    """
    if explicitAskOnly {
        frontmatter += "\nexplicitAskOnly: true"
    }
    frontmatter += "\n---"
    let markdown = """
    \(frontmatter)

    # \(name)

    - Use the verified workflow.

    ```cascade-runtime-hints
    {"appMatchers":{"bundleIdentifiers":[\(jsonArray(bundles))],"names":[\(jsonArray(appNames))]}}
    ```
    """
    return try #require(AppSkillRegistry.parseSkill(markdown: markdown, path: "/tmp/skills/\(name)/SKILL.md", source: "user"))
}

private func record(
    id: String,
    name: String,
    useWhen: String,
    appNames: [String] = ["Blender"],
    bundles: [String] = ["org.blenderfoundation.blender"],
    explicitAskOnly: Bool = false,
    steps: [String] = [],
    approved: Bool = false,
    successes: Int = 0,
    failures: Int = 0,
    evidence: Set<String> = [],
    quarantined: Bool = false,
    archived: Bool = false
) throws -> SkillConsolidator.LearnedSkillRecord {
    SkillConsolidator.LearnedSkillRecord(
        id: id,
        skill: try parsedSkill(
            name: name,
            useWhen: useWhen,
            appNames: appNames,
            bundles: bundles,
            explicitAskOnly: explicitAskOnly
        ),
        humanSteps: steps,
        approved: approved,
        successCount: successes,
        failureCount: failures,
        evidenceIDs: evidence,
        quarantined: quarantined,
        archived: archived
    )
}

private func jsonArray(_ values: [String]) -> String {
    values.map { "\"\($0)\"" }.joined(separator: ",")
}

struct SkillConsolidatorTests {
    @Test func nearDuplicateSkillsRouteToReviseExisting() throws {
        let existing = try record(
            id: "blender-modeling",
            name: "blender-modeling",
            useWhen: "Create and adjust Blender mesh primitives",
            explicitAskOnly: true,
            steps: [
                "Open Add Mesh with Shift A",
                "Scale objects with S",
                "Confirm modal values with Enter"
            ],
            approved: true,
            successes: 5,
            evidence: ["moment-1", "moment-2"]
        )
        let candidate = try record(
            id: "draft-blender-modeling",
            name: "blender-mesh-draft",
            useWhen: "Create and adjust Blender mesh primitives",
            explicitAskOnly: true,
            steps: [
                "Open Add Mesh with Shift A",
                "Scale objects with S",
                "Confirm modal values with Enter",
                "Type numeric dimensions into modal fields"
            ],
            successes: 1,
            evidence: ["moment-2", "moment-3"]
        )

        let result = SkillConsolidator().evaluate(candidate, against: [existing])

        #expect(result.action == .reviseExisting(existingID: "blender-modeling"))
        #expect((result.bestMatch?.total ?? 0.0) >= 0.68)
        #expect(result.bestMatch?.explicitAskOnly == 1.0)
        #expect(result.bestMatch?.approvedStatus == 0.65)
    }

    @Test func unrelatedSameAppSkillsStaySeparate() throws {
        let existing = try record(
            id: "blender-modeling",
            name: "blender-modeling",
            useWhen: "Create Blender mesh primitives",
            steps: [
                "Open Add Mesh with Shift A",
                "Scale objects with S"
            ],
            approved: true,
            successes: 3,
            evidence: ["mesh-1"]
        )
        let candidate = try record(
            id: "blender-rendering",
            name: "blender-rendering",
            useWhen: "Render animation frames from the Blender timeline",
            steps: [
                "Open render settings",
                "Set output folder",
                "Start animation render"
            ],
            successes: 1,
            evidence: ["render-1"]
        )

        let result = SkillConsolidator().evaluate(candidate, against: [existing])

        #expect(result.action == .newSkill)
        #expect((result.bestMatch?.total ?? 1.0) < 0.68)
    }

    @Test func failedAndQuarantinedSkillsAbstainFromActiveUse() throws {
        let active = try record(
            id: "active",
            name: "active-skill",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A"],
            approved: true,
            successes: 2
        )
        let quarantined = try record(
            id: "quarantined",
            name: "quarantined-skill",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A"],
            approved: true,
            successes: 4,
            quarantined: true
        )
        let failed = try record(
            id: "failed",
            name: "failed-skill",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A"],
            approved: true,
            failures: 3
        )
        let consolidator = SkillConsolidator()

        #expect(consolidator.activeSkills(from: [quarantined, failed, active]).map(\.id) == ["active"])

        let healthyCandidate = try record(
            id: "healthy-candidate",
            name: "healthy-candidate",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A"],
            successes: 1
        )
        #expect(consolidator.evaluate(healthyCandidate, against: [quarantined]).action == .newSkill)

        let failedCandidate = try record(
            id: "failed-candidate",
            name: "failed-candidate",
            useWhen: "Create Blender mesh primitives",
            failures: 2
        )
        if case .quarantine(let reason) = consolidator.evaluate(failedCandidate, against: [active]).action {
            #expect(reason.contains("failure"))
        } else {
            #expect(false, "Expected failure-dominated candidate to quarantine.")
        }
    }

    @Test func scoringIsStableAcrossInputOrder() throws {
        let alpha = try record(
            id: "alpha",
            name: "same-skill",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A", "Scale objects with S"],
            approved: true,
            successes: 2,
            evidence: ["same-1"]
        )
        let beta = try record(
            id: "beta",
            name: "same-skill",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A", "Scale objects with S"],
            approved: true,
            successes: 2,
            evidence: ["same-1"]
        )
        let candidate = try record(
            id: "candidate",
            name: "candidate-skill",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A", "Scale objects with S", "Confirm modal values with Enter"],
            successes: 1,
            evidence: ["same-1", "same-2"]
        )
        let consolidator = SkillConsolidator()

        let forward = consolidator.evaluate(candidate, against: [beta, alpha])
        let reversed = consolidator.evaluate(candidate, against: [alpha, beta])

        #expect(forward.action == .reviseExisting(existingID: "alpha"))
        #expect(forward == reversed)
    }

    @Test func exactLowerSignalDuplicateArchivesCandidate() throws {
        let existing = try record(
            id: "proven-existing",
            name: "proven-existing",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A", "Scale objects with S"],
            approved: true,
            successes: 6,
            evidence: ["moment-1", "moment-2"]
        )
        let candidate = try record(
            id: "redundant-draft",
            name: "redundant-draft",
            useWhen: "Create Blender mesh primitives",
            steps: ["Open Add Mesh with Shift A", "Scale objects with S"],
            evidence: ["moment-1", "moment-2"]
        )

        let result = SkillConsolidator().evaluate(candidate, against: [existing])

        #expect(result.action == .archiveCandidate(existingID: "proven-existing"))
        #expect((result.bestMatch?.total ?? 0.0) >= 0.84)
    }
}
