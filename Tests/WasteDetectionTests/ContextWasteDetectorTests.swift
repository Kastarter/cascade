import CascadeMemory
import Foundation
@testable import WasteDetection
import Testing

private let contextBase = Date(timeIntervalSince1970: 1_700_100_000)

private func context(
    id: Int64,
    at seconds: TimeInterval,
    app: String = "QuickBooks",
    bundle: String? = "com.intuit.quickbooks",
    title: String = "Vendor invoice queue",
    ocr: String,
    metadataJSON: String? = nil,
    safeToShow: Bool = true,
    safeToSummarize: Bool = true
) -> RecordedContext {
    RecordedContext(
        id: id,
        capturedAt: contextBase.addingTimeInterval(seconds),
        source: .screen,
        appName: app,
        bundleIdentifier: bundle,
        windowTitle: title,
        ocrText: ocr,
        metadataJSON: metadataJSON,
        safeToShow: safeToShow,
        safeToSummarize: safeToSummarize
    )
}

private func session(
    idStart: Int64,
    start: TimeInterval,
    duration: TimeInterval,
    app: String = "QuickBooks",
    bundle: String? = "com.intuit.quickbooks",
    title: String = "Vendor invoice queue",
    ocr: String = "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
    metadataJSON: String? = #"{"project":"Vendor invoices"}"#,
    safeToShow: Bool = true,
    safeToSummarize: Bool = true
) -> [RecordedContext] {
    stride(from: 0.0, through: duration, by: 300.0).enumerated().map { offset, elapsed in
        context(
            id: idStart + Int64(offset),
            at: start + elapsed,
            app: app,
            bundle: bundle,
            title: title,
            ocr: ocr,
            metadataJSON: metadataJSON,
            safeToShow: safeToShow,
            safeToSummarize: safeToSummarize
        )
    }
}

@Test
func contextWasteDetectsThreeHoursOfRepeatedRealWork() {
    let contexts =
        session(idStart: 1, start: 0, duration: 3_600)
        + session(idStart: 100, start: 7_200, duration: 3_600)
        + session(idStart: 200, start: 14_400, duration: 3_600)

    let results = ContextWasteDetector().detect(contexts: contexts)

    let waste = try? #require(results.first)
    #expect(results.count == 1)
    #expect(waste?.occurrences == 3)
    #expect(waste?.estimatedTotalSeconds == 10_800)
    #expect(waste?.apps == ["QuickBooks"])
    #expect(waste?.feasibility == .goalOnlyCandidate)
    #expect(waste?.evidenceContextIDs.count == contexts.count)
    #expect(waste?.title.lowercased().contains("invoice") == true)
}

@Test
func contextWasteMergesSameProcessAcrossDifferentProjects() {
    let acme =
        session(idStart: 1, start: 0, duration: 1_200, title: "Acme invoice queue", metadataJSON: #"{"project":"Acme invoices"}"#)
        + session(idStart: 100, start: 3_600, duration: 1_200, title: "Acme invoice queue", metadataJSON: #"{"project":"Acme invoices"}"#)
        + session(idStart: 200, start: 7_200, duration: 1_200, title: "Acme invoice queue", metadataJSON: #"{"project":"Acme invoices"}"#)
    let beta =
        session(idStart: 300, start: 10_800, duration: 1_200, title: "Beta invoice queue", metadataJSON: #"{"project":"Beta invoices"}"#)
        + session(idStart: 400, start: 14_400, duration: 1_200, title: "Beta invoice queue", metadataJSON: #"{"project":"Beta invoices"}"#)
        + session(idStart: 500, start: 18_000, duration: 1_200, title: "Beta invoice queue", metadataJSON: #"{"project":"Beta invoices"}"#)

    let results = ContextWasteDetector().detect(contexts: acme + beta, maxResults: 5)

    let waste = try? #require(results.first)
    #expect(results.count == 1)
    #expect(waste?.occurrences == 6)
    #expect(waste?.estimatedTotalSeconds == 7_200)
    #expect(waste?.signature.contains("context-process:v3") == true)
    #expect(waste?.signature.lowercased().contains("acme") == false)
    #expect(waste?.signature.lowercased().contains("beta") == false)
    #expect(waste?.title.lowercased().contains("invoice") == true)
    #expect(waste?.title.lowercased().contains("acme") == false)
    #expect(waste?.title.lowercased().contains("beta") == false)
    #expect(waste?.suggestedGoal.lowercased().contains("acme") == false)
    #expect(waste?.suggestedGoal.lowercased().contains("beta") == false)
    let parameters = waste?.parameters ?? []
    #expect(parameters.contains { $0.role == "project" || $0.role == "record_name" })
    #expect(parameters.flatMap(\.valueShapes).isEmpty == false)
    #expect(parameters.flatMap(\.valueHashes).joined().lowercased().contains("acme") == false)
    #expect(parameters.flatMap(\.valueHashes).joined().lowercased().contains("beta") == false)
    let entityValues = results.flatMap(\.entities).flatMap { [$0.displayName, $0.canonicalValue] }.joined(separator: " ").lowercased()
    #expect(!entityValues.contains("acme"))
    #expect(!entityValues.contains("beta"))
}

@Test
func contextWasteGroupsStructuredFormsByFieldRolesNotValues() {
    let metadata: [(String, String, String, String)] = [
        ("Acme Corp", "INV-001", "$120.00", "2026-07-15"),
        ("Beta LLC", "INV-002", "$340.00", "2026-07-16"),
        ("Contoso", "INV-003", "$560.00", "2026-07-17"),
    ]
    let contexts = metadata.enumerated().flatMap { index, values in
        let (customer, invoice, total, dueDate) = values
        let fields = """
        {"structured":{"fields":[
        {"key":"Customer","value":"\(customer)"},
        {"key":"Invoice #","value":"\(invoice)"},
        {"key":"Total","value":"\(total)"},
        {"key":"Due Date","value":"\(dueDate)"}
        ]}}
        """
        return session(
            idStart: Int64(index * 100 + 1),
            start: TimeInterval(index * 3_600),
            duration: 1_200,
            title: "\(customer) invoice form",
            ocr: "Review invoice form, verify total, and update paid status.",
            metadataJSON: fields
        )
    }

    let report = ContextWasteDetector().detectReport(contexts: contexts, maxResults: 5)
    let results = report.results
    let waste = try? #require(results.first)

    #expect(report.safeContextCount == contexts.count)
    #expect(report.sessionCount == 3)
    #expect(report.groupedCount == 1)
    #expect(results.count == 1)
    #expect(waste?.occurrences == 3)
    #expect(waste?.signature.lowercased().contains("acme") == false)
    #expect(waste?.signature.lowercased().contains("beta") == false)
    #expect(waste?.parameters.contains { $0.role == "business_object" && $0.sourceKind == "field" } == true)
    #expect(waste?.parameters.contains { $0.role == "invoice_id" && $0.sourceKind == "field" } == true)
    #expect(waste?.parameters.contains { $0.role == "total" && $0.sourceKind == "field" } == true)
    #expect(waste?.parameters.contains { $0.role == "date" && $0.sourceKind == "field" } == true)
}

@Test
func contextWasteClustersSameProcessAcrossDifferentApps() {
    let quickBooks =
        session(
            idStart: 1,
            start: 0,
            duration: 1_200,
            app: "QuickBooks",
            bundle: "com.intuit.quickbooks",
            title: "Vendor invoice queue",
            ocr: "Review vendor invoice queue, verify invoice total, and mark status paid.",
            metadataJSON: #"{"fields":[{"key":"Vendor","value":"Acme Corp"},{"key":"Invoice #","value":"INV-001"},{"key":"Total","value":"$120.00"}]}"#
        )
        + session(
            idStart: 100,
            start: 3_600,
            duration: 1_200,
            app: "Xero",
            bundle: "com.xero.desktop",
            title: "Payables bill queue",
            ocr: "Review supplier bill queue, verify bill total, and mark status paid.",
            metadataJSON: #"{"fields":[{"key":"Vendor","value":"Beta LLC"},{"key":"Invoice #","value":"BILL-002"},{"key":"Total","value":"$340.00"}]}"#
        )
        + session(
            idStart: 200,
            start: 7_200,
            duration: 1_200,
            app: "NetSuite",
            bundle: "com.netsuite.app",
            title: "Accounts payable invoice review",
            ocr: "Review vendor payable queue, verify invoice total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Vendor","value":"Contoso"},{"key":"Invoice #","value":"AP-003"},{"key":"Total","value":"$560.00"}]}"#
        )

    let results = ContextWasteDetector().detect(contexts: quickBooks, maxResults: 5)

    let waste = try? #require(results.first)
    #expect(results.count == 1)
    #expect(waste?.occurrences == 3)
    #expect(Set(waste?.apps ?? []) == ["NetSuite", "QuickBooks", "Xero"])
    #expect(waste?.signature.contains("context-process:v3") == true)
    #expect(waste?.signature.lowercased().contains("acme") == false)
    #expect(waste?.signature.lowercased().contains("beta") == false)
    #expect(waste?.signature.lowercased().contains("contoso") == false)
}

@Test
func contextWasteGroupsStructuredTablesByHeadersNotRows() {
    let rows = [
        ("Acme Corp", "INV-101", "$120.00"),
        ("Beta LLC", "INV-102", "$340.00"),
        ("Contoso", "INV-103", "$560.00"),
    ]
    let contexts = rows.enumerated().flatMap { index, row in
        let metadata = """
        {"structured":{"tables":[{"rows":[
        ["Customer","Invoice #","Status","Total"],
        ["\(row.0)","\(row.1)","Paid","\(row.2)"]
        ]}]}}
        """
        return session(
            idStart: Int64(index * 100 + 1),
            start: TimeInterval(index * 3_600),
            duration: 1_200,
            title: "\(row.0) invoice table",
            ocr: "Review invoice table and update paid status.",
            metadataJSON: metadata
        )
    }

    let report = ContextWasteDetector().detectReport(contexts: contexts, maxResults: 5)
    let results = report.results
    let waste = try? #require(results.first)

    #expect(report.safeContextCount == contexts.count)
    #expect(report.sessionCount == 3)
    #expect(report.groupedCount == 1)
    #expect(results.count == 1)
    #expect(waste?.occurrences == 3)
    #expect(waste?.parameters.contains { $0.role == "business_object" && $0.sourceKind == "table" } == true)
    #expect(waste?.parameters.contains { $0.role == "invoice_id" && $0.sourceKind == "table" } == true)
    #expect(waste?.parameters.contains { $0.role == "total" && $0.sourceKind == "table" } == true)
}

@Test
func contextWasteSplitsDifferentProcessesInSameApp() {
    let invoices =
        session(idStart: 1, start: 0, duration: 1_200, title: "Acme invoice queue", metadataJSON: #"{"project":"Acme invoices"}"#)
        + session(idStart: 100, start: 3_600, duration: 1_200, title: "Acme invoice queue", metadataJSON: #"{"project":"Acme invoices"}"#)
        + session(idStart: 200, start: 7_200, duration: 1_200, title: "Acme invoice queue", metadataJSON: #"{"project":"Acme invoices"}"#)
    let tickets =
        session(
            idStart: 300,
            start: 10_800,
            duration: 1_200,
            title: "Acme support tickets",
            ocr: "Triage support ticket queue, update case status, and assign owner.",
            metadataJSON: #"{"project":"Acme support"}"#
        )
        + session(
            idStart: 400,
            start: 14_400,
            duration: 1_200,
            title: "Acme support tickets",
            ocr: "Triage support ticket queue, update case status, and assign owner.",
            metadataJSON: #"{"project":"Acme support"}"#
        )
        + session(
            idStart: 500,
            start: 18_000,
            duration: 1_200,
            title: "Acme support tickets",
            ocr: "Triage support ticket queue, update case status, and assign owner.",
            metadataJSON: #"{"project":"Acme support"}"#
        )

    let results = ContextWasteDetector().detect(contexts: invoices + tickets, maxResults: 5)

    #expect(results.count == 2)
    #expect(Set(results.map(\.signature)).count == 2)
    #expect(results.allSatisfy { $0.occurrences == 3 })
    let titles = results.map { $0.title.lowercased() }
    #expect(titles.contains { $0.contains("invoice") })
    #expect(titles.contains { $0.contains("ticket") })
}

@Test
func contextWasteExcludesUnsafeContexts() {
    let hidden =
        session(idStart: 1, start: 0, duration: 3_600, safeToSummarize: false)
        + session(idStart: 100, start: 7_200, duration: 3_600, safeToSummarize: false)
        + session(idStart: 200, start: 14_400, duration: 3_600, safeToSummarize: false)
    let sensitive =
        session(
            idStart: 300,
            start: 21_600,
            duration: 3_600,
            app: "Bank Portal",
            bundle: "com.example.bank",
            title: "Bank account",
            ocr: "Review account number and routing number",
            metadataJSON: nil
        )

    let report = ContextWasteDetector().detectReport(contexts: hidden + sensitive)

    #expect(report.safeContextCount == 0)
    #expect(report.results.isEmpty)
}

@Test
func contextWasteDoesNotPromotePassiveBrowsing() {
    let contexts =
        session(
            idStart: 1,
            start: 0,
            duration: 3_600,
            app: "Safari",
            bundle: "com.apple.Safari",
            title: "News article",
            ocr: "Reading a news article and blog post about product launches.",
            metadataJSON: nil
        )
        + session(
            idStart: 100,
            start: 7_200,
            duration: 3_600,
            app: "Safari",
            bundle: "com.apple.Safari",
            title: "News article",
            ocr: "Reading a news article and blog post about product launches.",
            metadataJSON: nil
        )
        + session(
            idStart: 200,
            start: 14_400,
            duration: 3_600,
            app: "Safari",
            bundle: "com.apple.Safari",
            title: "News article",
            ocr: "Reading a news article and blog post about product launches.",
            metadataJSON: nil
        )

    #expect(ContextWasteDetector().detect(contexts: contexts).isEmpty)
}

@Test
func contextWasteDoesNotPromoteClickScrollOnlyContexts() {
    let contexts =
        session(
            idStart: 1,
            start: 0,
            duration: 3_600,
            app: "Internal Tool",
            bundle: "com.example.tool",
            title: "Click next page",
            ocr: "Click next, scroll page, click button."
        )
        + session(
            idStart: 100,
            start: 7_200,
            duration: 3_600,
            app: "Internal Tool",
            bundle: "com.example.tool",
            title: "Click next page",
            ocr: "Click next, scroll page, click button."
        )
        + session(
            idStart: 200,
            start: 14_400,
            duration: 3_600,
            app: "Internal Tool",
            bundle: "com.example.tool",
            title: "Click next page",
            ocr: "Click next, scroll page, click button."
        )

    #expect(ContextWasteDetector().detect(contexts: contexts).isEmpty)
}

@Test
func contextWasteDropsNonAllowlistedOCRTokensFromProcessTerms() throws {
    let contexts =
        session(
            idStart: 1,
            start: 0,
            duration: 1_200,
            title: "Receipt status",
            ocr: "Review PhoenixLabs receipt status and mark receipt paid.",
            metadataJSON: nil
        )
        + session(
            idStart: 100,
            start: 3_600,
            duration: 1_200,
            title: "Receipt status",
            ocr: "Review PhoenixLabs receipt status and mark receipt paid.",
            metadataJSON: nil
        )
        + session(
            idStart: 200,
            start: 7_200,
            duration: 1_200,
            title: "Receipt status",
            ocr: "Review PhoenixLabs receipt status and mark receipt paid.",
            metadataJSON: nil
        )

    let waste = try #require(ContextWasteDetector().detect(contexts: contexts).first)

    #expect(!waste.processTerms.contains("phoenixlabs"))
    #expect(!waste.title.lowercased().contains("phoenixlabs"))
    #expect(!waste.suggestedGoal.lowercased().contains("phoenixlabs"))
}

@Test
func contextWasteDoesNotMergeDifferentGenericSameAppWork() {
    let exports =
        session(
            idStart: 1,
            start: 0,
            duration: 1_200,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Weekly export queue",
            ocr: "Review export queue, update report status, and upload spreadsheet."
        )
        + session(
            idStart: 100,
            start: 3_600,
            duration: 1_200,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Weekly export queue",
            ocr: "Review export queue, update report status, and upload spreadsheet."
        )
        + session(
            idStart: 200,
            start: 7_200,
            duration: 1_200,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Weekly export queue",
            ocr: "Review export queue, update report status, and upload spreadsheet."
        )
    let approvals =
        session(
            idStart: 300,
            start: 10_800,
            duration: 1_200,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Approval task queue",
            ocr: "Review approval queue, update task status, and submit vendor approval."
        )
        + session(
            idStart: 400,
            start: 14_400,
            duration: 1_200,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Approval task queue",
            ocr: "Review approval queue, update task status, and submit vendor approval."
        )
        + session(
            idStart: 500,
            start: 18_000,
            duration: 1_200,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Approval task queue",
            ocr: "Review approval queue, update task status, and submit vendor approval."
        )

    let results = ContextWasteDetector().detect(contexts: exports + approvals, maxResults: 5)

    #expect(results.count == 2)
    #expect(Set(results.map(\.signature)).count == 2)
}

@Test
func contextWasteSplitsSameAppABAIntoSeparateTaskEpisodes() {
    let contexts: [RecordedContext] =
        context(
            id: 1,
            at: 0,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Acme invoice queue",
            ocr: "Review invoice queue, verify total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Invoice #","value":"INV-001"},{"key":"Total","value":"$120.00"}]}"#
        )
        .asArray
        + context(
            id: 2,
            at: 120,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Acme invoice queue",
            ocr: "Review invoice queue, verify total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Invoice #","value":"INV-001"},{"key":"Total","value":"$120.00"}]}"#
        )
        .asArray
        + context(
            id: 4,
            at: 240,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Ticket triage",
            ocr: "Triage support ticket queue, assign owner, and update case status.",
            metadataJSON: #"{"fields":[{"key":"Ticket ID","value":"TCK-101"},{"key":"Owner","value":"Maya"}]}"#
        )
        .asArray
        + context(
            id: 3,
            at: 360,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Ticket triage",
            ocr: "Triage support ticket queue, assign owner, and update case status.",
            metadataJSON: #"{"fields":[{"key":"Ticket ID","value":"TCK-101"},{"key":"Owner","value":"Maya"}]}"#
        )
        .asArray
        + context(
            id: 5,
            at: 480,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Beta invoice queue",
            ocr: "Review invoice queue, verify total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Invoice #","value":"INV-002"},{"key":"Total","value":"$340.00"}]}"#
        )
        .asArray
        + context(
            id: 6,
            at: 600,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Beta invoice queue",
            ocr: "Review invoice queue, verify total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Invoice #","value":"INV-002"},{"key":"Total","value":"$340.00"}]}"#
        )
        .asArray
        + session(
            idStart: 100,
            start: 3_600,
            duration: 600,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Contoso invoice queue",
            ocr: "Review invoice queue, verify total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Invoice #","value":"INV-003"},{"key":"Total","value":"$560.00"}]}"#
        )
        + session(
            idStart: 200,
            start: 7_200,
            duration: 600,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Support ticket triage",
            ocr: "Triage support ticket queue, assign owner, and update case status.",
            metadataJSON: #"{"fields":[{"key":"Ticket ID","value":"TCK-102"},{"key":"Owner","value":"Noah"}]}"#
        )
        + session(
            idStart: 250,
            start: 9_000,
            duration: 600,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Support ticket triage",
            ocr: "Triage support ticket queue, assign owner, and update case status.",
            metadataJSON: #"{"fields":[{"key":"Ticket ID","value":"TCK-103"},{"key":"Owner","value":"Ava"}]}"#
        )
        + session(
            idStart: 300,
            start: 10_800,
            duration: 600,
            app: "Ops Console",
            bundle: "com.example.ops",
            title: "Delta invoice queue",
            ocr: "Review invoice queue, verify total, and update paid status.",
            metadataJSON: #"{"fields":[{"key":"Invoice #","value":"INV-004"},{"key":"Total","value":"$780.00"}]}"#
        )

    let report = ContextWasteDetector().detectReport(contexts: contexts, maxResults: 5)

    #expect(report.refinedEpisodeCount > report.sessionCount)
    #expect(report.results.contains { $0.title.lowercased().contains("invoice") })
    #expect(report.results.contains { $0.title.lowercased().contains("ticket") })
}

@Test
func contextWasteCanEmitTwoLongRepeatedSessions() {
    let contexts =
        session(idStart: 1, start: 0, duration: 1_800)
        + session(idStart: 100, start: 7_200, duration: 1_800)

    let results = ContextWasteDetector().detect(contexts: contexts)

    let waste = try? #require(results.first)
    #expect(results.count == 1)
    #expect(waste?.occurrences == 2)
    #expect(waste?.estimatedTotalSeconds == 3_600)
}

@Test
func contextWasteBuildsTaskEpisodesAcrossShortRelatedAppSwitches() {
    var contexts: [RecordedContext] = []
    var id: Int64 = 1
    for run in 0..<3 {
        let start = TimeInterval(run * 3_600)
        let fields = #"{"fields":[{"key":"Vendor","value":"Vendor \#(run)"},{"key":"Invoice #","value":"INV-10\#(run)"},{"key":"Total","value":"$12\#(run).00"}]}"#
        contexts.append(context(
            id: id,
            at: start,
            app: "Mail",
            bundle: "com.apple.mail",
            title: "Invoice email",
            ocr: "Review vendor invoice email, capture invoice total and invoice number.",
            metadataJSON: fields
        )); id += 1
        contexts.append(context(
            id: id,
            at: start + 45,
            app: "Mail",
            bundle: "com.apple.mail",
            title: "Invoice email",
            ocr: "Review vendor invoice email, capture invoice total and invoice number.",
            metadataJSON: fields
        )); id += 1
        contexts.append(context(
            id: id,
            at: start + 46,
            app: "QuickBooks",
            bundle: "com.intuit.quickbooks",
            title: "Vendor invoice queue",
            ocr: "Update vendor invoice queue, enter invoice total, and mark status paid.",
            metadataJSON: fields
        )); id += 1
        contexts.append(context(
            id: id,
            at: start + 91,
            app: "QuickBooks",
            bundle: "com.intuit.quickbooks",
            title: "Vendor invoice queue",
            ocr: "Update vendor invoice queue, enter invoice total, and mark status paid.",
            metadataJSON: fields
        )); id += 1
        contexts.append(context(
            id: id,
            at: start + 92,
            app: "Numbers",
            bundle: "com.apple.Numbers",
            title: "Invoice tracker",
            ocr: "Update invoice tracker spreadsheet row with invoice total and paid status.",
            metadataJSON: fields
        )); id += 1
        contexts.append(context(
            id: id,
            at: start + 137,
            app: "Numbers",
            bundle: "com.apple.Numbers",
            title: "Invoice tracker",
            ocr: "Update invoice tracker spreadsheet row with invoice total and paid status.",
            metadataJSON: fields
        )); id += 1
    }

    let report = ContextWasteDetector().detectReport(contexts: contexts, maxResults: 5)
    let waste = try? #require(report.results.first)

    #expect(report.sessionCount == 9)
    #expect(report.refinedEpisodeCount == 3)
    #expect(report.results.count == 1)
    #expect(waste?.occurrences == 3)
    #expect(Set(waste?.apps ?? []) == ["Mail", "Numbers", "QuickBooks"])
}

@Test
func contextWastePromotesSingleStrongBatchWithRepeatedRecordBindings() {
    let rows = """
    {"structured":{"tables":[{"rows":[
    ["Vendor","Invoice #","Status","Total"],
    ["Acme Corp","INV-101","Queued","$120.00"],
    ["Beta LLC","INV-102","Queued","$340.00"],
    ["Contoso","INV-103","Queued","$560.00"],
    ["Delta Ltd","INV-104","Queued","$780.00"]
    ]}]}}
    """
    let contexts = stride(from: 0.0, through: 10_800.0, by: 600.0).enumerated().map { offset, elapsed in
        context(
            id: Int64(offset + 1),
            at: elapsed,
            title: "Vendor invoice batch",
            ocr: "Review vendor invoice queue, verify invoice total, and update paid status.",
            metadataJSON: rows
        )
    }

    let results = ContextWasteDetector().detect(contexts: contexts, maxResults: 5)
    let waste = try? #require(results.first)

    #expect(results.count == 1)
    #expect(waste?.occurrences == 4)
    #expect(waste?.estimatedTotalSeconds == 10_800)
    #expect(waste?.parameters.contains { $0.role == "invoice_id" && $0.count == 4 } == true)
}

private extension RecordedContext {
    var asArray: [RecordedContext] { [self] }
}
