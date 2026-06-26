import Foundation
import NaturalLanguage

/// Categories of personally-identifiable information Cascade detects on device.
/// Seeded from the Presidio entity taxonomy (SEQ-07), trimmed to what we can
/// detect deterministically or with Apple's on-device detectors — no network,
/// no shipped Python.
public enum PIIType: String, Sendable, CaseIterable {
    case email = "EMAIL"
    case phone = "PHONE"
    case creditCard = "CREDIT_CARD"
    case ssn = "SSN"
    case iban = "IBAN"
    case apiKey = "API_KEY"
    case ipAddress = "IP"
    case url = "URL"
    case person = "PERSON"

    /// High-confidence types are deterministic (regex + checksum) and rarely
    /// false-positive, so they are safe to redact automatically (e.g. from the
    /// audit log). `person`/`url`/`ipAddress`/`phone` are lower-confidence hints
    /// and are only redacted when the caller opts in.
    public var isHighConfidence: Bool {
        switch self {
        case .email, .creditCard, .ssn, .iban, .apiKey: true
        case .phone, .ipAddress, .url, .person: false
        }
    }

    /// The placeholder substituted on redaction, e.g. `<EMAIL>`.
    public var placeholder: String { "<\(rawValue)>" }
}

/// One detected PII span.
public struct PIIFinding: Equatable, Sendable {
    public let type: PIIType
    public let range: Range<String.Index>
    public let text: String

    public init(type: PIIType, range: Range<String.Index>, text: String) {
        self.type = type
        self.range = range
        self.text = text
    }
}

/// On-device PII detection and redaction.
///
/// Deterministic recognizers (regex + Luhn/structure checks) handle emails,
/// credit cards, SSNs, IBANs, and common API-key shapes; Apple's `NSDataDetector`
/// handles phone numbers and links; `NLTagger` provides lower-confidence person
/// names. Detection is never assumed complete — Presidio itself warns no
/// automated detector catches everything — so this is a recall layer in front of
/// the existing `PrivacyRules` drop list, not a replacement for it.
public enum PIIDetector {

    // MARK: - Public API

    /// All non-overlapping PII spans found in `text`, earliest first. Names are
    /// off by default (higher false-positive rate, and slower).
    public static func findings(in text: String, includeNames: Bool = false) -> [PIIFinding] {
        guard !text.isEmpty else { return [] }
        var found: [PIIFinding] = []
        for type in PIIType.allCases {
            if type == .person { continue }       // handled below (opt-in)
            found += regexFindings(in: text, type: type)
        }
        found += dataDetectorFindings(in: text)
        if includeNames { found += nameFindings(in: text) }
        return dedupeByPriority(found)
    }

    /// Replaces every detected span with its typed placeholder (`<EMAIL>`, …),
    /// returning the redacted text and the findings. High-confidence-only by
    /// default so it can't mangle ordinary text it merely resembles.
    public static func redact(
        _ text: String, includeNames: Bool = false, highConfidenceOnly: Bool = true
    ) -> (redacted: String, findings: [PIIFinding]) {
        let all = findings(in: text, includeNames: includeNames)
        let targets = highConfidenceOnly ? all.filter { $0.type.isHighConfidence } : all
        guard !targets.isEmpty else { return (text, []) }
        var result = text
        // Replace back-to-front so earlier ranges stay valid.
        for finding in targets.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(finding.range, with: finding.type.placeholder)
        }
        return (result, targets)
    }

    /// Fast check for high-confidence PII (email/card/SSN/IBAN/API key). Used to
    /// gate audit-detail and harness output where any leak is unacceptable.
    public static func containsHighConfidencePII(_ text: String) -> Bool {
        for type in PIIType.allCases where type.isHighConfidence {
            if !regexFindings(in: text, type: type).isEmpty { return true }
        }
        return false
    }

    // MARK: - Regex recognizers

    private static let patterns: [(PIIType, String)] = [
        (.email, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        (.ssn, #"\b\d{3}-\d{2}-\d{4}\b"#),
        (.iban, #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#),
        (.ipAddress, #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#),
        // High-confidence API-key shapes (specific prefixes only — generic long
        // tokens are too noisy to auto-redact).
        (.apiKey, #"\b(?:sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{35})\b"#),
        // Candidate card numbers (13–19 digits, optional space/dash groups);
        // confirmed by Luhn below.
        (.creditCard, #"\b(?:\d[ \-]?){13,19}\b"#),
    ]

    private static func regexFindings(in text: String, type: PIIType) -> [PIIFinding] {
        let pattern = patterns.first { $0.0 == type }?.1
        guard let pattern, let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var results: [PIIFinding] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let matched = String(text[range])
            if type == .creditCard, !luhnValid(matched) { return }  // reject non-cards
            results.append(PIIFinding(type: type, range: range, text: matched))
        }
        return results
    }

    /// Luhn checksum over a 13–19 digit candidate (spaces/dashes stripped).
    private static func luhnValid(_ candidate: String) -> Bool {
        let digits = candidate.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    // MARK: - Apple detectors

    private static func dataDetectorFindings(in text: String) -> [PIIFinding] {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let ns = text as NSString
        var results: [PIIFinding] = []
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let kind: PIIType? = match.resultType == .phoneNumber ? .phone : (match.resultType == .link ? .url : nil)
            // mailto: links double-count emails the regex already found — skip.
            if match.resultType == .link, match.url?.scheme == "mailto" { return }
            guard let kind else { return }
            results.append(PIIFinding(type: kind, range: range, text: String(text[range])))
        }
        return results
    }

    private static func nameFindings(in text: String) -> [PIIFinding] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var results: [PIIFinding] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .personalName {
                results.append(PIIFinding(type: .person, range: range, text: String(text[range])))
            }
            return true
        }
        return results
    }

    // MARK: - Overlap resolution

    /// When spans overlap (e.g. a URL inside which a regex also matched), keep the
    /// higher-priority type and drop the overlap, leaving non-overlapping spans
    /// ordered by start index.
    private static func dedupeByPriority(_ findings: [PIIFinding]) -> [PIIFinding] {
        let priority: [PIIType] = [.email, .creditCard, .ssn, .iban, .apiKey, .ipAddress, .phone, .url, .person]
        let ordered = findings.sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            let a = priority.firstIndex(of: $0.type) ?? .max
            let b = priority.firstIndex(of: $1.type) ?? .max
            return a < b
        }
        var kept: [PIIFinding] = []
        for finding in ordered {
            if let last = kept.last, finding.range.lowerBound < last.range.upperBound { continue }
            kept.append(finding)
        }
        return kept
    }
}
