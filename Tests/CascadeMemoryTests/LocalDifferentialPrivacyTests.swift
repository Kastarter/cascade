import CascadeMemory
import Foundation
import Testing

private struct SequenceRNG: RandomNumberGenerator {
    var values: [UInt64]
    var index = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    mutating func next() -> UInt64 {
        let value = values[index % values.count]
        index += 1
        return value
    }
}

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Test
func clippedCountAndSumApplyBoundsBeforeNoise() throws {
    var zeroNoiseRNG = SequenceRNG([1 << 63])
    let count = try LocalDifferentialPrivacy.clippedNoisyCount(
        name: "agent.run.completed.count",
        rawValue: 50,
        bounds: FleetClippingBounds(minimum: 0, maximum: 10),
        epsilon: 1,
        rng: &zeroNoiseRNG
    )

    #expect(count.clippedValue == 10)
    #expect(count.value == 10)
    #expect(count.wasClipped)
    #expect(count.mechanism == .laplaceBoundedCount)

    var sumRNG = SequenceRNG([1 << 63])
    let sum = try LocalDifferentialPrivacy.clippedNoisySum(
        name: "agent.reclaimed_seconds.count",
        rawValue: -5,
        bounds: LocalDPDoubleBounds(minimum: 0, maximum: 30),
        epsilon: 1,
        rng: &sumRNG
    )

    #expect(sum.clippedValue == 0)
    #expect(sum.value == 0)
    #expect(sum.wasClipped)
    #expect(sum.mechanism == .laplaceBoundedSum)
}

@Test
func randomizedResponseProbabilityTracksKaryFormulaWithSeededRNG() throws {
    let domain = ["editing", "browser", "calendar", "email"]
    let epsilon = 1.2
    let expectedTruthRate = try LocalDifferentialPrivacy.truthfulProbability(
        epsilon: epsilon,
        domainSize: domain.count
    )
    let trueHash = LocalDifferentialPrivacy.hashedCategory("browser", salt: "tenant-a")
    var rng = SeededRNG(seed: 42)
    var truthfulReports = 0
    let trials = 20_000

    for _ in 0..<trials {
        let report = try LocalDifferentialPrivacy.randomizedResponse(
            name: "workflow.kind",
            category: "browser",
            domain: domain,
            epsilon: epsilon,
            disclosure: .hash,
            hashSalt: "tenant-a",
            rng: &rng
        )
        if report.reportedCategoryHash == trueHash {
            truthfulReports += 1
        }
        #expect(report.domainSize == 4)
        #expect(report.mechanism == .kAryRandomizedResponse)
    }

    let observedTruthRate = Double(truthfulReports) / Double(trials)
    #expect(abs(observedTruthRate - expectedTruthRate) < 0.02)
}

@Test
func monthlyBudgetCompositionCapsSpend() throws {
    var budget = FleetDPMonthlyBudget(period: "2026-06", epsilonCap: 1.0, deltaCap: 0.001)
    let countParameters = try LocalDPPrivacyParameters(epsilon: 0.4, delta: 0, mechanism: .laplaceBoundedCount)
    let categoryParameters = try LocalDPPrivacyParameters(
        epsilon: 0.6,
        delta: 0.0005,
        mechanism: .kAryRandomizedResponse
    )

    let firstSpend = try budget.reserve(metricFamily: "runs", parameters: countParameters)
    let secondSpend = try budget.reserve(metricFamily: "workflow-kind", parameters: categoryParameters)

    #expect(budget.spends == [firstSpend, secondSpend])
    #expect(budget.spentEpsilon == 1.0)
    #expect(budget.spentDelta == 0.0005)
    #expect(throws: LocalDifferentialPrivacyError.monthlyBudgetExceeded) {
        _ = try budget.reserve(metricFamily: "extra", parameters: countParameters)
    }
}

@Test
func categoryDisclosureHashesOrOmitsRawCategories() throws {
    var hashRNG = SequenceRNG([0])
    let hashed = try LocalDifferentialPrivacy.randomizedResponse(
        name: "app.category",
        category: "Finance App With Raw Name",
        domain: ["Finance App With Raw Name"],
        epsilon: 2,
        disclosure: .hash,
        hashSalt: "tenant-secret",
        rng: &hashRNG
    )

    #expect(hashed.reportedCategoryHash == LocalDifferentialPrivacy.hashedCategory(
        "Finance App With Raw Name",
        salt: "tenant-secret"
    ))
    #expect(hashed.reportedCategoryHash != "Finance App With Raw Name")

    var omitRNG = SequenceRNG([0])
    let omitted = try LocalDifferentialPrivacy.randomizedResponse(
        name: "app.category",
        category: "Finance App With Raw Name",
        domain: ["Finance App With Raw Name"],
        epsilon: 2,
        disclosure: .omit,
        hashSalt: "tenant-secret",
        rng: &omitRNG
    )

    #expect(omitted.reportedCategoryHash == nil)
    #expect(omitted.domainSize == 1)
}

@Test
func dpSerializationComposesWithFleetManifestWithoutSensitiveFields() throws {
    let policy = AnalyticsPrivacyPolicy(clippingBounds: FleetClippingBounds(minimum: 0, maximum: 5))
    var rng = SequenceRNG([1 << 63, 1 << 63])
    let parameters = try LocalDPPrivacyParameters(epsilon: 0.5, delta: 0, mechanism: .laplaceBoundedCount)
    var budget = FleetDPMonthlyBudget(period: "2026-06", epsilonCap: 1)
    let spend = try budget.reserve(metricFamily: "counter", parameters: parameters)

    let export = try LocalDifferentialPrivacy.privatizedCounterExport(
        policy: policy,
        candidates: [
            "agent.run.completed.count": .counter(12),
            "recorded_context.ocrText": .text("Raw OCR should not export"),
            "recorded_context.imagePath": .text("/Users/khalid/private/frame.jpg"),
            "https://internal.example/private": .text("private url")
        ],
        epsilon: parameters.epsilon,
        sourceAuditHead: AuditHead(count: 7, hash: "audit-head"),
        budgetSpends: [spend],
        rng: &rng
    )
    let data = try LocalDifferentialPrivacy.serialize(export: export)
    let json = String(decoding: data, as: UTF8.self)

    #expect(export.manifest.sourceAuditHead == AuditHead(count: 7, hash: "audit-head"))
    #expect(export.metrics.first?.name == "agent.run.completed.count")
    #expect(export.metrics.first?.clippedValue == 5)
    #expect(export.metrics.first?.wasClipped == true)
    #expect(json.contains("\"epsilon\":0.5"))
    #expect(json.contains("\"delta\":0"))
    #expect(json.contains("\"mechanism\":\"laplace_bounded_count\""))
    #expect(json.contains("\"budgetSpends\""))
    #expect(!json.contains("Raw OCR should not export"))
    #expect(!json.contains("/Users/khalid/private/frame.jpg"))
    #expect(!json.contains("internal.example"))
    #expect(!json.contains("ocrText"))
    #expect(!json.contains("imagePath"))
}

