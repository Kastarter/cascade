import CascadeMemory
import Foundation
import Testing

/// §4d perception-anchor write path (t10). These exercise the full ON-path
/// write body headlessly: candidate extraction IS the InputRecorder drain
/// hook's entire logic, and the upsert is both hooks' sink — no CGEvent taps
/// or live AX needed.
struct PerceptionAnchorStoreTests {
    private func makeStore() throws -> CascadeStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerceptionAnchorTests-\(UUID().uuidString).sqlite")
            .path
        return try CascadeStore(path: path)
    }

    @Test
    func testUpsertIncrementsVerifiedCount() async throws {
        let store = try makeStore()
        let bundle = "com.apple.Notes"
        let hash = "hash-abc123"
        let firstJSON = #"{"label":"Save","role":"AXButton","semanticTextHash":"hash-abc123"}"#
        let latestJSON = #"{"label":"Save","role":"AXButton","semanticTextHash":"hash-abc123","frameBucket":"b2"}"#
        let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondAt = Date(timeIntervalSince1970: 1_700_000_100)

        let wroteFirst = try await store.upsertPerceptionAnchor(
            bundleID: bundle, targetTextHash: hash, descriptorJSON: firstJSON,
            source: "human", at: firstAt
        )
        let wroteSecond = try await store.upsertPerceptionAnchor(
            bundleID: bundle, targetTextHash: hash, descriptorJSON: latestJSON,
            source: "agent_verified", at: secondAt
        )
        #expect(wroteFirst)
        #expect(wroteSecond)

        let rows = try await store.perceptionAnchors(bundleID: bundle)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.verifiedCount == 2)
        #expect(row.descriptorJSON == latestJSON)
        #expect(row.source == "agent_verified")
        #expect(row.updatedAt > firstAt)

        // A distinct hash is a distinct anchor, not an increment.
        _ = try await store.upsertPerceptionAnchor(
            bundleID: bundle, targetTextHash: "hash-other", descriptorJSON: firstJSON,
            source: "human", at: secondAt
        )
        let all = try await store.perceptionAnchors(bundleID: bundle)
        #expect(all.count == 2)
        #expect(all.first?.verifiedCount == 2)  // ordered by verified_count DESC
    }

    @Test
    func testAnchorCandidatesFromHumanClicks() throws {
        let phraseHash = try #require(AXTargetDescriptorV2.semanticTextHash(for: "Save button toolbar"))
        let descriptorJSON = try #require(AXTargetDescriptorV2(
            label: "Save",
            role: "AXButton",
            semanticTextHash: phraseHash
        ).encodedJSON())
        let events = [
            InputEvent(
                kind: .click, x: 10, y: 20, text: "Save",
                appName: "Notes", bundleIdentifier: "com.apple.Notes",
                targetDescriptor: descriptorJSON
            ),
            InputEvent(
                kind: .click, x: 30, y: 40,
                appName: "Notes", bundleIdentifier: "com.apple.Notes",
                targetDescriptor: nil  // no descriptor → no candidate
            ),
            InputEvent(
                kind: .key, key: "s", modifiers: ["command"],
                appName: "Notes", bundleIdentifier: "com.apple.Notes"
            ),
        ]

        let candidates = PerceptionAnchorWriter.anchorCandidates(from: events)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.bundleID == "com.apple.Notes")
        #expect(candidate.textHash == phraseHash)
        #expect(candidate.descriptorJSON == descriptorJSON)
    }

    @Test
    func testCandidateSkippedWithoutTextHash() {
        // Descriptor JSON with neither semanticTextHash nor semanticHash:
        // skipped — missed, never false (LAW 7).
        let hashlessJSON = #"{"label":"Save","role":"AXButton"}"#
        let events = [
            InputEvent(
                kind: .click, x: 10, y: 20, text: "Save",
                appName: "Notes", bundleIdentifier: "com.apple.Notes",
                targetDescriptor: hashlessJSON
            ),
        ]
        #expect(PerceptionAnchorWriter.anchorCandidates(from: events).isEmpty)
    }

    @Test
    func testFlagDefaultOff() throws {
        let suite = "PerceptionAnchorFlagTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PerceptionAnchorWriteFlag.isEnabled(defaults: defaults) == false)
        defaults.set(true, forKey: PerceptionAnchorWriteFlag.key)
        #expect(PerceptionAnchorWriteFlag.isEnabled(defaults: defaults) == true)
    }
}
