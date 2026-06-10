import Foundation
import Testing
@testable import ComputerUseKit

private let blenderFixture = """
---
name: blender
description: Drives Blender's modal keyboard workflows.
---

# Blender

Work from screenshots; the AX tree cannot see the canvas.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["org.blenderfoundation.blender"],
    "names": ["Blender"]
  },
  "inputPolicies": [
    { "kind": "numericModalText", "delivery": "physicalKeys", "maxLength": 12, "characters": "0123456789.-" }
  ],
  "axUnreliable": true,
  "keysFollowPointer": true
}
```
"""

/// The shape TipTour ships — tiptour fence name plus keys Cascade doesn't use.
private let tiptourFixture = """
---
name: blender
description: TipTour-authored skill.
---

# Blender

One action at a time.

```tiptour-runtime-hints
{
  "appMatchers": { "bundleIdentifiers": ["org.blenderfoundation.blender"], "names": ["Blender"] },
  "commandAliases": [
    { "phrases": ["select all"], "type": "pressKey", "label": "A" }
  ],
  "inputPolicies": [
    { "kind": "numericModalText", "delivery": "physicalKeys", "maxLength": 16, "characters": "0123456789.-+*/" }
  ],
  "targetPolicies": { "menuSelection": { "preferLeftMenuRegionMaxX": 0.72 } },
  "plannerInstructions": ["Use one TipTour action at a time."]
}
```
"""

private func parsed(_ markdown: String, path: String = "/tmp/skills/blender/SKILL.md") -> AppSkill? {
    AppSkillRegistry.parseSkill(markdown: markdown, path: path, source: "user")
}

private func writeSkill(_ markdown: String, under root: URL, directory: String) throws {
    let dir = root.appendingPathComponent(directory, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try markdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

private func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("appskill-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct AppSkillTests {
    @Test func parsesFrontmatterNameAndDescription() {
        let skill = parsed(blenderFixture)
        #expect(skill?.name == "blender")
        #expect(skill?.description == "Drives Blender's modal keyboard workflows.")
    }

    @Test func fallsBackToDirectoryNameWithoutFrontmatterName() {
        let bare = blenderFixture.replacingOccurrences(of: "name: blender\n", with: "")
        let skill = parsed(bare, path: "/tmp/skills/photoshop/SKILL.md")
        #expect(skill?.name == "photoshop")
    }

    @Test func extractsCascadeRuntimeHintsFence() {
        let skill = parsed(blenderFixture)
        #expect(skill?.hints.appMatchers?.bundleIdentifiers == ["org.blenderfoundation.blender"])
        #expect(skill?.hints.inputPolicies.first?.delivery == "physicalKeys")
        #expect(skill?.hints.inputPolicies.first?.maxLength == 12)
    }

    @Test func acceptsTipTourFenceWithUnknownKeys() {
        let skill = parsed(tiptourFixture)
        #expect(skill != nil)
        #expect(skill?.hints.appMatchers?.names == ["Blender"])
        #expect(skill?.hints.inputPolicies.first?.kind == "numericModalText")
        // TipTour-only keys (commandAliases, targetPolicies, plannerInstructions)
        // are ignored, and tiptour skills don't set the Cascade-only flag.
        #expect(skill?.axUnreliable == false)
    }

    @Test func missingFenceYieldsTaskSkillWithDefaultHints() {
        // Pure task skills carry no hints fence — they parse, join the index,
        // but never app-match and carry no policies.
        let skill = parsed("# Research\n\nJust prose.", path: "/tmp/skills/web-research/SKILL.md")
        #expect(skill?.name == "web-research")
        #expect(skill?.axUnreliable == false)
        #expect(skill?.matches(appName: "Safari", bundleIdentifier: "com.apple.Safari") == false)
    }

    @Test func rejectsMalformedHintsJSON() {
        let broken = blenderFixture.replacingOccurrences(of: "\"axUnreliable\": true", with: "\"axUnreliable\": ")
        #expect(parsed(broken) == nil)
    }

    @Test func useWhenParsesAndFallsBackToDescription() {
        let withUseWhen = blenderFixture.replacingOccurrences(
            of: "---\nname: blender\n",
            with: "---\nname: blender\nuseWhen: any 3D work\n"
        )
        #expect(parsed(withUseWhen)?.useWhen == "any 3D work")
        #expect(parsed(blenderFixture)?.useWhen == "Drives Blender's modal keyboard workflows.")
    }

    @Test func indexRendersOneLinePerSkill() throws {
        let a = try #require(parsed(blenderFixture))
        let b = try #require(parsed("# Notes\n\nProse.", path: "/tmp/skills/web-research/SKILL.md"))
        let index = try #require(AppSkillRegistry(skills: [a, b]).indexText)
        #expect(index.contains("- blender: Drives Blender's modal keyboard workflows."))
        #expect(index.contains("- web-research: web-research"))
        #expect(index.contains("use_skill"))
        #expect(!index.contains("Work from screenshots"))  // index never carries content
        #expect(AppSkillRegistry(skills: []).indexText == nil)
    }

    @Test func namedLookupIsCaseInsensitive() throws {
        let registry = AppSkillRegistry(skills: [try #require(parsed(blenderFixture))])
        #expect(registry.skill(named: "Blender")?.name == "blender")
        #expect(registry.skill(named: " blender ")?.name == "blender")
        #expect(registry.skill(named: "nope") == nil)
    }

    @Test func axUnreliableDefaultsFalseAndParsesTrue() {
        #expect(parsed(blenderFixture)?.axUnreliable == true)
        let without = blenderFixture.replacingOccurrences(of: ",\n  \"axUnreliable\": true", with: "")
        #expect(parsed(without)?.axUnreliable == false)
    }

    @Test func keysFollowPointerDefaultsFalseAndParsesTrue() {
        #expect(parsed(blenderFixture)?.keysFollowPointer == true)
        // The tiptour fixture doesn't carry the Cascade-only flag.
        #expect(parsed(tiptourFixture)?.keysFollowPointer == false)
    }

    @Test func instructionsStripFrontmatterAndFence() throws {
        let instructions = try #require(parsed(blenderFixture)?.instructions)
        #expect(instructions.contains("Work from screenshots"))
        #expect(!instructions.contains("name: blender"))
        #expect(!instructions.contains("```"))
        #expect(!instructions.contains("appMatchers"))
        #expect(instructions.hasPrefix("# Blender"))
    }

    @Test func matchesBundleIdentifierCaseInsensitively() throws {
        let skill = try #require(parsed(blenderFixture))
        #expect(skill.matches(appName: nil, bundleIdentifier: "ORG.BlenderFoundation.Blender"))
        #expect(!skill.matches(appName: nil, bundleIdentifier: "com.apple.Safari"))
    }

    @Test func matchesAppNameBySubstring() throws {
        let skill = try #require(parsed(blenderFixture))
        #expect(skill.matches(appName: "Blender 4.2", bundleIdentifier: nil))
        #expect(skill.matches(appName: "blender", bundleIdentifier: nil))
        #expect(!skill.matches(appName: "Finder", bundleIdentifier: nil))
        #expect(!skill.matches(appName: nil, bundleIdentifier: nil))
    }

    @Test func numericModalTextUsesPhysicalKeys() throws {
        let skill = try #require(parsed(blenderFixture))
        #expect(skill.shouldTypePhysicalKeys("3"))
        #expect(skill.shouldTypePhysicalKeys("1.5"))
        #expect(skill.shouldTypePhysicalKeys("-0.75"))
    }

    @Test func nonNumericOrOversizeTextDoesNot() throws {
        let skill = try #require(parsed(blenderFixture))
        #expect(!skill.shouldTypePhysicalKeys("hello"))
        #expect(!skill.shouldTypePhysicalKeys("3a"))
        #expect(!skill.shouldTypePhysicalKeys("1234567890123"))  // 13 > maxLength 12
        #expect(!skill.shouldTypePhysicalKeys(""))
        #expect(!skill.shouldTypePhysicalKeys("-"))   // no digit
        #expect(!skill.shouldTypePhysicalKeys("."))
    }

    @Test func physicalKeySequenceMapsDigitsPeriodMinus() {
        #expect(AppSkillRegistry.physicalKeySequence(for: "1.5") == ["1", "period", "5"])
        #expect(AppSkillRegistry.physicalKeySequence(for: "-2") == ["minus", "2"])
        #expect(AppSkillRegistry.physicalKeySequence(for: " 3 ") == ["3"])
        #expect(AppSkillRegistry.physicalKeySequence(for: "+3") == nil)
        #expect(AppSkillRegistry.physicalKeySequence(for: "") == nil)
    }

    @Test func userSkillOverridesBundledSameName() throws {
        let userRoot = try makeTempRoot()
        let bundledRoot = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: userRoot)
            try? FileManager.default.removeItem(at: bundledRoot)
        }
        try writeSkill(blenderFixture, under: userRoot, directory: "blender")
        try writeSkill(tiptourFixture, under: bundledRoot, directory: "blender")
        let registry = AppSkillRegistry.load(
            roots: [(userRoot, "user"), (bundledRoot, "bundled")],
            fileManager: .default
        )
        #expect(registry.skills.count == 1)
        #expect(registry.skills.first?.source == "user")
        #expect(registry.skills.first?.axUnreliable == true)  // the user copy, not tiptour's
    }

    @Test func loadsOnlySkillMdFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(blenderFixture, under: root, directory: "blender")
        // Valid skill content under the wrong file names — must be ignored.
        let dir = root.appendingPathComponent("blender", isDirectory: true)
        try blenderFixture.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try blenderFixture.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let registry = AppSkillRegistry.load(roots: [(root, "user")], fileManager: .default)
        #expect(registry.skills.count == 1)
        #expect(registry.skills.first?.path.hasSuffix("SKILL.md") == true)
    }

    @Test func bundledBlenderSkillLoads() {
        let registry = AppSkillRegistry.load()
        let blender = registry.skill(appName: "Blender", bundleIdentifier: "org.blenderfoundation.blender")
        #expect(blender != nil)
        #expect(blender?.name == "blender")
        #expect(blender?.axUnreliable == true)
        #expect(blender?.keysFollowPointer == true)
        #expect(blender?.shouldTypePhysicalKeys("3") == true)
        #expect(blender?.instructions.contains("one") == true)
    }

    @Test func bundledKeynotePackLoads() {
        let registry = AppSkillRegistry.load()
        // Both builds resolve to the core skill: legacy Keynote 14.x and the
        // 15.x app, whose name is "Keynote Creator Studio" and whose bundle
        // id is com.apple.Keynote (not com.apple.iWork.Keynote).
        let creatorStudio = registry.skill(appName: "Keynote Creator Studio", bundleIdentifier: "com.apple.Keynote")
        let legacy = registry.skill(appName: "Keynote", bundleIdentifier: "com.apple.iWork.Keynote")
        #expect(creatorStudio?.name == "keynote")
        #expect(legacy?.name == "keynote")
        #expect(creatorStudio?.axUnreliable == false)
        #expect(creatorStudio?.keysFollowPointer == false)
        // The task skills join the index but never app-match — matchers stay
        // on the core skill (and keynote-* would path-sort ahead of it).
        for name in ["keynote-consulting", "keynote-applescript"] {
            let skill = registry.skill(named: name)
            #expect(skill != nil, "missing bundled skill: \(name)")
            #expect(skill?.matches(appName: "Keynote Creator Studio", bundleIdentifier: "com.apple.Keynote") == false)
        }
        // PowerPoint still routes to the generic slides skill.
        #expect(registry.skill(appName: "Microsoft PowerPoint", bundleIdentifier: "com.microsoft.Powerpoint")?.name == "slides")
    }

    @Test func bundledStarterPackLoads() {
        let registry = AppSkillRegistry.load()
        #expect(registry.skills.count >= 13)
        let names = registry.skills.map { $0.name.lowercased() }
        #expect(Set(names).count == names.count)  // unique
        for expected in ["blender", "email", "spreadsheets", "web-research", "terminal", "messaging", "finder"] {
            #expect(registry.skill(named: expected) != nil, "missing bundled skill: \(expected)")
        }
        // Every bundled skill has a usable index line and pullable content.
        for skill in registry.skills {
            #expect(!skill.useWhen.isEmpty)
            #expect(!skill.instructions.isEmpty)
        }
        #expect(registry.indexText?.contains("- figma:") == true)
    }
}
