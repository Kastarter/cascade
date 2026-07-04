// LEAF TARGET — no package dependencies. See Geometry.swift header.
//
// AXMatchScore (integer 0...3) and Confidence (0...1) are DISTINCT types with exactly
// ONE explicit bridge (`AXMatchScore.normalized()`), so mixing the two units — the
// 34c2efa bug class, where a raw 0...3 AX score was compared against a 0...1
// confidence threshold — fails to COMPILE instead of silently mis-routing.

/// A structural AX match score in 0...3 (0 = no match, 3 = exact role+label match).
/// Deliberately NOT ExpressibleByIntegerLiteral and exposes no Double accessor:
/// the only way out of this unit is the explicit `normalized()` bridge.
public struct AXMatchScore: Sendable, Hashable, Codable, Comparable {
    public let raw: Int

    /// Pins the score into 0...3.
    public init(clamping value: Int) {
        self.raw = min(max(value, 0), 3)
    }

    public static func < (lhs: AXMatchScore, rhs: AXMatchScore) -> Bool {
        lhs.raw < rhs.raw
    }

    private enum CodingKeys: String, CodingKey { case raw }

    /// Hand-written so DECODING also routes through the clamp: a persisted/model-adjacent
    /// JSON payload of `{"raw": 9}` decodes to 3, never to an out-of-range score.
    /// (Encoding stays synthesized with the same key — byte-identical on the wire.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(clamping: try container.decode(Int.self, forKey: .raw))
    }

    /// The ONE bridge from match-score units to confidence units.
    /// `Confidence(clamping: Double(raw) / 3.0)`. No other AXMatchScore↔Double or
    /// AXMatchScore↔Confidence path exists — this is what kills the 34c2efa bug class.
    public func normalized() -> Confidence {
        Confidence(clamping: Double(raw) / 3.0)
    }
}

/// A grounding confidence in 0...1.
public struct Confidence: Sendable, Hashable, Codable, Comparable {
    public let value: Double

    /// Pins the value into 0...1 (non-finite input pins to 0).
    public init(clamping value: Double) {
        if value.isFinite {
            self.value = min(max(value, 0), 1)
        } else {
            self.value = 0
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.value < rhs.value
    }

    private enum CodingKeys: String, CodingKey { case value }

    /// Hand-written so DECODING also routes through the clamp: a persisted/model-adjacent
    /// JSON payload of `{"value": 7.3}` decodes to 1.0, never to an out-of-range confidence.
    /// (Encoding stays synthesized with the same key — byte-identical on the wire.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(clamping: try container.decode(Double.self, forKey: .value))
    }
}
