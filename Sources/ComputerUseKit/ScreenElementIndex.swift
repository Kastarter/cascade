import AppKit
import Foundation
import ImageIO
import MacContextKit
import Vision

public enum ScreenElementIndex {
    public enum Source: String, Sendable, CaseIterable {
        case accessibility
        case visual
        case ocr

        var rank: Int {
            switch self {
            case .accessibility: 3
            case .visual: 2
            case .ocr: 1
            }
        }
    }

    public enum Role: String, Sendable, Equatable {
        case button
        case link
        case checkbox
        case textField
        case menuItem
        case option
        case text
        case image
        case container
        case unknown

        var isInteractive: Bool {
            switch self {
            case .button, .link, .checkbox, .textField, .menuItem, .option:
                true
            case .text, .image, .container, .unknown:
                false
            }
        }
    }

    public enum ClickSafety: String, Sendable, Equatable {
        case safe
        case passive
        case unsafe
    }

    public struct Bounds: Sendable, Hashable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var area: Double { max(0, width) * max(0, height) }
        public var isValid: Bool { width > 0 && height > 0 && x.isFinite && y.isFinite && width.isFinite && height.isFinite }

        func union(_ other: Bounds) -> Bounds {
            let minX = min(x, other.x)
            let minY = min(y, other.y)
            let maxX = max(self.maxX, other.maxX)
            let maxY = max(self.maxY, other.maxY)
            return Bounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        func intersectionArea(with other: Bounds) -> Double {
            let overlapWidth = max(0, min(maxX, other.maxX) - max(x, other.x))
            let overlapHeight = max(0, min(maxY, other.maxY) - max(y, other.y))
            return overlapWidth * overlapHeight
        }

        func intersectionOverUnion(with other: Bounds) -> Double {
            let intersection = intersectionArea(with: other)
            let unionArea = area + other.area - intersection
            guard unionArea > 0 else { return 0 }
            return intersection / unionArea
        }

        func containmentOverlap(with other: Bounds) -> Double {
            let smallerArea = min(area, other.area)
            guard smallerArea > 0 else { return 0 }
            return intersectionArea(with: other) / smallerArea
        }

        public var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let bounds: Bounds
        /// Pixel bounds in the screenshot/model image, top-left origin. `bounds`
        /// remains display-local AppKit points for executor compatibility.
        public let imageBounds: Bounds?
        public let label: String
        public let role: Role
        public let source: Source
        public let confidence: Double
        public let trust: Double
        public let clickSafety: ClickSafety

        public init(
            bounds: Bounds,
            imageBounds: Bounds? = nil,
            label: String,
            role: Role,
            source: Source,
            confidence: Double,
            trust: Double? = nil,
            clickSafety: ClickSafety? = nil
        ) {
            self.bounds = bounds
            self.imageBounds = imageBounds
            self.label = label
            self.role = role
            self.source = source
            self.confidence = confidence.clampedToUnit
            self.trust = (trust ?? source.defaultTrust).clampedToUnit
            self.clickSafety = clickSafety ?? (role.isInteractive ? .safe : .passive)
        }
    }

    public struct SetOfMark: Sendable, Equatable {
        public let number: Int
        public let label: String
        public let isSafeToClick: Bool

        public init(number: Int, label: String, isSafeToClick: Bool) {
            self.number = number
            self.label = label
            self.isSafeToClick = isSafeToClick
        }
    }

    public struct IndexedCandidate: Sendable, Equatable {
        public let id: String
        public let bounds: Bounds
        public let imageBounds: Bounds?
        public let label: String
        public let role: Role
        public let source: Source
        public let confidence: Double
        public let trust: Double
        public let clickSafety: ClickSafety
        public let contributingSources: [Source]
        public let mark: SetOfMark

        public var isSafeToClick: Bool {
            clickSafety == .safe && role.isInteractive
        }

        public var center: CGPoint {
            CGPoint(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2)
        }

        public init(
            id: String,
            bounds: Bounds,
            imageBounds: Bounds? = nil,
            label: String,
            role: Role,
            source: Source,
            confidence: Double,
            trust: Double,
            clickSafety: ClickSafety,
            contributingSources: [Source],
            mark: SetOfMark
        ) {
            self.id = id
            self.bounds = bounds
            self.imageBounds = imageBounds
            self.label = label
            self.role = role
            self.source = source
            self.confidence = confidence
            self.trust = trust
            self.clickSafety = clickSafety
            self.contributingSources = contributingSources
            self.mark = mark
        }

        fileprivate func withMark(_ mark: SetOfMark) -> IndexedCandidate {
            IndexedCandidate(
                id: id,
                bounds: bounds,
                imageBounds: imageBounds,
                label: label,
                role: role,
                source: source,
                confidence: confidence,
                trust: trust,
                clickSafety: clickSafety,
                contributingSources: contributingSources,
                mark: mark)
        }
    }

    public struct Configuration: Sendable, Equatable {
        public let overlapThreshold: Double
        public let containmentThreshold: Double
        public let rowTolerance: Double

        public init(
            overlapThreshold: Double = 0.55,
            containmentThreshold: Double = 0.80,
            rowTolerance: Double = 12
        ) {
            self.overlapThreshold = overlapThreshold
            self.containmentThreshold = containmentThreshold
            self.rowTolerance = rowTolerance
        }

        public static let `default` = Configuration()
    }

    public struct TrustPolicy: Sendable, Equatable {
        public let minAXScore: Double
        public let maxCanvasAreaFraction: Double
        public let maxAXSnapDistance: Double
        public let maxAXSnapWidth: Double
        public let maxAXSnapHeight: Double
        public let actionableAXRoles: Set<String>
        public let passiveAXRoles: Set<String>
        public let canvasAXRoles: Set<String>

        public init(
            minAXScore: Double = 2,
            maxCanvasAreaFraction: Double = 0.35,
            maxAXSnapDistance: Double = 28,
            maxAXSnapWidth: Double = 360,
            maxAXSnapHeight: Double = 130,
            actionableAXRoles: Set<String> = Self.defaultActionableAXRoles,
            passiveAXRoles: Set<String> = Self.defaultPassiveAXRoles,
            canvasAXRoles: Set<String> = Self.defaultCanvasAXRoles
        ) {
            self.minAXScore = minAXScore
            self.maxCanvasAreaFraction = maxCanvasAreaFraction
            self.maxAXSnapDistance = maxAXSnapDistance
            self.maxAXSnapWidth = maxAXSnapWidth
            self.maxAXSnapHeight = maxAXSnapHeight
            self.actionableAXRoles = actionableAXRoles
            self.passiveAXRoles = passiveAXRoles
            self.canvasAXRoles = canvasAXRoles
        }

        public static let `default` = TrustPolicy()

        public static let defaultActionableAXRoles: Set<String> = [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField",
            "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXCheckBox",
            "AXRadioButton", "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXSlider",
            "AXIncrementor"
        ]

        public static let defaultPassiveAXRoles: Set<String> = [
            "AXStaticText", "AXImage", "AXGroup", "AXLayoutArea", "AXSeparator"
        ]

        public static let defaultCanvasAXRoles: Set<String> = [
            "AXCanvas", "AXWebArea"
        ]

        public func role(fromAXRole role: String) -> Role {
            switch role {
            case "AXButton", "AXMenuBarItem": return .button
            case "AXMenuItem": return .menuItem
            case "AXLink": return .link
            case "AXCheckBox", "AXRadioButton": return .checkbox
            case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return .textField
            case "AXPopUpButton", "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXSlider", "AXIncrementor": return .option
            case "AXStaticText": return .text
            case "AXImage": return .image
            case "AXGroup", "AXLayoutArea": return .container
            default: return .unknown
            }
        }

        public func isActionableAXRole(_ role: String) -> Bool {
            actionableAXRoles.contains(role)
        }

        public func isPassiveAXRole(_ role: String) -> Bool {
            passiveAXRoles.contains(role)
        }

        public func isCanvasAXRole(_ role: String) -> Bool {
            canvasAXRoles.contains(role)
        }

        public func targetLooksFillable(_ target: String) -> Bool {
            let t = target.lowercased()
            return t.contains("field")
                || t.contains("box")
                || t.contains("search")
                || t.contains("placeholder")
                || t.contains("input")
                || t.contains("cell")
        }

        public func clickSafety(role: Role, source: Source, target: String) -> ClickSafety {
            switch source {
            case .accessibility:
                return role.isInteractive ? .safe : .passive
            case .visual:
                return role.isInteractive ? .safe : .passive
            case .ocr:
                return targetLooksFillable(target) && role == .textField ? .safe : .passive
            }
        }

        public func trust(source: Source, role: Role, confidence: Double, target: String) -> Double {
            switch source {
            case .accessibility:
                return role.isInteractive && confidence >= minAXScore / 3 ? 0.95 : 0.45
            case .visual:
                return 0.70
            case .ocr:
                return targetLooksFillable(target) && role == .textField ? 0.68 : 0.45
            }
        }

        public func acceptsAXCandidate(
            role axRole: String,
            score: Double,
            bounds: Bounds,
            displayWidthPoints: Int,
            displayHeightPoints: Int,
            appSkillHints: AppSkillRuntimeHints? = nil,
            runtimeProfile: AXRuntimeProfile? = nil
        ) -> Bool {
            guard appSkillHints?.axUnreliable != true else { return false }
            guard runtimeProfile?.isSparse != true else { return false }
            guard score >= minAXScore else { return false }
            guard isActionableAXRole(axRole) else { return false }
            guard bounds.isValid else { return false }
            let displayArea = Double(max(1, displayWidthPoints) * max(1, displayHeightPoints))
            guard bounds.area / displayArea <= maxCanvasAreaFraction else { return false }
            return true
        }
    }

    public static func build(
        from candidates: [Candidate],
        configuration: Configuration = .default
    ) -> [IndexedCandidate] {
        let validCandidates = candidates.filter { $0.bounds.isValid }
        guard !validCandidates.isEmpty else { return [] }

        let clusters = cluster(validCandidates, configuration: configuration)
        let indexed = clusters.map { merge(cluster: $0) }
            .sorted { readingOrderPrecedes($0, $1, rowTolerance: configuration.rowTolerance) }

        return indexed.enumerated().map { offset, candidate in
            let mark = SetOfMark(
                number: offset + 1,
                label: String(offset + 1),
                isSafeToClick: candidate.isSafeToClick)
            return candidate.withMark(mark)
        }
    }

    @MainActor
    public static func accessibilityCandidates(
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        limit: Int = 48,
        policy: TrustPolicy = .default,
        appSkillHints: AppSkillRuntimeHints? = nil,
        runtimeProfile: AXRuntimeProfile? = nil
    ) -> [Candidate] {
        guard appSkillHints?.axUnreliable != true else { return [] }
        guard runtimeProfile?.isSparse != true else { return [] }
        guard let displayBounds = captureDisplayBounds(
            widthPoints: displayWidthPoints,
            heightPoints: displayHeightPoints
        ) else {
            return []
        }
        return AXElementResolver.interactables(limit: limit).compactMap { match in
            guard let point = displayLocalPoint(
                cgGlobalCenter: match.center,
                displayCGBounds: displayBounds,
                displayHeightPoints: displayHeightPoints
            ) else { return nil }
            let role = policy.role(fromAXRole: match.role)
            let size = role == .textField ? CGSize(width: 180, height: 28) : CGSize(width: 96, height: 28)
            let bounds = Bounds(
                x: Double(point.x - size.width / 2),
                y: Double(point.y - size.height / 2),
                width: Double(size.width),
                height: Double(size.height)
            )
            guard policy.acceptsAXCandidate(
                role: match.role,
                score: max(match.score, policy.minAXScore),
                bounds: bounds,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                appSkillHints: appSkillHints,
                runtimeProfile: runtimeProfile
            ) else { return nil }
            let confidence = min(1, max(0.72, max(match.score, policy.minAXScore) / 3))
            return Candidate(
                bounds: bounds,
                label: match.title,
                role: role,
                source: .accessibility,
                confidence: confidence,
                trust: policy.trust(source: .accessibility, role: role, confidence: confidence, target: match.title),
                clickSafety: policy.clickSafety(role: role, source: .accessibility, target: match.title)
            )
        }
    }

    public static func ocrCandidates(
        from boxes: [ScreenTextRecognizer.TextBox],
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        imageWidthPixels: Int? = nil,
        imageHeightPixels: Int? = nil,
        policy: TrustPolicy = .default
    ) -> [Candidate] {
        boxes.compactMap { box in
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, text.count <= 80 else { return nil }
            let displayRect = rectFromVisionBox(
                box.boundingBox,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
            let imageRect = imageBoundsFromVisionBox(
                box.boundingBox,
                imageWidthPixels: imageWidthPixels,
                imageHeightPixels: imageHeightPixels
            )
            let role: Role = policy.targetLooksFillable(target) ? .textField : .text
            let confidence = Double(box.confidence)
            return Candidate(
                bounds: Bounds(displayRect),
                imageBounds: imageRect.map(Bounds.init),
                label: text,
                role: role,
                source: .ocr,
                confidence: confidence,
                trust: policy.trust(source: .ocr, role: role, confidence: confidence, target: target),
                clickSafety: policy.clickSafety(role: role, source: .ocr, target: target)
            )
        }
    }

    public static func ocrCandidates(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        level: VNRequestTextRecognitionLevel = .fast,
        policy: TrustPolicy = .default
    ) -> [Candidate] {
        let boxes = ScreenTextRecognizer.recognizeBoxes(inImageData: screenshot, level: level)
        let dimensions = imageDimensions(screenshot)
        return ocrCandidates(
            from: boxes,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            imageWidthPixels: dimensions?.width,
            imageHeightPixels: dimensions?.height,
            policy: policy
        )
    }

    public static func applyTargetAliases(_ target: String, aliases: [String: [String]]) -> String {
        let normalizedTarget = normalizedSearchLabel(target)
        guard !normalizedTarget.isEmpty else { return target }
        for (canonical, rawAliases) in aliases {
            let candidates = ([canonical] + rawAliases).map(normalizedSearchLabel).filter { !$0.isEmpty }
            guard candidates.contains(where: { normalizedTarget == $0 || normalizedTarget.contains($0) }) else {
                continue
            }
            return canonical
        }
        return target
    }

    public static func applyPreferredSourceHints(
        _ candidates: [Candidate],
        hints: AppSkillRuntimeHints?,
        target: String
    ) -> [Candidate] {
        guard let preferred = hints?.preferredGroundingSource?.lowercased(), !preferred.isEmpty else {
            return candidates
        }
        return candidates.map { candidate in
            let sourceName = candidate.source.rawValue.lowercased()
            let matches = preferred == sourceName
                || (preferred == "ax" && candidate.source == .accessibility)
                || (preferred == "accessibility" && candidate.source == .accessibility)
            let adjustedTrust = matches ? min(1, candidate.trust * 1.12) : max(0, candidate.trust * 0.88)
            return Candidate(
                bounds: candidate.bounds,
                imageBounds: candidate.imageBounds,
                label: candidate.label,
                role: candidate.role,
                source: candidate.source,
                confidence: candidate.confidence,
                trust: adjustedTrust,
                clickSafety: candidate.clickSafety
            )
        }
    }

    public static func normalizedSearchLabel(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(
                of: #"\b(the|a|an|button|field|box|link|menu|item|placeholder|input|control)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func textMatchScore(needle: String, candidate: String) -> Double {
        guard !needle.isEmpty, !candidate.isEmpty else { return 0 }
        if needle == candidate { return 3 }
        if candidate.contains(needle) || needle.contains(candidate) { return 2 }
        let needleWords = Set(needle.split(separator: " "))
        let candidateWords = Set(candidate.split(separator: " "))
        guard !needleWords.isEmpty else { return 0 }
        let overlap = Double(needleWords.intersection(candidateWords).count) / Double(needleWords.count)
        return overlap >= 0.75 ? 1 + overlap : 0
    }

    public static func bestCandidate(
        for target: String,
        in candidates: [IndexedCandidate],
        policy: TrustPolicy = .default
    ) -> IndexedCandidate? {
        let target = normalizedSearchLabel(target)
        guard !target.isEmpty else { return nil }
        var best: (candidate: IndexedCandidate, score: Double)?
        for candidate in candidates where candidate.isSafeToClick {
            let score = textMatchScore(needle: target, candidate: normalizedSearchLabel(candidate.label)) * candidate.trust
            guard score >= 1.30 else { continue }
            if best == nil
                || score > best!.score
                || (score == best!.score && candidate.source.rank > best!.candidate.source.rank)
                || (score == best!.score && candidate.source.rank == best!.candidate.source.rank && candidate.bounds.area < best!.candidate.bounds.area) {
                best = (candidate, score)
            }
        }
        return best?.candidate
    }

    public static func candidate(markNumber: Int, in candidates: [IndexedCandidate]) -> IndexedCandidate? {
        candidates.first { $0.mark.number == markNumber }
    }

    public static func renderMarkedJPEG(
        screenshot: Data,
        candidates: [IndexedCandidate],
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        compression: Double = 0.85
    ) -> Data? {
        guard let image = NSImage(data: screenshot) else { return nil }
        let dimensions = imageDimensions(screenshot)
        let pixelWidth = dimensions?.width ?? max(1, Int(image.size.width.rounded()))
        let pixelHeight = dimensions?.height ?? max(1, Int(image.size.height.rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        drawMarks(
            candidates: candidates,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
}

private extension ScreenElementIndex {
    static func cluster(
        _ candidates: [Candidate],
        configuration: Configuration
    ) -> [[Candidate]] {
        let ordered = candidates.sorted(by: candidateSortPrecedes)
        var parent = Array(0..<ordered.count)

        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }

        func union(_ left: Int, _ right: Int) {
            let leftRoot = root(left)
            let rightRoot = root(right)
            guard leftRoot != rightRoot else { return }
            parent[max(leftRoot, rightRoot)] = min(leftRoot, rightRoot)
        }

        for left in ordered.indices {
            for right in ordered.indices where right > left {
                if shouldMerge(ordered[left], ordered[right], configuration: configuration) {
                    union(left, right)
                }
            }
        }

        var grouped: [Int: [Candidate]] = [:]
        for index in ordered.indices {
            grouped[root(index), default: []].append(ordered[index])
        }

        return grouped.values
            .map { $0.sorted(by: candidateSortPrecedes) }
            .sorted { candidateSortPrecedes($0[0], $1[0]) }
    }

    static func shouldMerge(
        _ left: Candidate,
        _ right: Candidate,
        configuration: Configuration
    ) -> Bool {
        let hasOverlap = left.bounds.intersectionOverUnion(with: right.bounds) >= configuration.overlapThreshold
            || left.bounds.containmentOverlap(with: right.bounds) >= configuration.containmentThreshold
        guard hasOverlap else { return false }
        guard labelsCompatible(left.label, right.label) else { return false }
        return rolesCompatible(left.role, right.role)
    }

    static func labelsCompatible(_ left: String, _ right: String) -> Bool {
        let lhs = normalizedLabel(left)
        let rhs = normalizedLabel(right)
        if lhs.isEmpty || rhs.isEmpty { return true }
        if lhs == rhs { return true }
        guard min(lhs.count, rhs.count) >= 4 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    static func rolesCompatible(_ left: Role, _ right: Role) -> Bool {
        if left == right || left == .unknown || right == .unknown {
            return true
        }
        if left == .text || right == .text {
            return true
        }
        return false
    }

    static func merge(cluster: [Candidate]) -> IndexedCandidate {
        let ordered = cluster.sorted(by: candidateSortPrecedes)
        let primary = ordered.max(by: candidateQualityPrecedes) ?? ordered[0]
        let bounds = ordered.dropFirst().reduce(ordered[0].bounds) { partial, candidate in
            partial.union(candidate.bounds)
        }
        let imageBounds = ordered.compactMap(\.imageBounds).reduce(nil) { partial, candidate -> Bounds? in
            partial?.union(candidate) ?? candidate
        }
        let label = bestLabel(in: ordered, fallback: primary.label)
        let confidence = ordered.map(\.confidence).max() ?? primary.confidence
        let trust = ordered.map(\.trust).max() ?? primary.trust
        let clickSafety: ClickSafety = ordered.contains { $0.clickSafety == .unsafe } ? .unsafe : primary.clickSafety
        let sources = Array(Set(ordered.map(\.source))).sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return $0.rawValue < $1.rawValue
        }
        let id = stableID(bounds: bounds, label: label, role: primary.role)

        return IndexedCandidate(
            id: id,
            bounds: bounds,
            imageBounds: imageBounds,
            label: label,
            role: primary.role,
            source: primary.source,
            confidence: confidence,
            trust: trust,
            clickSafety: clickSafety,
            contributingSources: sources,
            mark: SetOfMark(number: 0, label: "", isSafeToClick: false))
    }

    static func bestLabel(in candidates: [Candidate], fallback: String) -> String {
        candidates
            .filter { !normalizedLabel($0.label).isEmpty }
            .max {
                if $0.trust != $1.trust { return $0.trust < $1.trust }
                if $0.confidence != $1.confidence { return $0.confidence < $1.confidence }
                if $0.source.rank != $1.source.rank { return $0.source.rank < $1.source.rank }
                return $0.label.count < $1.label.count
            }?
            .label ?? fallback
    }

    static func candidateSortPrecedes(_ left: Candidate, _ right: Candidate) -> Bool {
        let leftKey = candidateStableKey(left)
        let rightKey = candidateStableKey(right)
        return leftKey < rightKey
    }

    static func candidateQualityPrecedes(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.trust != right.trust { return left.trust < right.trust }
        if left.confidence != right.confidence { return left.confidence < right.confidence }
        if left.source.rank != right.source.rank { return left.source.rank < right.source.rank }
        if left.role.isInteractive != right.role.isInteractive { return !left.role.isInteractive && right.role.isInteractive }
        return candidateStableKey(left) > candidateStableKey(right)
    }

    static func readingOrderPrecedes(
        _ left: IndexedCandidate,
        _ right: IndexedCandidate,
        rowTolerance: Double
    ) -> Bool {
        if abs(left.bounds.y - right.bounds.y) > rowTolerance {
            return left.bounds.y < right.bounds.y
        }
        if left.bounds.x != right.bounds.x {
            return left.bounds.x < right.bounds.x
        }
        return left.id < right.id
    }

    static func stableID(bounds: Bounds, label: String, role: Role) -> String {
        let key = [
            normalizedLabel(label),
            role.rawValue,
            String(quantized(bounds.x)),
            String(quantized(bounds.y)),
            String(quantized(bounds.width)),
            String(quantized(bounds.height)),
        ].joined(separator: "|")
        return "se_\(fnv1a64(key))"
    }

    static func candidateStableKey(_ candidate: Candidate) -> String {
        [
            normalizedLabel(candidate.label),
            candidate.role.rawValue,
            String(quantized(candidate.bounds.x)),
            String(quantized(candidate.bounds.y)),
            String(quantized(candidate.bounds.width)),
            String(quantized(candidate.bounds.height)),
            candidate.source.rawValue,
            String(quantized(candidate.confidence * 1_000)),
            String(quantized(candidate.trust * 1_000)),
        ].joined(separator: "|")
    }

    static func normalizedLabel(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func rectFromVisionBox(
        _ box: CGRect,
        displayWidthPoints width: Int,
        displayHeightPoints height: Int
    ) -> CGRect {
        CGRect(
            x: box.minX * CGFloat(width),
            y: box.minY * CGFloat(height),
            width: box.width * CGFloat(width),
            height: box.height * CGFloat(height)
        )
    }

    static func imageBoundsFromVisionBox(
        _ box: CGRect,
        imageWidthPixels width: Int?,
        imageHeightPixels height: Int?
    ) -> CGRect? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGRect(
            x: box.minX * CGFloat(width),
            y: (1 - box.maxY) * CGFloat(height),
            width: box.width * CGFloat(width),
            height: box.height * CGFloat(height)
        )
    }

    static func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }

    @MainActor
    static func captureDisplayBounds(widthPoints: Int, heightPoints: Int) -> CGRect? {
        func dims(_ screen: NSScreen) -> Bool {
            Int(screen.frame.width.rounded()) == widthPoints
                && Int(screen.frame.height.rounded()) == heightPoints
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { dims($0) && NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first(where: dims)
        guard let screen, let mapper = DisplayCoordinateMapper(screen: screen) else { return nil }
        return mapper.cgBounds
    }

    static func displayLocalPoint(
        cgGlobalCenter point: CGPoint,
        displayCGBounds bounds: CGRect,
        displayHeightPoints: Int
    ) -> CGPoint? {
        let mapper = DisplayCoordinateMapper(
            displayID: CGMainDisplayID(),
            appKitFrame: CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(displayHeightPoints)),
            cgBounds: bounds,
            backingScaleFactor: 1
        )
        return mapper.screenLocalAppKit(fromCGGlobal: point)
    }

    static func drawMarks(
        candidates: [IndexedCandidate],
        pixelWidth: Int,
        pixelHeight: Int,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) {
        let sx = CGFloat(pixelWidth) / CGFloat(max(1, displayWidthPoints))
        let sy = CGFloat(pixelHeight) / CGFloat(max(1, displayHeightPoints))
        let stroke = NSColor.systemYellow
        let fill = NSColor.systemYellow.withAlphaComponent(0.92)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        for candidate in candidates.prefix(99) {
            let rect: CGRect
            if let imageBounds = candidate.imageBounds {
                rect = CGRect(
                    x: imageBounds.x,
                    y: CGFloat(pixelHeight) - CGFloat(imageBounds.maxY),
                    width: imageBounds.width,
                    height: imageBounds.height
                )
            } else {
                rect = CGRect(
                    x: CGFloat(candidate.bounds.x) * sx,
                    y: CGFloat(candidate.bounds.y) * sy,
                    width: CGFloat(candidate.bounds.width) * sx,
                    height: CGFloat(candidate.bounds.height) * sy
                )
            }
            stroke.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
            path.lineWidth = 2
            path.stroke()
            let label = candidate.mark.label as NSString
            let textSize = label.size(withAttributes: textAttrs)
            let badge = CGRect(
                x: rect.minX,
                y: min(CGFloat(pixelHeight) - textSize.height - 4, rect.maxY + 2),
                width: max(22, textSize.width + 8),
                height: textSize.height + 4
            )
            fill.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            label.draw(
                in: badge.insetBy(dx: 4, dy: 2),
                withAttributes: textAttrs
            )
        }
    }

    static func quantized(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        guard rounded.isFinite else { return 0 }
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 36)
    }
}

private extension ScreenElementIndex.Source {
    var defaultTrust: Double {
        switch self {
        case .accessibility: 0.95
        case .visual: 0.70
        case .ocr: 0.55
        }
    }
}

private extension Double {
    var clampedToUnit: Double {
        guard isFinite else { return 0 }
        return min(1, max(0, self))
    }
}

private extension ScreenElementIndex.Bounds {
    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.minX),
            y: Double(rect.minY),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}
