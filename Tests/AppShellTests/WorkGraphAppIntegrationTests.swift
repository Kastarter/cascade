import CascadeMemory
import Foundation
import Testing

@testable import AppShell

private func makeAppShellWorkGraphStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeWorkGraphAppIT-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func appShellWorkGraphContext() -> RecordedContext {
    RecordedContext(
        capturedAt: Date(timeIntervalSince1970: 1_780_000_000),
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Hiring Review",
        ocrText: """
        Owner: Ada Lovelace reviewed /Users/khalidsh/Reports/Q2.csv \
        for the 2026-06-26 hiring plan.
        """
    )
}

@MainActor @Test
func appCreatedRecorderWorkGraphIndexDefaultsOffAndDoesNotIndex() async throws {
    let defaults = UserDefaults(suiteName: "CascadeWorkGraphOff-\(UUID().uuidString)")!
    let store = try makeAppShellWorkGraphStore()
    let model = try CascadeAppModel(store: store, defaults: defaults, startsSubsystems: false)

    #expect(!CascadeAppModel.experimentalWorkGraphIndexEnabled(defaults: defaults))
    #expect(!model.recorder.configuration.indexWorkGraph)

    _ = try await store.insert(
        appShellWorkGraphContext(),
        indexWorkGraph: model.recorder.configuration.indexWorkGraph
    )

    #expect(try await model.graphTimeline(kind: .app, canonicalValue: "com.apple.safari").isEmpty)
    #expect(try await model.graphTimeline(kind: .window, canonicalValue: "hiring review").isEmpty)
    #expect(try await model.graphTimeline(kind: .person, canonicalValue: "ada lovelace").isEmpty)
    #expect(try await model.graphTimeline(kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv").isEmpty)
}

@MainActor @Test
func appCreatedRecorderWorkGraphIndexOptInCreatesReachableTimeline() async throws {
    let defaults = UserDefaults(suiteName: "CascadeWorkGraphOn-\(UUID().uuidString)")!
    defaults.set(true, forKey: CascadeAppModel.experimentalWorkGraphIndexKey)
    let store = try makeAppShellWorkGraphStore()
    let model = try CascadeAppModel(store: store, defaults: defaults, startsSubsystems: false)

    #expect(CascadeAppModel.experimentalWorkGraphIndexEnabled(defaults: defaults))
    #expect(model.recorder.configuration.indexWorkGraph)

    let context = try await store.insert(
        appShellWorkGraphContext(),
        indexWorkGraph: model.recorder.configuration.indexWorkGraph
    )

    let appTimeline = try await model.graphTimeline(kind: .app, canonicalValue: "com.apple.safari")
    let windowTimeline = try await model.graphTimeline(kind: .window, canonicalValue: "hiring review")
    let personTimeline = try await model.graphTimeline(kind: .person, canonicalValue: "ada lovelace")
    let fileTimeline = try await model.graphTimeline(kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv")

    #expect(appTimeline.map(\.contextID) == [context.id])
    #expect(windowTimeline.map(\.contextID) == [context.id])
    #expect(personTimeline.map(\.contextID) == [context.id])
    #expect(fileTimeline.map(\.contextID) == [context.id])
    #expect((appTimeline + windowTimeline + personTimeline + fileTimeline).allSatisfy { $0.relation == "observed" })
}
