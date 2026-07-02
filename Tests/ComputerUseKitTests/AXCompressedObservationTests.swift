import CascadeMemory
import CoreGraphics
import Foundation
import Testing

@testable import ComputerUseKit

// d10 compressed-planner-observation tests: rendering shape (grouping, stable
// ids, role/name/value/frame/actions/modality), deterministic task-relevant
// selection, and counts-only audit metrics. Pure — no live AX needed.
struct AXCompressedObservationTests {
    private static func match(
        id: String,
        label: String,
        role: String,
        container: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        actions: [String] = ["AXPress"],
        frame: CGRect? = CGRect(x: 10, y: 20, width: 100, height: 30),
        enabled: Bool? = nil,
        selected: Bool? = nil,
        focused: Bool? = nil
    ) -> AXElementResolver.Match {
        let descriptor = AXTargetDescriptorV2(
            label: label,
            role: role,
            identifier: identifier,
            container: container,
            supportedActions: actions
        )
        let node = AXElementResolver.ActionableNode(
            stableID: id,
            role: role,
            identifier: identifier,
            title: label,
            value: value,
            supportedActions: actions,
            enabled: enabled,
            focused: focused,
            selected: selected
        )
        return AXElementResolver.Match(
            id: id,
            center: frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 60, y: 35),
            frame: frame,
            role: role,
            title: label,
            score: 1,
            descriptor: descriptor,
            actionableNode: node
        )
    }

    // MARK: - Rendering shape

    @Test func rendersStableIDRoleNameFrameActionsAndModality() throws {
        let rendering = AXCompressedObservation.render(
            matches: [Self.match(
                id: "ax:0123456789ab",
                label: "New Note",
                role: "AXButton",
                container: "toolbar: Notes",
                identifier: "NewNoteButton",
                frame: CGRect(x: 712, y: 388, width: 86, height: 24)
            )],
            goal: "open Notes and create a new note"
        )
        let text = try #require(rendering).text
        #expect(text.contains("[ax:01234567]"))
        #expect(text.contains("button “New Note”"))
        #expect(text.contains("click(press)"))
        #expect(text.contains("(712,388,86×24)"))
        #expect(text.contains("id NewNoteButton"))
        #expect(text.contains("▸ in toolbar: Notes:"))
    }

    @Test func rendersValueAndStateFlags() throws {
        let rendering = AXCompressedObservation.render(
            matches: [Self.match(
                id: "ax:ffff0000aaaa",
                label: "Search",
                role: "AXSearchField",
                value: "hello",
                actions: ["AXConfirm"],
                enabled: false,
                selected: true,
                focused: true
            )],
            goal: nil
        )
        let text = try #require(rendering).text
        // Short-role rendering matches the legacy summary's (`searchfield`).
        #expect(text.contains("searchfield “Search”"))
        #expect(text.contains("type(confirm)"))
        #expect(text.contains("val “hello”"))
        #expect(text.contains("disabled"))
        #expect(text.contains("selected"))
        #expect(text.contains("focused"))
    }

    @Test func groupsByContainerStatedOnce() throws {
        let matches = [
            Self.match(id: "ax:aaaaaaaaaaaa", label: "Save", role: "AXButton", container: "toolbar: Doc"),
            Self.match(id: "ax:bbbbbbbbbbbb", label: "Share", role: "AXButton", container: "toolbar: Doc"),
            Self.match(id: "ax:cccccccccccc", label: "All iCloud", role: "AXRow", container: "outline: Folders"),
        ]
        let rendering = try #require(AXCompressedObservation.render(matches: matches, goal: nil))
        let occurrences = rendering.text.components(separatedBy: "▸ in toolbar: Doc:").count - 1
        #expect(occurrences == 1)
        #expect(rendering.text.contains("▸ in outline: Folders:"))
        #expect(rendering.metrics.groupCount == 2)
    }

    @Test func emptyInputRendersNothing() {
        #expect(AXCompressedObservation.render(matches: [], goal: "anything") == nil)
    }

    // MARK: - Task-relevant selection

    @Test func selectionKeepsTaskRelevantCandidatesUnderBudget() throws {
        var matches: [AXElementResolver.Match] = []
        for index in 0..<30 {
            matches.append(Self.match(
                id: "ax:" + String(format: "%012x", index),
                label: "Filler \(index)",
                role: "AXButton",
                container: "group: \(index / 4)"
            ))
        }
        matches.append(Self.match(
            id: "ax:feedfacefeed",
            label: "Privacy & Security",
            role: "AXButton",
            container: "group: 99"
        ))
        let rendering = try #require(AXCompressedObservation.render(
            matches: matches,
            goal: "open Privacy and Security settings",
            maxCandidates: 10
        ))
        #expect(rendering.text.contains("Privacy & Security"))
        #expect(rendering.metrics.renderedCandidateCount == 10)
        #expect(rendering.metrics.prunedCandidateCount == matches.count - 10)
        #expect(rendering.metrics.taskRelevantCount >= 1)
    }

    @Test func selectionIsDeterministicAndPreservesScreenOrder() throws {
        let matches = (0..<8).map { index in
            Self.match(
                id: "ax:" + String(format: "%012x", index),
                label: "Button \(index)",
                role: "AXButton",
                container: "toolbar: App"
            )
        }
        let first = try #require(AXCompressedObservation.render(matches: matches, goal: nil, maxCandidates: 5))
        let second = try #require(AXCompressedObservation.render(matches: matches, goal: nil, maxCandidates: 5))
        #expect(first == second)
        // No goal signal → pure truncation in screen order.
        #expect(first.text.contains("Button 0"))
        #expect(first.text.contains("Button 4"))
        #expect(!first.text.contains("Button 5"))
    }

    @Test func perGroupCapStopsOneGroupFlooding() throws {
        var matches = (0..<12).map { index in
            Self.match(
                id: "ax:" + String(format: "%012x", index),
                label: "Row \(index)",
                role: "AXRow",
                container: "table: Big"
            )
        }
        matches.append(Self.match(
            id: "ax:0000dddd0000",
            label: "Done",
            role: "AXButton",
            container: "toolbar: App"
        ))
        let rendering = try #require(AXCompressedObservation.render(
            matches: matches,
            goal: nil,
            maxPerGroup: 4
        ))
        #expect(rendering.metrics.renderedCandidateCount == 5)
        #expect(rendering.text.contains("“Done”"))
    }

    @Test func relevanceMatchesWordsAndPrefixes() {
        let note = Self.match(id: "ax:111111111111", label: "New Note", role: "AXButton")
        let unrelated = Self.match(id: "ax:222222222222", label: "Format", role: "AXButton")
        let goalWords = AXCompressedObservation.relevanceWords(fromGoal: "open Notes and type hello")
        #expect(AXCompressedObservation.relevance(of: note, toGoalWords: goalWords) > 0)
        #expect(AXCompressedObservation.relevance(of: unrelated, toGoalWords: goalWords) == 0)
    }

    // MARK: - Modality

    @Test func modalityFollowsRole() {
        #expect(AXCompressedObservation.modality(role: "AXTextField", supportedActions: []) == .type)
        #expect(AXCompressedObservation.modality(role: "AXCheckBox", supportedActions: []) == .toggle)
        #expect(AXCompressedObservation.modality(role: "AXPopUpButton", supportedActions: []) == .select)
        #expect(AXCompressedObservation.modality(role: "AXSlider", supportedActions: []) == .adjust)
        #expect(AXCompressedObservation.modality(role: "AXDisclosureTriangle", supportedActions: []) == .disclose)
        #expect(AXCompressedObservation.modality(role: "AXButton", supportedActions: ["AXPress"]) == .click)
        #expect(AXCompressedObservation.modality(role: "AXGroup", supportedActions: ["AXShowMenu"]) == .select)
    }

    // MARK: - Stable display ids

    @Test func displayIDsShortenAndStayUniqueOnCollision() {
        let ids = AXCompressedObservation.uniqueDisplayIDs(for: [
            "ax:0123456789ab",
            "ax:01234567ffff",
            "ax:aaaabbbbcccc",
        ])
        #expect(Set(ids).count == 3)
        // Colliding 8-char prefixes extend rather than alias each other.
        #expect(ids[0] != ids[1])
        #expect(ids[2] == "ax:aaaabbbb")
    }

    @Test func identicalFullIDsStillRenderDistinctly() {
        let ids = AXCompressedObservation.uniqueDisplayIDs(for: [
            "ax:0123456789ab",
            "ax:0123456789ab",
        ])
        #expect(Set(ids).count == 2)
    }

    // MARK: - Metrics / audit

    @Test func metricsAreCountsOnlyAndTrackCompression() throws {
        let matches = (0..<6).map { index in
            Self.match(
                id: "ax:" + String(format: "%012x", index),
                label: "Control \(index)",
                role: "AXButton",
                container: "toolbar: App"
            )
        }
        let baseline = AXElementResolver.interactableSummary(matches) ?? ""
        let rendering = try #require(AXCompressedObservation.render(
            matches: matches,
            goal: "press control 3",
            baselineCharacterCount: baseline.count
        ))
        let detail = rendering.metrics.safeAuditDetail
        #expect(detail.contains("axObsCandidates=6"))
        #expect(detail.contains("axObsRendered=6"))
        #expect(detail.contains("axObsGroups=1"))
        #expect(detail.contains("axObsApproxTokens="))
        #expect(detail.contains("axObsBaselineApproxTokens="))
        // Counts only: no label text, no coordinates in the audit detail.
        #expect(!detail.contains("Control"))
        #expect(!detail.contains("toolbar"))
        for token in detail.split(separator: " ") {
            #expect(token.contains("="))
        }
        #expect(rendering.metrics.approximateTokenCount == (rendering.text.count + 3) / 4)
    }

    @Test func flagKeyIsTheExperimentalFamilyKey() {
        #expect(AXCompressedObservation.flagKey == "cascade.experimentalCompressedObservation")
    }
}
