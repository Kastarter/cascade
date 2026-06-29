import CoreGraphics
import Foundation

/// Turns flat OCR boxes into structured screen content using deterministic
/// geometry: reading-order lines, blocks, lists, key/value fields, and tables.
///
/// Coordinate note: pass `topLeftOrigin: true` when smaller `y` is higher on
/// screen (standard UI coordinates). Apple Vision OCR uses a bottom-left origin,
/// so live `recognizeBoxes` output passes `topLeftOrigin: false`.
public enum ScreenContentStructurer {
    public static let currentVersion = 2

    public enum Source: String, Codable, Sendable {
        case ocr
        case ax
        case merged
    }

    public enum BlockKind: String, Codable, Sendable {
        case heading
        case paragraph
        case list
        case table
        case form
        case code
    }

    public enum FieldKind: String, Codable, Sendable {
        case text
        case date
        case link
        case phone
        case address
        case currency
        case total
        case invoiceID = "invoice_id"
        case orderID = "order_id"
        case email
        case percentage
        case quantity
        case accountID = "account_id"
        case formControl = "form_control"
    }

    public enum AXControlKind: String, Codable, Sendable {
        case textField = "text_field"
        case checkbox
        case radio
        case popup
        case comboBox = "combo_box"
        case unknown
    }

    public struct AXControl: Codable, Sendable, Equatable {
        public let id: String
        public let kind: AXControlKind
        public let label: String?
        public let value: String?
        public let rect: CGRect?
        public let confidence: Double

        public init(
            id: String = UUID().uuidString,
            kind: AXControlKind,
            label: String? = nil,
            value: String? = nil,
            rect: CGRect? = nil,
            confidence: Double = 0.85
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.value = value
            self.rect = rect
            self.confidence = confidence
        }
    }

    public struct Line: Sendable, Equatable, Codable {
        public let id: String
        public let orderIndex: Int
        public let text: String
        public let boxes: [ScreenTextRecognizer.TextBox]
        public let rect: CGRect
        public let normalizedRect: CGRect
        public let source: Source
        public let confidence: Double

        public init(
            id: String,
            orderIndex: Int,
            text: String,
            boxes: [ScreenTextRecognizer.TextBox],
            rect: CGRect,
            normalizedRect: CGRect,
            source: Source = .ocr,
            confidence: Double = 1
        ) {
            self.id = id
            self.orderIndex = orderIndex
            self.text = text
            self.boxes = boxes
            self.rect = rect
            self.normalizedRect = normalizedRect
            self.source = source
            self.confidence = confidence
        }

        enum CodingKeys: String, CodingKey {
            case id
            case orderIndex = "order_index"
            case text
            case rect
            case normalizedRect = "normalized_rect"
            case source
            case confidence
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            orderIndex = try container.decode(Int.self, forKey: .orderIndex)
            text = try container.decode(String.self, forKey: .text)
            rect = try container.decode(CGRect.self, forKey: .rect)
            normalizedRect = try container.decode(CGRect.self, forKey: .normalizedRect)
            source = try container.decode(Source.self, forKey: .source)
            confidence = try container.decode(Double.self, forKey: .confidence)
            boxes = []
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(orderIndex, forKey: .orderIndex)
            try container.encode(text, forKey: .text)
            try container.encode(rect, forKey: .rect)
            try container.encode(normalizedRect, forKey: .normalizedRect)
            try container.encode(source, forKey: .source)
            try container.encode(confidence, forKey: .confidence)
        }
    }

    public struct KeyValue: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    public struct OCRBlock: Codable, Sendable, Equatable {
        public let id: String
        public let orderIndex: Int
        public let kind: BlockKind
        public let text: String
        public let rect: CGRect
        public let normalizedRect: CGRect
        public let confidence: Double
        public let evidenceLineIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case orderIndex = "order_index"
            case kind
            case text
            case rect
            case normalizedRect = "normalized_rect"
            case confidence
            case evidenceLineIDs = "evidence_line_ids"
        }
    }

    public struct OCRList: Codable, Sendable, Equatable {
        public struct Item: Codable, Sendable, Equatable {
            public let text: String
            public let marker: String?
            public let lineID: String

            enum CodingKeys: String, CodingKey {
                case text
                case marker
                case lineID = "line_id"
            }
        }

        public let id: String
        public let orderIndex: Int
        public let items: [Item]
        public let rect: CGRect
        public let confidence: Double
        public let evidenceLineIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case orderIndex = "order_index"
            case items
            case rect
            case confidence
            case evidenceLineIDs = "evidence_line_ids"
        }
    }

    public struct OCRField: Codable, Sendable, Equatable {
        public let id: String
        public let key: String
        public let value: String
        public let kind: FieldKind
        public let confidence: Double
        public let rect: CGRect
        public let keyLineIDs: [String]
        public let valueLineIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case key
            case value
            case kind
            case confidence
            case rect
            case keyLineIDs = "key_line_ids"
            case valueLineIDs = "value_line_ids"
        }
    }

    public struct TableCell: Codable, Sendable, Equatable {
        public let row: Int
        public let column: Int
        public let text: String
        public let rect: CGRect
        public let evidenceLineIDs: [String]

        enum CodingKeys: String, CodingKey {
            case row
            case column
            case text
            case rect
            case evidenceLineIDs = "evidence_line_ids"
        }
    }

    /// A reconstructed table: `rows[r][c]` is the cell text ("" when empty).
    public struct Table: Sendable, Equatable, Codable {
        public let id: String
        public let orderIndex: Int
        public let rows: [[String]]
        public let cells: [TableCell]
        public let rect: CGRect
        public let headerRowIndex: Int?
        public let confidence: Double
        public let evidenceLineIDs: [String]
        public var columnCount: Int { rows.first?.count ?? 0 }

        public init(
            rows: [[String]],
            id: String = "table-0001",
            orderIndex: Int = 0,
            cells: [TableCell]? = nil,
            rect: CGRect = .zero,
            headerRowIndex: Int? = nil,
            confidence: Double = 0.75,
            evidenceLineIDs: [String] = []
        ) {
            self.id = id
            self.orderIndex = orderIndex
            self.rows = rows
            self.rect = rect
            self.headerRowIndex = headerRowIndex
            self.confidence = confidence
            self.evidenceLineIDs = evidenceLineIDs
            if let cells {
                self.cells = cells
            } else {
                self.cells = rows.enumerated().flatMap { rowIndex, row in
                    row.enumerated().map { columnIndex, text in
                        TableCell(row: rowIndex, column: columnIndex, text: text, rect: .zero, evidenceLineIDs: [])
                    }
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case orderIndex = "order_index"
            case rows
            case cells
            case rect
            case headerRowIndex = "header_row_index"
            case confidence
            case evidenceLineIDs = "evidence_line_ids"
        }
    }

    public struct OCRCodeBlock: Codable, Sendable, Equatable {
        public let id: String
        public let orderIndex: Int
        public let languageHint: String?
        public let text: String
        public let rect: CGRect
        public let confidence: Double
        public let evidenceLineIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case orderIndex = "order_index"
            case languageHint = "language_hint"
            case text
            case rect
            case confidence
            case evidenceLineIDs = "evidence_line_ids"
        }
    }

    public struct Structured: Sendable, Equatable, Codable {
        public let version: Int
        public let lines: [Line]
        public let blocks: [OCRBlock]
        public let fields: [OCRField]
        public let lists: [OCRList]
        public let tables: [Table]
        public let codeBlocks: [OCRCodeBlock]

        /// Backward-compatible simple key/value surface for existing callers.
        public var keyValues: [KeyValue] {
            fields.map { KeyValue(key: $0.key, value: $0.value) }
        }

        /// Reading-order plain text.
        public var readingOrderText: String { lines.map(\.text).joined(separator: "\n") }

        /// Compact text indexed in the structured retrieval lane.
        public var searchableText: String {
            var parts = lines.map(\.text)
            parts += blocks.map { "\($0.kind.rawValue) \($0.text)" }
            parts += fields.map { "\($0.kind.rawValue) \($0.key) \($0.value)" }
            parts += lists.flatMap { list in list.items.map(\.text) }
            parts += tables.flatMap { $0.rows.flatMap { $0 } }
            parts += codeBlocks.map(\.text)
            return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        enum CodingKeys: String, CodingKey {
            case version
            case lines
            case blocks
            case fields
            case lists
            case tables
            case codeBlocks = "code_blocks"
        }
    }

    // MARK: - Entry

    public static func structure(
        _ boxes: [ScreenTextRecognizer.TextBox],
        topLeftOrigin: Bool = true,
        axControls: [AXControl] = []
    ) -> Structured {
        let lines = groupIntoLines(boxes, topLeftOrigin: topLeftOrigin)
        let lists = detectLists(lines)
        let tables = detectTables(lines)
        let fields = extractFields(lines: lines, tables: tables, axControls: axControls)
        let blocks = detectBlocks(lines: lines, lists: lists, tables: tables, fields: fields)
        let codeBlocks = detectCodeBlocks(lines)
        return Structured(
            version: currentVersion,
            lines: lines,
            blocks: blocks,
            fields: fields,
            lists: lists,
            tables: tables,
            codeBlocks: codeBlocks
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

        let sorted = valid.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > tolerance {
                return topLeftOrigin ? $0.boundingBox.midY < $1.boundingBox.midY : $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
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

        let rawLines = groups.map { group -> (text: String, boxes: [ScreenTextRecognizer.TextBox], rect: CGRect, confidence: Double) in
            let ordered = group.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let confidence = ordered.isEmpty ? 1 : Double(ordered.reduce(Float(0)) { $0 + $1.confidence } / Float(ordered.count))
            return (text, ordered, unionRect(ordered.map { $0.boundingBox }), confidence)
        }

        let ordered = orderByWhitespace(rawLines, topLeftOrigin: topLeftOrigin)
        return ordered.enumerated().map { index, raw in
            Line(
                id: stableID(prefix: "line", index: index),
                orderIndex: index,
                text: raw.text,
                boxes: raw.boxes,
                rect: raw.rect,
                normalizedRect: raw.rect,
                source: .ocr,
                confidence: raw.confidence
            )
        }
    }

    private static func orderByWhitespace(
        _ lines: [(text: String, boxes: [ScreenTextRecognizer.TextBox], rect: CGRect, confidence: Double)],
        topLeftOrigin: Bool
    ) -> [(text: String, boxes: [ScreenTextRecognizer.TextBox], rect: CGRect, confidence: Double)] {
        guard lines.count >= 6 else {
            return lines.sorted { visualPrecedes($0.rect, $1.rect, topLeftOrigin: topLeftOrigin) }
        }
        let page = unionRect(lines.map(\.rect))
        let candidateXs = lines.flatMap { [$0.rect.minX, $0.rect.maxX] }.sorted()
        var bestGap: (start: CGFloat, end: CGFloat, width: CGFloat)?
        for pair in zip(candidateXs, candidateXs.dropFirst()) {
            let gap = pair.1 - pair.0
            guard gap > page.width * 0.12 else { continue }
            let left = lines.filter { $0.rect.maxX <= pair.0 }.count
            let right = lines.filter { $0.rect.minX >= pair.1 }.count
            guard left >= 2, right >= 2 else { continue }
            if bestGap == nil || gap > bestGap!.width {
                bestGap = (pair.0, pair.1, gap)
            }
        }
        guard let gap = bestGap else {
            return lines.sorted { visualPrecedes($0.rect, $1.rect, topLeftOrigin: topLeftOrigin) }
        }
        let middle = (gap.start + gap.end) / 2
        let left = lines.filter { $0.rect.midX < middle }
        let right = lines.filter { $0.rect.midX >= middle }
        guard !left.isEmpty, !right.isEmpty else {
            return lines.sorted { visualPrecedes($0.rect, $1.rect, topLeftOrigin: topLeftOrigin) }
        }
        return orderByWhitespace(left, topLeftOrigin: topLeftOrigin)
            + orderByWhitespace(right, topLeftOrigin: topLeftOrigin)
    }

    private static func visualPrecedes(_ lhs: CGRect, _ rhs: CGRect, topLeftOrigin: Bool) -> Bool {
        let verticalGap = abs(lhs.midY - rhs.midY)
        let tolerance = max(min(lhs.height, rhs.height) * 0.8, 1e-6)
        if verticalGap > tolerance {
            return topLeftOrigin ? lhs.midY < rhs.midY : lhs.midY > rhs.midY
        }
        return lhs.minX < rhs.minX
    }

    // MARK: - Blocks and lists

    static func detectLists(_ lines: [Line]) -> [OCRList] {
        var lists: [OCRList] = []
        var run: [(line: Line, marker: String?, text: String)] = []

        func flush() {
            guard run.count >= 2 else {
                run = []
                return
            }
            let index = lists.count
            let rect = unionRect(run.map { $0.line.rect })
            lists.append(OCRList(
                id: stableID(prefix: "list", index: index),
                orderIndex: run.first?.line.orderIndex ?? index,
                items: run.map { OCRList.Item(text: $0.text, marker: $0.marker, lineID: $0.line.id) },
                rect: rect,
                confidence: 0.78,
                evidenceLineIDs: run.map { $0.line.id }
            ))
            run = []
        }

        for line in lines {
            if let item = listItem(line.text) {
                run.append((line, item.marker, item.text))
            } else {
                flush()
            }
        }
        flush()
        return lists
    }

    static func detectBlocks(lines: [Line], lists: [OCRList], tables: [Table], fields: [OCRField]) -> [OCRBlock] {
        guard !lines.isEmpty else { return [] }
        let tableLineIDs = Set(tables.flatMap(\.evidenceLineIDs))
        let listLineIDs = Set(lists.flatMap(\.evidenceLineIDs))
        let formLineIDs = Set(fields.flatMap { $0.keyLineIDs + $0.valueLineIDs })
        let medianHeight = median(lines.map { $0.rect.height })
        var blocks: [OCRBlock] = []
        var paragraphRun: [Line] = []

        func flushParagraph() {
            guard !paragraphRun.isEmpty else { return }
            let index = blocks.count
            blocks.append(block(
                id: stableID(prefix: "block", index: index),
                orderIndex: paragraphRun.first?.orderIndex ?? index,
                kind: .paragraph,
                lines: paragraphRun,
                confidence: 0.65
            ))
            paragraphRun = []
        }

        for line in lines {
            if tableLineIDs.contains(line.id) {
                flushParagraph()
                continue
            }
            if listLineIDs.contains(line.id) {
                flushParagraph()
                if !blocks.contains(where: { $0.evidenceLineIDs.contains(line.id) }) {
                    let matching = lists.first { $0.evidenceLineIDs.contains(line.id) }
                    if let matching {
                        blocks.append(OCRBlock(
                            id: stableID(prefix: "block", index: blocks.count),
                            orderIndex: matching.orderIndex,
                            kind: .list,
                            text: matching.items.map(\.text).joined(separator: "\n"),
                            rect: matching.rect,
                            normalizedRect: matching.rect,
                            confidence: matching.confidence,
                            evidenceLineIDs: matching.evidenceLineIDs
                        ))
                    }
                }
                continue
            }
            if formLineIDs.contains(line.id), line.text.count <= 120 {
                flushParagraph()
                blocks.append(block(
                    id: stableID(prefix: "block", index: blocks.count),
                    orderIndex: line.orderIndex,
                    kind: .form,
                    lines: [line],
                    confidence: 0.72
                ))
                continue
            }
            let following = nextLine(after: line, in: lines)
            if isHeading(line, next: following, medianHeight: medianHeight)
                || isHeadingBeforeList(line, next: following) {
                flushParagraph()
                blocks.append(block(
                    id: stableID(prefix: "block", index: blocks.count),
                    orderIndex: line.orderIndex,
                    kind: .heading,
                    lines: [line],
                    confidence: 0.7
                ))
                continue
            }
            paragraphRun.append(line)
        }
        flushParagraph()

        for table in tables {
            blocks.append(OCRBlock(
                id: stableID(prefix: "block", index: blocks.count),
                orderIndex: table.orderIndex,
                kind: .table,
                text: table.rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"),
                rect: table.rect,
                normalizedRect: table.rect,
                confidence: table.confidence,
                evidenceLineIDs: table.evidenceLineIDs
            ))
        }
        return blocks.sorted { $0.orderIndex < $1.orderIndex }
    }

    private static func block(id: String, orderIndex: Int, kind: BlockKind, lines: [Line], confidence: Double) -> OCRBlock {
        let rect = unionRect(lines.map(\.rect))
        return OCRBlock(
            id: id,
            orderIndex: orderIndex,
            kind: kind,
            text: lines.map(\.text).joined(separator: "\n"),
            rect: rect,
            normalizedRect: rect,
            confidence: confidence,
            evidenceLineIDs: lines.map(\.id)
        )
    }

    private static func nextLine(after line: Line, in lines: [Line]) -> Line? {
        lines.first { $0.orderIndex == line.orderIndex + 1 }
    }

    private static func isHeading(_ line: Line, next: Line?, medianHeight: CGFloat) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(text.count) else { return false }
        if text.range(of: #"[:.,;]$"#, options: .regularExpression) != nil { return false }
        let prominent = medianHeight > 0 && line.rect.height >= medianHeight * 1.15
        let titleLike = text == text.uppercased() || text.split(separator: " ").filter { $0.first?.isUppercase == true }.count >= max(1, text.split(separator: " ").count - 1)
        let whitespaceBelow = next.map { abs($0.rect.midY - line.rect.midY) > max(medianHeight * 1.8, line.rect.height * 1.4) } ?? true
        return (prominent || titleLike) && whitespaceBelow
    }

    private static func isHeadingBeforeList(_ line: Line, next: Line?) -> Bool {
        guard let next, listItem(next.text) != nil else { return false }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(text.count), text.range(of: #"[:.,;]$"#, options: .regularExpression) == nil else {
            return false
        }
        return text.split(separator: " ").count <= 8 && text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    private static func listItem(_ text: String) -> (marker: String?, text: String)? {
        let patterns = [
            #"^\s*([\-*•])\s+(.+)$"#,
            #"^\s*(\d+[\.)])\s+(.+)$"#,
            #"^\s*([A-Za-z][\.)])\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let match = regexCaptures(pattern, in: text), match.count == 2 else { continue }
            return (match[0], match[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    // MARK: - Key/value and field extraction

    static func extractKeyValues(_ lines: [Line]) -> [KeyValue] {
        extractFields(lines: lines, tables: [], axControls: []).map { KeyValue(key: $0.key, value: $0.value) }
    }

    static func extractFields(lines: [Line], tables: [Table], axControls: [AXControl]) -> [OCRField] {
        var fields: [OCRField] = []

        func append(_ field: OCRField) {
            let key = field.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field.value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            guard !fields.contains(where: {
                $0.key.lowercased() == key && $0.value.lowercased() == value
            }) else { return }
            fields.append(field)
        }

        for line in lines {
            if let pair = colonPair(line.text), !isClockFalsePositive(key: pair.key, value: pair.value) {
                append(makeField(
                    key: pair.key,
                    value: pair.value,
                    kind: kind(forKey: pair.key, value: pair.value),
                    confidence: 0.82,
                    rect: line.rect,
                    keyLines: [line.id],
                    valueLines: [line.id],
                    index: fields.count
                ))
            }

            if let total = totalPair(line.text) {
                append(makeField(
                    key: total.key,
                    value: total.value,
                    kind: .total,
                    confidence: 0.86,
                    rect: line.rect,
                    keyLines: [line.id],
                    valueLines: [line.id],
                    index: fields.count
                ))
            }

            if line.boxes.count >= 2, let spatial = sameBaselinePair(line) {
                append(makeField(
                    key: spatial.key,
                    value: spatial.value,
                    kind: kind(forKey: spatial.key, value: spatial.value),
                    confidence: 0.8,
                    rect: line.rect,
                    keyLines: [line.id],
                    valueLines: [line.id],
                    index: fields.count
                ))
            }

            for detected in detectorFields(line) {
                append(makeField(
                    key: detected.key,
                    value: detected.value,
                    kind: detected.kind,
                    confidence: detected.confidence,
                    rect: line.rect,
                    keyLines: [line.id],
                    valueLines: [line.id],
                    index: fields.count
                ))
            }
        }

        for (label, value) in aboveBelowPairs(lines) {
            append(makeField(
                key: label.text,
                value: value.text,
                kind: kind(forKey: label.text, value: value.text),
                confidence: 0.72,
                rect: label.rect.union(value.rect),
                keyLines: [label.id],
                valueLines: [value.id],
                index: fields.count
            ))
        }

        for table in tables {
            for rowIndex in table.rows.indices {
                let row = table.rows[rowIndex]
                guard row.count >= 2 else { continue }
                let key = row.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let value = row.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard isTotalLabel(key), looksLikeValue(value) else { continue }
                let evidence = table.cells.filter { $0.row == rowIndex }.flatMap(\.evidenceLineIDs)
                append(makeField(
                    key: key,
                    value: value,
                    kind: .total,
                    confidence: 0.9,
                    rect: unionRect(table.cells.filter { $0.row == rowIndex }.map(\.rect)),
                    keyLines: evidence,
                    valueLines: evidence,
                    index: fields.count
                ))
            }
        }

        for control in axControls {
            guard let label = control.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { continue }
            let value = control.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleValue = (value?.isEmpty == false ? value : control.kind.rawValue) ?? control.kind.rawValue
            append(makeField(
                key: label,
                value: visibleValue,
                kind: .formControl,
                confidence: control.confidence,
                rect: control.rect ?? .zero,
                keyLines: [],
                valueLines: [],
                index: fields.count
            ))
        }

        return fields
    }

    private static func makeField(
        key: String,
        value: String,
        kind: FieldKind,
        confidence: Double,
        rect: CGRect,
        keyLines: [String],
        valueLines: [String],
        index: Int
    ) -> OCRField {
        OCRField(
            id: stableID(prefix: "field", index: index),
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            value: value.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            confidence: confidence,
            rect: rect,
            keyLineIDs: keyLines,
            valueLineIDs: valueLines
        )
    }

    private static func colonPair(_ text: String) -> (key: String, value: String)? {
        guard let captures = regexCaptures(#"^\s*([^:]{1,60}?)\s*:\s*(\S.*)$"#, in: text), captures.count == 2 else {
            return nil
        }
        let key = captures[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = captures[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty, !value.hasPrefix("//") else { return nil }
        return (key, value)
    }

    private static func totalPair(_ text: String) -> (key: String, value: String)? {
        guard let captures = regexCaptures(#"^\s*((?:grand\s+)?total(?:\s+due)?|subtotal|tax|balance(?:\s+due)?|amount\s+due)\s+(.+?\$?[\d,]+(?:\.\d{2})?)\s*$"#, in: text, options: [.caseInsensitive]), captures.count == 2 else {
            return nil
        }
        return (captures[0], captures[1])
    }

    private static func sameBaselinePair(_ line: Line) -> (key: String, value: String)? {
        let boxes = line.boxes
        guard boxes.count >= 2 else { return nil }
        let first = boxes.dropLast().map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let last = boxes.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isLabelLike(first), looksLikeValue(last) else { return nil }
        return (first, last)
    }

    private static func aboveBelowPairs(_ lines: [Line]) -> [(Line, Line)] {
        guard lines.count >= 2 else { return [] }
        var pairs: [(Line, Line)] = []
        for (index, line) in lines.dropLast().enumerated() {
            let next = lines[index + 1]
            guard isLabelLike(line.text), looksLikeValue(next.text) else { continue }
            let aligned = abs(line.rect.minX - next.rect.minX) <= max(line.rect.height, next.rect.height) * 1.2
            let gap = abs(line.rect.midY - next.rect.midY)
            guard aligned, gap <= max(line.rect.height, next.rect.height) * 3.2 else { continue }
            pairs.append((line, next))
        }
        return pairs
    }

    private static func detectorFields(_ line: Line) -> [(key: String, value: String, kind: FieldKind, confidence: Double)] {
        var out: [(String, String, FieldKind, Double)] = []
        let text = line.text
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let types = NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
        if let detector = try? NSDataDetector(types: types) {
            detector.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                let value = String(text[range])
                switch match.resultType {
                case .date:
                    out.append(("date", value, .date, 0.62))
                case .link:
                    out.append(("link", value, .link, 0.66))
                case .phoneNumber:
                    out.append(("phone", value, .phone, 0.66))
                case .address:
                    out.append(("address", value, .address, 0.62))
                default:
                    break
                }
            }
        }

        let regexes: [(String, String, FieldKind, Double)] = [
            (#"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, "email", .email, 0.74),
            (#"\$[\d,]+(?:\.\d{2})?\b"#, "amount", .currency, 0.68),
            (#"\b(?:INV|INVOICE|ORDER|PO|SO)[-\s#:]*[A-Z0-9-]*\d[A-Z0-9-]*\b"#, "document id", .invoiceID, 0.72),
            (#"\b\d+(?:\.\d+)?\s?%\b"#, "percentage", .percentage, 0.68),
            (#"\b(?:qty|quantity)\s+[\d,]+(?:\.\d+)?\b"#, "quantity", .quantity, 0.68),
            (#"\b(?:acct|account)[-\s#:]*[A-Z0-9-]{4,}\b"#, "account", .accountID, 0.68),
        ]
        for (pattern, key, kind, confidence) in regexes {
            for value in regexMatches(pattern, in: text, options: [.caseInsensitive]) {
                out.append((key, value, kind, confidence))
            }
        }
        return out
    }

    private static func kind(forKey key: String, value: String) -> FieldKind {
        let blob = "\(key) \(value)".lowercased()
        if isTotalLabel(key) { return .total }
        if value.range(of: #"^\$?\d[\d,]*(\.\d{2})?$"#, options: .regularExpression) != nil,
           blob.contains("total") || blob.contains("amount") || blob.contains("balance") || blob.contains("tax") {
            return .total
        }
        if value.range(of: #"\$[\d,]+(?:\.\d{2})?"#, options: .regularExpression) != nil { return .currency }
        if blob.contains("due date") || blob.contains(" date") || key.lowercased() == "date" { return .date }
        if blob.contains("invoice") { return .invoiceID }
        if blob.contains("order") { return .orderID }
        if value.range(of: #"@"#, options: .regularExpression) != nil { return .email }
        if value.range(of: #"https?://"#, options: [.regularExpression, .caseInsensitive]) != nil { return .link }
        if value.range(of: #"\d+(?:\.\d+)?\s?%"#, options: .regularExpression) != nil { return .percentage }
        return .text
    }

    private static func isClockFalsePositive(key: String, value: String) -> Bool {
        if key.range(of: #"^\d+$"#, options: .regularExpression) != nil { return true }
        if key.range(of: #"\d$"#, options: .regularExpression) != nil,
           value.range(of: #"^\d{2}(\s*[AaPp][Mm]\b|\s|$)"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isLabelLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(trimmed.count) else { return false }
        if looksLikeValue(trimmed) { return false }
        return trimmed.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    private static func looksLikeValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let patterns = [
            #"\$?\d[\d,]*(?:\.\d{2})?\b"#,
            #"\b\d{4}-\d{2}-\d{2}\b"#,
            #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,
            #"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#,
            #"https?://"#,
            #"\b[A-Z]{2,}[-#]?\d{3,}\b"#,
        ]
        return patterns.contains { trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func isTotalLabel(_ text: String) -> Bool {
        text.range(of: #"\b(total|subtotal|tax|balance|amount\s+due|grand\s+total)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Table reconstruction

    static func detectTables(_ lines: [Line]) -> [Table] {
        var tables: [Table] = []
        let candidates = lines.enumerated().filter { $0.element.boxes.count >= 2 }
        guard candidates.count >= 3 else { return [] }

        var run: [Line] = []
        var lastIndex = -2
        func flush() {
            if run.count >= 3, let table = makeTable(run, index: tables.count) {
                tables.append(table)
            }
            run = []
        }
        for (index, line) in candidates {
            if index == lastIndex + 1 {
                run.append(line)
            } else {
                flush()
                run = [line]
            }
            lastIndex = index
        }
        flush()
        return tables
    }

    private static func makeTable(_ rows: [Line], index: Int) -> Table? {
        let allBoxes = rows.flatMap(\.boxes)
        guard allBoxes.count >= rows.count * 2 else { return nil }

        let medianHeight = median(allBoxes.map { $0.boundingBox.height })
        let medianChar = median(allBoxes.map {
            max($0.boundingBox.width / CGFloat(max(1, $0.text.count)), 0.0001)
        })
        let columnTolerance = max(medianHeight * 1.4, medianChar * 4)

        let leftAnchors = clusterValues(allBoxes.map { $0.boundingBox.minX }, tolerance: columnTolerance)
        guard leftAnchors.count >= 2 else { return nil }

        var columnHits = [Int](repeating: 0, count: leftAnchors.count)
        for row in rows {
            var seen = Set<Int>()
            for box in row.boxes {
                seen.insert(nearestIndex(of: box.boundingBox.minX, in: leftAnchors))
            }
            for col in seen { columnHits[col] += 1 }
        }
        let stableColumns = leftAnchors.indices.filter { columnHits[$0] >= 3 || columnHits[$0] * 2 >= rows.count }
        guard stableColumns.count >= 2 else { return nil }
        let columns = stableColumns.map { leftAnchors[$0] }.sorted()

        var grid = [[String]]()
        var cells: [TableCell] = []
        for (rowIndex, row) in rows.enumerated() {
            var rowCells = [String](repeating: "", count: columns.count)
            var rects = [CGRect](repeating: .zero, count: columns.count)
            var hasRect = [Bool](repeating: false, count: columns.count)
            for box in row.boxes {
                let col = nearestIndex(of: box.boundingBox.minX, in: columns)
                let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
                rowCells[col] = rowCells[col].isEmpty ? text : rowCells[col] + " " + text
                rects[col] = hasRect[col] ? rects[col].union(box.boundingBox) : box.boundingBox
                hasRect[col] = true
            }
            grid.append(rowCells)
            for columnIndex in columns.indices {
                cells.append(TableCell(
                    row: rowIndex,
                    column: columnIndex,
                    text: rowCells[columnIndex],
                    rect: hasRect[columnIndex] ? rects[columnIndex] : .zero,
                    evidenceLineIDs: [row.id]
                ))
            }
        }

        let nonEmptyRows = grid.filter { row in row.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2 }
        guard nonEmptyRows.count >= 3 else { return nil }
        guard !looksLikeProseGrid(nonEmptyRows) else { return nil }

        let headerIndex = inferHeaderRow(grid)
        let rect = unionRect(rows.map(\.rect))
        return Table(
            rows: grid,
            id: stableID(prefix: "table", index: index),
            orderIndex: rows.first?.orderIndex ?? index,
            cells: cells,
            rect: rect,
            headerRowIndex: headerIndex,
            confidence: headerIndex == 0 ? 0.82 : 0.74,
            evidenceLineIDs: rows.map(\.id)
        )
    }

    private static func inferHeaderRow(_ rows: [[String]]) -> Int? {
        guard rows.count >= 3, let first = rows.first else { return nil }
        let firstHasLabels = first.contains { hasLetter($0) && !isMostlyNumeric($0) }
        guard firstHasLabels else { return nil }
        let laterNumericColumns = first.indices.filter { column in
            rows.dropFirst().filter { row in
                column < row.count && isMostlyNumeric(row[column])
            }.count >= max(1, rows.count - 2)
        }
        return laterNumericColumns.isEmpty ? nil : 0
    }

    private static func looksLikeProseGrid(_ rows: [[String]]) -> Bool {
        let joined = rows.flatMap { $0 }.joined(separator: " ")
        let wordCount = joined.split(separator: " ").count
        let numericCount = rows.flatMap { $0 }.filter(isMostlyNumeric).count
        return wordCount > rows.count * 8 && numericCount == 0
    }

    private static func isMostlyNumeric(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "$€£¥0123456789,.-()% ")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
            && trimmed.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func hasLetter(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .letters) != nil
    }

    // MARK: - Code blocks

    static func detectCodeBlocks(_ lines: [Line]) -> [OCRCodeBlock] {
        var blocks: [OCRCodeBlock] = []
        var run: [Line] = []

        func flush() {
            guard run.count >= 3 else {
                run = []
                return
            }
            let text = run.map(\.text).joined(separator: "\n")
            let index = blocks.count
            blocks.append(OCRCodeBlock(
                id: stableID(prefix: "code", index: index),
                orderIndex: run.first?.orderIndex ?? index,
                languageHint: nil,
                text: text,
                rect: unionRect(run.map(\.rect)),
                confidence: 0.62,
                evidenceLineIDs: run.map(\.id)
            ))
            run = []
        }

        for line in lines {
            if codeScore(line.text) >= 2 {
                run.append(line)
            } else {
                flush()
            }
        }
        flush()
        return blocks
    }

    private static func codeScore(_ text: String) -> Int {
        var score = 0
        if text.range(of: #"[{}();=]"#, options: .regularExpression) != nil { score += 1 }
        if text.range(of: #"\b(import|func|let|var|class|struct|if|for|return|await|try|const|function)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { score += 1 }
        if text.range(of: #"^\s*(//|#|>|[$])"#, options: .regularExpression) != nil { score += 1 }
        if text.range(of: #"(=>|==|!=|<=|>=|\.\w+\()"#, options: .regularExpression) != nil { score += 1 }
        return score
    }

    // MARK: - Geometry and regex helpers

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

    private static func stableID(prefix: String, index: Int) -> String {
        "\(prefix)-\(String(format: "%04d", index + 1))"
    }

    private static func regexCaptures(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        var captures: [String] = []
        for i in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: i), in: text) else { return nil }
            captures.append(String(text[range]))
        }
        return captures
    }

    private static func regexMatches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
