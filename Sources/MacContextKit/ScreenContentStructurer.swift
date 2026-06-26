import CoreGraphics
import Foundation

/// Turns flat OCR boxes into STRUCTURED screen content — reading-order lines,
/// key:value pairs, and tables — using pure geometry (no ML model, runs anywhere).
///
/// Cascade stores OCR as flat text today, which makes "what was the invoice total",
/// "extract that table", and reliable harness extraction weak. Geometry over the
/// `ScreenTextRecognizer.TextBox` rectangles recovers layout the flat text lost
/// (SEQ-16). Designed to be deterministic and unit-testable without a screen.
///
/// Coordinate note: pass `topLeftOrigin: true` when smaller `y` is higher on screen
/// (standard screen/UI coordinates). Apple Vision OCR uses a BOTTOM-left origin, so
/// a caller wiring this to live `recognizeBoxes` output passes `topLeftOrigin: false`
/// (or flips the rects first).
public enum ScreenContentStructurer {

    public struct Line: Sendable, Equatable {
        public let text: String
        public let boxes: [ScreenTextRecognizer.TextBox]
        public let rect: CGRect
    }

    public struct KeyValue: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    /// A reconstructed table: `rows[r][c]` is the cell text ("" when empty).
    public struct Table: Sendable, Equatable {
        public let rows: [[String]]
        public var columnCount: Int { rows.first?.count ?? 0 }
    }

    public struct Structured: Sendable, Equatable {
        public let lines: [Line]
        public let keyValues: [KeyValue]
        public let tables: [Table]
        /// Reading-order plain text — top-to-bottom, left-to-right within a line.
        public var readingOrderText: String { lines.map(\.text).joined(separator: "\n") }
    }

    // MARK: - Entry

    public static func structure(_ boxes: [ScreenTextRecognizer.TextBox], topLeftOrigin: Bool = true) -> Structured {
        let lines = groupIntoLines(boxes, topLeftOrigin: topLeftOrigin)
        return Structured(
            lines: lines,
            keyValues: extractKeyValues(lines),
            tables: detectTables(lines)
        )
    }

    // MARK: - Reading-order line grouping

    static func groupIntoLines(_ boxes: [ScreenTextRecognizer.TextBox], topLeftOrigin: Bool) -> [Line] {
        let valid = boxes.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.boundingBox.height > 0
        }
        guard !valid.isEmpty else { return [] }
        let medianHeight = median(valid.map { $0.boundingBox.height })
        let tolerance = max(medianHeight * 0.6, 1e-6)

        // Sort by vertical center, top first. Boxes on one visual line then sit
        // adjacent in the sorted order.
        let sorted = valid.sorted {
            topLeftOrigin ? $0.boundingBox.midY < $1.boundingBox.midY : $0.boundingBox.midY > $1.boundingBox.midY
        }
        var groups: [[ScreenTextRecognizer.TextBox]] = []
        var centers: [CGFloat] = []
        for box in sorted {
            let center = box.boundingBox.midY
            if let i = groups.indices.last, abs(center - centers[i]) <= tolerance {
                groups[i].append(box)
                centers[i] = groups[i].reduce(0) { $0 + $1.boundingBox.midY } / CGFloat(groups[i].count)
            } else {
                groups.append([box])
                centers.append(center)
            }
        }
        return groups.map { group in
            let ordered = group.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return Line(text: text, boxes: ordered, rect: unionRect(ordered.map { $0.boundingBox }))
        }
    }

    // MARK: - Key:value extraction

    static func extractKeyValues(_ lines: [Line]) -> [KeyValue] {
        var pairs: [KeyValue] = []
        for line in lines {
            guard let range = line.text.range(of: #"^\s*([^:]{1,40}?)\s*:\s*(\S.*)$"#, options: .regularExpression) else {
                continue
            }
            let matched = String(line.text[range])
            guard let colon = matched.firstIndex(of: ":") else { continue }
            let key = String(matched[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(matched[matched.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Skip false positives: a purely numeric "key" (12:00); a value that is
            // really the rest of a URL (Visit https://… → "//…"); or a clock time
            // where the colon splits hours from minutes (… 9:30 AM).
            if key.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
            if value.hasPrefix("//") { continue }
            if key.range(of: #"\d$"#, options: .regularExpression) != nil,
               value.range(of: #"^\d{2}(\s*[AaPp][Mm]\b|\s|$)"#, options: .regularExpression) != nil { continue }
            if key.isEmpty || value.isEmpty { continue }
            pairs.append(KeyValue(key: key, value: value))
        }
        return pairs
    }

    // MARK: - Table reconstruction

    static func detectTables(_ lines: [Line]) -> [Table] {
        // Candidate rows have ≥2 cells. Tables are maximal runs of ≥2 such rows
        // that share ≥2 aligned columns.
        var tables: [Table] = []
        let candidates = lines.enumerated().filter { $0.element.boxes.count >= 2 }
        guard candidates.count >= 2 else { return [] }

        // Split candidates into runs that are consecutive in the original line order.
        var run: [Line] = []
        var lastIndex = -2
        func flush() {
            if run.count >= 2, let table = makeTable(run) { tables.append(table) }
            run = []
        }
        for (index, line) in candidates {
            if index == lastIndex + 1 { run.append(line) } else { flush(); run = [line] }
            lastIndex = index
        }
        flush()
        return tables
    }

    private static func makeTable(_ rows: [Line]) -> Table? {
        let allBoxes = rows.flatMap { $0.boxes }
        let medianWidth = median(allBoxes.map { $0.boundingBox.width })
        let columnTolerance = max(medianWidth * 0.5, 1e-6)

        // Column anchors = clustered left-edges across all rows.
        let anchors = clusterValues(allBoxes.map { $0.boundingBox.minX }, tolerance: columnTolerance)
        guard anchors.count >= 2 else { return nil }

        // Each column must appear in at least half the rows to count as a real column.
        var columnHits = [Int](repeating: 0, count: anchors.count)
        for row in rows {
            var seen = Set<Int>()
            for box in row.boxes {
                let col = nearestIndex(of: box.boundingBox.minX, in: anchors)
                seen.insert(col)
            }
            for col in seen { columnHits[col] += 1 }
        }
        let stableColumns = anchors.indices.filter { columnHits[$0] * 2 >= rows.count }
        guard stableColumns.count >= 2 else { return nil }

        // Build cells against the stable columns.
        let columns = stableColumns.map { anchors[$0] }
        let grid: [[String]] = rows.map { row in
            var cells = [String](repeating: "", count: columns.count)
            for box in row.boxes {
                let col = nearestIndex(of: box.boundingBox.minX, in: columns)
                let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
                cells[col] = cells[col].isEmpty ? text : cells[col] + " " + text
            }
            return cells
        }
        return Table(rows: grid)
    }

    // MARK: - Geometry helpers

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func unionRect(_ rects: [CGRect]) -> CGRect {
        guard var u = rects.first else { return .zero }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    /// 1-D clustering: sort, then start a new cluster whenever the gap exceeds
    /// `tolerance`. Returns each cluster's mean.
    private static func clusterValues(_ values: [CGFloat], tolerance: CGFloat) -> [CGFloat] {
        let sorted = values.sorted()
        guard let first = sorted.first else { return [] }
        var clusters: [[CGFloat]] = [[first]]
        for v in sorted.dropFirst() {
            if v - (clusters[clusters.count - 1].last ?? v) <= tolerance {
                clusters[clusters.count - 1].append(v)
            } else {
                clusters.append([v])
            }
        }
        return clusters.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    private static func nearestIndex(of value: CGFloat, in anchors: [CGFloat]) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, a) in anchors.enumerated() {
            let d = abs(a - value)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }
}
