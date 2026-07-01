import AgentOrchestrator
import CascadeMemory
import ComputerUseKit
import Foundation
import ProviderKit
import Testing

@testable import AppShell

private struct LearnedSkillFakeCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        #"{"agents":[]}"#
    }
}

@MainActor
private func makeLearnedSkillModel(
    consolidationEnabled: Bool,
    appSkills: AppSkillRegistry = AppSkillRegistry()
) throws -> (model: CascadeAppModel, skillDirectory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeLearnedSkillIT-\(UUID().uuidString)", isDirectory: true)
    let store = try CascadeStore(path: root.appendingPathComponent("store.sqlite").path)
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: LearnedSkillFakeCompleter()))
    let defaults = UserDefaults(suiteName: "CascadeLearnedSkillIT-\(UUID().uuidString)")!
    defaults.set(consolidationEnabled, forKey: CascadeAppModel.experimentalSkillConsolidationKey)
    let skillDirectory = root.appendingPathComponent("Skills", isDirectory: true)
    let model = try CascadeAppModel(
        store: store,
        orchestrator: orchestrator,
        defaults: defaults,
        startsSubsystems: false,
        appSkills: appSkills,
        learnedSkillDirectory: skillDirectory
    )
    return (model, skillDirectory)
}

private func skillMarkdown(
    name: String,
    useWhen: String,
    appName: String,
    steps: [String]
) -> String {
    """
    ---
    name: \(name)
    description: \(useWhen)
    useWhen: \(useWhen)
    ---

    # \(name)

    \(steps.map { "- \($0)" }.joined(separator: "\n"))

    ```cascade-runtime-hints
    {"appMatchers":{"names":["\(appName)"]}}
    ```
    """
}

private func learnedSkill(
    slug: String,
    appName: String,
    useWhen: String,
    steps: [String]
) -> CascadeAppModel.LearnedSkill {
	    CascadeAppModel.LearnedSkill(
	        appName: appName,
	        slug: slug,
	        markdown: skillMarkdown(name: slug, useWhen: useWhen, appName: appName, steps: steps),
	        sourceTask: useWhen,
	        sourceCaseIDs: [9001],
	        evidenceIDs: [101, 102],
	        successCount: 1
	    )
	}

private func registry(markdowns: [String]) throws -> AppSkillRegistry {
    let skills = try markdowns.enumerated().map { index, markdown in
        try #require(SkillConsolidator.record(
            id: "existing-\(index)",
            markdown: markdown,
            path: "/tmp/existing-\(index)/SKILL.md",
            source: "user",
            approved: true,
            successCount: 4
        )?.skill)
    }
    return AppSkillRegistry(skills: skills)
}

@MainActor @Test
func flagFalseLeavesLearnedSkillApprovalOnTheExistingPath() throws {
    let (model, skillDirectory) = try makeLearnedSkillModel(consolidationEnabled: false)
    let draft = learnedSkill(
        slug: "learned-pages-export",
        appName: "Pages",
        useWhen: "Export Pages drafts as PDF",
        steps: ["Open the Share menu", "Choose Export PDF"]
    )
    model.enqueueLearnedSkillForReview(draft)

    #expect(model.learnedSkillConsolidationHint(for: draft) == nil)
    let writtenSkill = skillDirectory
        .appendingPathComponent(draft.slug, isDirectory: true)
        .appendingPathComponent("SKILL.md")
    #expect(!FileManager.default.fileExists(atPath: writtenSkill.path))

	    model.approveLearnedSkill(draft)

	    #expect(FileManager.default.fileExists(atPath: writtenSkill.path))
	    let saved = try String(contentsOf: writtenSkill, encoding: .utf8)
	    #expect(saved.contains("status: active"))
	    #expect(saved.contains("sourceCaseIDs: [\"9001\"]"))
	    #expect(model.pendingLearnedSkills.isEmpty)
	}

@MainActor @Test
func flagTrueAnnotatesLearnedSkillReviewCardsWithoutWritingFiles() throws {
    let existing = skillMarkdown(
        name: "blender-modeling",
        useWhen: "Create and adjust Blender mesh primitives",
        appName: "Blender",
        steps: ["Open Add Mesh with Shift A", "Scale objects with S", "Confirm modal values with Enter"]
    )
    let appSkills = try registry(markdowns: [existing])
    let (model, skillDirectory) = try makeLearnedSkillModel(consolidationEnabled: true, appSkills: appSkills)

    let revise = learnedSkill(
        slug: "learned-blender-modeling",
        appName: "Blender",
        useWhen: "Create and adjust Blender mesh primitives",
        steps: ["Open Add Mesh with Shift A", "Scale objects with S", "Confirm modal values with Enter", "Type numeric dimensions into modal fields"]
    )
    let duplicate = learnedSkill(
        slug: "learned-blender-duplicate",
        appName: "Blender",
        useWhen: "Create and adjust Blender mesh primitives",
        steps: ["Open Add Mesh with Shift A", "Scale objects with S", "Confirm modal values with Enter"]
    )
    let unrelated = learnedSkill(
        slug: "learned-slack-handoff",
        appName: "Slack",
        useWhen: "Summarize Slack handoff threads",
        steps: ["Open the thread", "Collect the unresolved action items"]
    )
    let invalid = CascadeAppModel.LearnedSkill(
        appName: "Preview",
        slug: "broken-preview",
        markdown: "# Missing metadata",
        sourceTask: "Annotate a PDF"
    )

	    #expect(model.learnedSkillConsolidationHint(for: revise)?.kind == .reviseExisting)
	    let duplicateHint = try #require(model.learnedSkillConsolidationHint(for: duplicate))
	    #expect(duplicateHint.kind == .archiveCandidate)
	    #expect(duplicateHint.sourceCaseIDs == [9001])
	    #expect(duplicateHint.successCount == 1)
	    #expect(model.learnedSkillConsolidationHint(for: unrelated)?.kind == .newSkill)
	    #expect(model.learnedSkillConsolidationHint(for: invalid)?.kind == .quarantine)

    #expect(!FileManager.default.fileExists(atPath: skillDirectory.path))
}
