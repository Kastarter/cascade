import CascadeMemory
import Foundation
import Testing

private func makePreferenceStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadePreferenceEvents-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func preferenceEventsRoundTripAndQueryBySignatureAndAgent() async throws {
    let store = try makePreferenceStore()
    let rawSignature = "click:Refund@Mail|key:Return@Mail"
    let event = try await store.appendPreferenceEvent(PreferenceEvent(
        kind: .agentApproved,
        reward: 1,
        surface: "manager.review",
        appName: "Mail",
        workflowSignature: rawSignature,
        agentID: 42,
        featureJSON: #"{"candidateType":"curatedAgent","backgroundCapable":"false"}"#,
        evidenceJSON: #"{"nameHash":"abc","goalHash":"def"}"#
    ))

    let recent = try await store.recentPreferenceEvents(limit: 10)
    let bySignature = try await store.preferenceEvents(workflowSignature: rawSignature, limit: 10)
    let byAgent = try await store.preferenceEvents(agentID: 42, limit: 10)

    #expect(event.id > 0)
    #expect(recent.count == 1)
    #expect(bySignature.first?.id == event.id)
    #expect(byAgent.first?.id == event.id)
    #expect(recent.first?.workflowSignature == AuditIdentity.hash(rawSignature))
}

@Test
func preferenceEventsUpdateRoutineProfilesByHourAndWeekday() async throws {
    let store = try makePreferenceStore()
    let date = Date(timeIntervalSince1970: 1_720_000_000)
    try await store.appendPreferenceEvent(PreferenceEvent(
        createdAt: date,
        kind: .proactiveOfferShown,
        reward: 0,
        surface: "proactive",
        appName: "Safari",
        workflowSignature: "background-web:gmail",
        featureJSON: #"{"candidateType":"backgroundWebAgent"}"#
    ))
    try await store.appendPreferenceEvent(PreferenceEvent(
        createdAt: date,
        kind: .proactiveAccepted,
        reward: 0.8,
        surface: "proactive",
        appName: "Safari",
        workflowSignature: "background-web:gmail",
        featureJSON: #"{"candidateType":"backgroundWebAgent"}"#
    ))

    let profile = try #require(try await store.routineProfiles(limit: 10).first)

    #expect(profile.appName == "safari")
    #expect(profile.surface == "proactive")
    #expect(profile.shown == 1)
    #expect(profile.accepted == 1)
    #expect(profile.workflowSignature == AuditIdentity.hash("background-web:gmail"))
}

@Test
func preferenceEventStorageRedactsSensitiveFeatureAndEvidenceText() async throws {
    let store = try makePreferenceStore()
    try await store.appendPreferenceEvent(PreferenceEvent(
        kind: .agentDeclined,
        reward: -1,
        surface: "manager.review",
        appName: "1Password",
        workflowSignature: "password reset for jane@example.com",
        featureJSON: #"{"window":"Password for jane@example.com"}"#,
        evidenceJSON: #"{"label":"bank password jane@example.com"}"#
    ))

    let stored = try #require(try await store.recentPreferenceEvents(limit: 1).first)

    #expect(stored.appName?.contains("1Password") != true)
    #expect(stored.workflowSignature == AuditIdentity.hash("password reset for jane@example.com"))
    #expect(!stored.featureJSON.contains("jane@example.com"))
    #expect(!stored.evidenceJSON.orEmpty.contains("jane@example.com"))
    #expect(!stored.evidenceJSON.orEmpty.lowercased().contains("password"))
}

@Test
func clearingPersonalizationRemovesEventsAndRoutineProfiles() async throws {
    let store = try makePreferenceStore()
    try await store.appendPreferenceEvent(PreferenceEvent(
        kind: .agentDisabled,
        reward: -1,
        surface: "agent.settings",
        appName: "Mail",
        workflowSignature: "mail-flow",
        featureJSON: #"{"candidateType":"savedAgent"}"#
    ))

    try await store.clearPersonalization()

    #expect(try await store.recentPreferenceEvents(limit: 10).isEmpty)
    #expect(try await store.routineProfiles(limit: 10).isEmpty)
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
