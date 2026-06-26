import Foundation

/// Pure exporters for `ScreenContentStructurer.Structured` snapshots.
///
/// The outputs are deliberately bounded so a future record inspection tool can
/// include structure without letting a single dense screen dominate context.
public enum StructuredContentExporter {
    public struct Budget: Sendable, Equatable {
        public let maxBytes: Int
        public let maxLines: Int

        public init(maxBytes: Int = 8_192, maxLines: Int = 120) {
            self.maxBytes = max(0, maxBytes)
            self.maxLines = max(0, maxLines)
        }

        public static let markdown = Budget(maxBytes: 12_000, maxLines: 160)
        public static let table = Budget(maxBytes: 8_000, maxLines: 120)
        public static let summary = Budget(maxBytes: 1_000, maxLines: 8)
    }

    private static let truncationMarker = "[truncated]"

    public static func markdown(
        from structured: ScreenContentStructurer.Structured,
        budget: Budget = .markdown
    ) -> String {
        var lines: [String] = []

        for line in structured.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append(escapeMarkdownInline(text))
        }

        if !structured.keyValues.isEmpty {
            if !lines.isEmpty { lines.append("") }
            for pair in structured.keyValues {
                lines.append("- **\(escapeMarkdownInline(pair.key))**: \(escapeMarkdownInline(pair.value))")
            }
        }

        for (index, table) in structured.tables.enumerated() {
            let tableLines = markdownTableLines(table)
            guard !tableLines.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append(structured.tables.count == 1 ? "**Table**" : "**Table \(index + 1)**")
            lines.append("")
            lines.append(contentsOf: tableLines)
        }

        return bounded(lines, budget: budget)
    }

    public static func markdownTables(
        from structured: ScreenContentStructurer.Structured,
        budget: Budget = .table
    ) -> [String] {
        structured.tables.map { markdownTable($0, budget: budget) }
    }

    public static func markdownTable(
        _ table: ScreenContentStructurer.Table,
        budget: Budget = .table
    ) -> String {
        bounded(markdownTableLines(table), budget: budget)
    }

    public static func csvTables(
        from structured: ScreenContentStructurer.Structured,
        budget: Budget = .table
    ) -> [String] {
        structured.tables.map { csv($0, budget: budget) }
    }

    public static func csv(
        _ table: ScreenContentStructurer.Table,
        budget: Budget = .table
    ) -> String {
        let rows = normalizedRows(table.rows)
        let lines = rows.map { row in row.map(csvCell).joined(separator: ",") }
        return bounded(lines, budget: budget)
    }

    public static func summary(
        from structured: ScreenContentStructurer.Structured,
        budget: Budget = .summary
    ) -> String {
        guard !structured.lines.isEmpty || !structured.keyValues.isEmpty || !structured.tables.isEmpty else {
            return bounded(["No structured content detected."], budget: budget)
        }

        let lineCount = structured.lines.count
        let pairCount = structured.keyValues.count
        let tableSummaries = structured.tables.enumerated().map { index, table in
            let rows = table.rows.count
            let columns = normalizedRows(table.rows).first?.count ?? table.columnCount
            return "table \(index + 1): \(rows) rows x \(columns) cols"
        }

        var parts = [
            "\(lineCount) \(lineCount == 1 ? "line" : "lines")",
            "\(pairCount) \(pairCount == 1 ? "key-value" : "key-values")",
            "\(structured.tables.count) \(structured.tables.count == 1 ? "table" : "tables")",
        ]
        if !tableSummaries.isEmpty {
            parts.append(tableSummaries.joined(separator: "; "))
        }

        var lines = ["Structured content: \(parts.joined(separator: ", "))."]
        if let preview = structured.lines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            lines.append("Preview: \(preview)")
        }
        return bounded(lines, budget: budget)
    }

    private static func markdownTableLines(_ table: ScreenContentStructurer.Table) -> [String] {
        let rows = normalizedRows(table.rows)
        guard let header = rows.first else { return [] }
        let separator = [String](repeating: "---", count: header.count)
        return [markdownRow(header), markdownRow(separator)] + rows.dropFirst().map(markdownRow)
    }

    private static func markdownRow(_ cells: [String]) -> String {
        "| " + cells.map(markdownTableCell).joined(separator: " | ") + " |"
    }

    private static func markdownTableCell(_ cell: String) -> String {
        let escaped = escapeMarkdownInline(cell)
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return escaped.isEmpty ? " " : escaped
    }

    private static func escapeMarkdownInline(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_[]()".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private static func csvCell(_ cell: String) -> String {
        let normalized = cell
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let safe = formulaEscaped(normalized)
        let escaped = safe.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private static func formulaEscaped(_ field: String) -> String {
        guard let first = field.first else { return field }
        if isFormulaDangerous(first) {
            return "'" + field
        }

        let firstNonWhitespace = field.drop(while: { $0.isWhitespace }).first
        guard let firstNonWhitespace, isFormulaTrigger(firstNonWhitespace) else { return field }
        return "'" + field
    }

    private static func isFormulaDangerous(_ character: Character) -> Bool {
        isFormulaTrigger(character) || character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isFormulaTrigger(_ character: Character) -> Bool {
        character == "=" || character == "+" || character == "-" || character == "@"
    }

    private static func normalizedRows(_ rows: [[String]]) -> [[String]] {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return [] }
        return rows.map { row in
            row + [String](repeating: "", count: max(0, columnCount - row.count))
        }
    }

    private static func bounded(_ lines: [String], budget: Budget) -> String {
        guard budget.maxLines > 0, budget.maxBytes > 0 else { return "" }

        let initialLines = Array(lines.prefix(budget.maxLines))
        let initialText = initialLines.joined(separator: "\n")
        if initialLines.count == lines.count, initialText.utf8.count <= budget.maxBytes {
            return initialText
        }

        if budget.maxLines == 1 {
            return clipped(truncationMarker, maxBytes: budget.maxBytes)
        }

        var kept = Array(lines.prefix(max(0, budget.maxLines - 1)))
        while !kept.isEmpty && (kept + [truncationMarker]).joined(separator: "\n").utf8.count > budget.maxBytes {
            kept.removeLast()
        }

        if kept.isEmpty,
           let first = lines.first,
           budget.maxBytes > truncationMarker.utf8.count + 1 {
            let available = budget.maxBytes - truncationMarker.utf8.count - 1
            let clippedFirst = clipped(first, maxBytes: available)
            if !clippedFirst.isEmpty {
                return [clippedFirst, truncationMarker].joined(separator: "\n")
            }
        }

        let text = (kept + [truncationMarker]).joined(separator: "\n")
        if text.utf8.count <= budget.maxBytes { return text }
        return clipped(truncationMarker, maxBytes: budget.maxBytes)
    }

    private static func clipped(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var clipped = text
        while clipped.utf8.count > maxBytes {
            clipped.removeLast()
        }
        return clipped
    }
}
