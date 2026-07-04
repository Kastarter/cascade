// LEAF TARGET — imports Foundation at most; importing ProviderKit/AppShell/ComputerUseKit
// is a build error by Package.swift construction (PerceptionCore declares ZERO package deps).
// Phantom-typed geometry: a Point<AXSpace> can never be passed where a Point<FrameSpace>
// is expected — cross-space mixups become COMPILE errors, not runtime drift.
// There is deliberately NO cross-space init and NO CGPoint/CGRect conversion here;
// conversions land at the actuator boundary in later tasks.

/// Marker protocol for coordinate spaces — a phantom tag with ONE requirement:
/// a stable `spaceTag` persisted alongside every Point/Rect so the compile-time
/// cross-space guarantee survives serialization. Without it, `Point<AXSpace>` JSON
/// would silently decode into `Point<FrameSpace>` (a runtime bypass of the phantom
/// type); with it, a cross-space decode THROWS — degrade to MISSED, never FALSE.
public protocol CoordinateSpace {
    /// Stable, unique discriminator written into encoded Points/Rects and
    /// validated on decode. Treat as a persisted format: never change it.
    static var spaceTag: String { get }
}

/// Accessibility-API coordinate space (CG-global, top-left origin).
public enum AXSpace: CoordinateSpace {
    public static let spaceTag = "ax"
}

/// Captured-frame pixel space (the space the model sees screenshots in).
public enum FrameSpace: CoordinateSpace {
    public static let spaceTag = "frame"
}

/// CGEvent posting space (display-local AppKit points).
public enum EventSpace: CoordinateSpace {
    public static let spaceTag = "event"
}

/// Web sandbox viewport space (WKWebView CSS pixels).
public enum WebViewportSpace: CoordinateSpace {
    public static let spaceTag = "webViewport"
}

/// A point tagged with the coordinate space it was measured in.
public struct Point<Space: CoordinateSpace>: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey { case x, y, space }

    /// Decode REQUIRES the payload's space tag to match `Space` — cross-space
    /// JSON fails loudly instead of silently re-tagging into the wrong space.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .space)
        guard tag == Space.spaceTag else {
            throw DecodingError.dataCorruptedError(
                forKey: .space, in: container,
                debugDescription: "coordinate-space mismatch: payload is '\(tag)', expected '\(Space.spaceTag)'"
            )
        }
        self.x = try container.decode(Double.self, forKey: .x)
        self.y = try container.decode(Double.self, forKey: .y)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(Space.spaceTag, forKey: .space)
    }
}

/// A rectangle tagged with the coordinate space it was measured in.
public struct Rect<Space: CoordinateSpace>: Sendable, Hashable, Codable {
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

    public var midpoint: Point<Space> {
        Point(x: x + width / 2, y: y + height / 2)
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height, space }

    /// Decode REQUIRES the payload's space tag to match `Space` — see Point.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .space)
        guard tag == Space.spaceTag else {
            throw DecodingError.dataCorruptedError(
                forKey: .space, in: container,
                debugDescription: "coordinate-space mismatch: payload is '\(tag)', expected '\(Space.spaceTag)'"
            )
        }
        self.x = try container.decode(Double.self, forKey: .x)
        self.y = try container.decode(Double.self, forKey: .y)
        self.width = try container.decode(Double.self, forKey: .width)
        self.height = try container.decode(Double.self, forKey: .height)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(Space.spaceTag, forKey: .space)
    }
}
