import AgentOrchestrator
import CascadeDesignSystem
import SwiftUI

struct TraceExportSheet: View {
    @ObservedObject var model: CascadeAppModel

    private let formats: [(AgentAuditExportFormat, String, String)] = [
        (.otelJSON, "OTel JSON", "Collector-ready OTLP trace envelope"),
        (.siemJSONL, "SIEM JSONL", "One stable event per span"),
        (.csv, "CSV bundle", "traces, spans, costs, and evals"),
        (.reliabilityJSONL, "Reliability JSONL", "Release-gate scenario rows"),
        (.manifestJSON, "Manifest JSON", "Redaction and audit-chain metadata"),
        (.diagnosticBundleMetadata, "Diagnostic metadata", "No screenshots or payloads by default"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            ForEach(formats, id: \.0) { format, title, detail in
                HStack(alignment: .top, spacing: CascadeMetrics.s3) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.cascadeSans(13, .semibold))
                        Text(detail)
                            .font(.cascadeSans(12))
                            .foregroundStyle(Color.cascadeText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Copy") { model.exportAgentAuditToPasteboard(format: format) }
                        .buttonStyle(CascadeQuietButtonStyle())
                    Button("Save") { model.saveAgentAuditExport(format: format) }
                        .buttonStyle(CascadeQuietButtonStyle())
                }
                if format != formats.last?.0 {
                    Divider().overlay(Color.cascadeBorder)
                }
            }
        }
    }
}
