import CascadeMemory
import Foundation
import Testing

@Test
func fleetMetricsOnlySerializeAllowlistedCounters() throws {
    let policy = AnalyticsPrivacyPolicy(clippingBounds: FleetClippingBounds(minimum: 0, maximum: 10), minCohort: 25)
    let candidates: [String: FleetMetricInput] = [
        "recorded_context.count": .counter(12),
        "agent.run.completed.count": .counter(4),
        "model.call.count": .counter(-3),
        "recorded_context.ocrText": .text("Project Borealis secret OCR"),
        "input_event.text": .text("typed payroll note"),
        "recipe_step.ocrAnchor": .text("Submit reimbursement"),
        "recipe_step.text": .text("typed invoice amount"),
        "trace_span.name": .text("clicked private action"),
        "/Users/khalid/private/payroll.csv": .text("local path"),
        "https://example.test/private?token=abc": .text("private url"),
        "assistant.prompt": .text("summarize confidential review"),
        "tool.payload": .payload("{\"email\":\"jane@example.com\"}"),
        "recorded_context.count.label": .text("not a counter"),
        "unknown.metric": .counter(1)
    ]

    let export = policy.export(candidates: candidates, sourceAuditHead: AuditHead(count: 3, hash: "abc123"))
    let metricNames = export.metrics.map(\.name)

    #expect(metricNames == ["agent.run.completed.count", "model.call.count", "recorded_context.count"])
    #expect(export.metrics.first { $0.name == "recorded_context.count" }?.value == 10)
    #expect(export.metrics.first { $0.name == "recorded_context.count" }?.wasClipped == true)
    #expect(export.metrics.first { $0.name == "model.call.count" }?.value == 0)
    #expect(export.metrics.first { $0.name == "model.call.count" }?.wasClipped == true)
    #expect(export.manifest.minCohort == 25)
    #expect(export.manifest.sourceAuditHead == AuditHead(count: 3, hash: "abc123"))
    #expect(export.manifest.omittedFields == [
        "input_event_fields",
        "non_allowlisted_fields",
        "ocr_fields",
        "path_fields",
        "prompt_fields",
        "recipe_step_fields",
        "recorded_context_fields",
        "tool_payload_fields",
        "trace_span_fields",
        "url_fields"
    ])
}

@Test
func fleetSerializationDoesNotLeakForbiddenValues() throws {
    let policy = AnalyticsPrivacyPolicy(clippingBounds: FleetClippingBounds(minimum: 0, maximum: 5))
    let data = try policy.serialize(candidates: [
        "agent.run.completed.count": .counter(8),
        "recorded_context.imagePath": .text("/Users/khalid/Frames/private.png"),
        "recorded_context.metadataJSON": .payload("{\"windowTitle\":\"Compensation Planning\"}"),
        "input_event.text": .text("bonus adjustment"),
        "recipe_step.text": .text("paste employee salary"),
        "trace_span.attributes": .payload("{\"prompt\":\"rank these people\"}"),
        "https://internal.example/payroll": .text("payroll url"),
        "tool.output.payload": .payload("{\"token\":\"secret\"}")
    ])
    let json = String(decoding: data, as: UTF8.self)

    #expect(json.contains("\"agent.run.completed.count\""))
    #expect(json.contains("\"value\":5"))
    #expect(json.contains("\"wasClipped\":true"))
    #expect(!json.contains("/Users/khalid/Frames/private.png"))
    #expect(!json.contains("Compensation Planning"))
    #expect(!json.contains("bonus adjustment"))
    #expect(!json.contains("paste employee salary"))
    #expect(!json.contains("rank these people"))
    #expect(!json.contains("internal.example"))
    #expect(!json.contains("secret"))
}

@Test
func fleetManifestCarriesRequiredPolicyFields() {
    let policy = AnalyticsPrivacyPolicy(
        schemaVersion: 7,
        privacyMode: .aggregateCountersOnly,
        clippingBounds: FleetClippingBounds(minimum: 2, maximum: 9),
        minCohort: 0,
        policyVersion: "policy-fixture",
        allowedCounters: ["tool.call.count"]
    )

    let export = policy.export(candidates: ["tool.call.count": .counter(6)])

    #expect(export.manifest.schemaVersion == 7)
    #expect(export.manifest.privacyMode == .aggregateCountersOnly)
    #expect(export.manifest.clippingBounds == FleetClippingBounds(minimum: 2, maximum: 9))
    #expect(export.manifest.omittedFields.isEmpty)
    #expect(export.manifest.minCohort == 1)
    #expect(export.manifest.sourceAuditHead == nil)
    #expect(export.manifest.policyVersion == "policy-fixture")
    #expect(export.metrics == [FleetMetric(name: "tool.call.count", value: 6, wasClipped: false)])
}
