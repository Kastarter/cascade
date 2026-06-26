import Foundation

public protocol SemanticEmbeddingProvider: Sendable {
    var metadata: SemanticEmbeddingModelMetadata { get }

    func embedding(for text: String) async throws -> [Float]?
}

public struct SemanticEmbeddingModelMetadata: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let dimension: Int
    public let distanceMetric: VectorDistanceMetric

    public init(modelID: String, dimension: Int, distanceMetric: VectorDistanceMetric) {
        precondition(dimension > 0, "Semantic embedding dimension must be positive")
        self.modelID = modelID
        self.dimension = dimension
        self.distanceMetric = distanceMetric
    }

    public var cacheKeyPrefix: String {
        "semantic:v1:\(modelID.count):\(modelID):\(dimension):\(distanceMetric.rawValue)"
    }

    public func cacheKey(forNormalizedTextHash normalizedTextHash: String) -> String {
        "\(cacheKeyPrefix):\(normalizedTextHash)"
    }

    public func cacheKey(forText text: String) -> String {
        cacheKey(forNormalizedTextHash: SemanticEmbeddingText.stableHashHex(for: text))
    }
}

public enum VectorDistanceMetric: String, Codable, CaseIterable, Sendable {
    case cosine
    case dot
    case l2

    public func distance(between lhs: [Float], and rhs: [Float]) -> Float {
        switch self {
        case .cosine:
            1 - Self.cosineSimilarity(lhs, rhs)
        case .dot:
            -Self.dotProduct(lhs, rhs)
        case .l2:
            Self.squaredL2Distance(lhs, rhs)
        }
    }

    public func rankScore(query: [Float], candidate: [Float]) -> Float {
        switch self {
        case .cosine:
            Self.cosineSimilarity(query, candidate)
        case .dot:
            Self.dotProduct(query, candidate)
        case .l2:
            -Self.squaredL2Distance(query, candidate)
        }
    }

    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        let denominator = (lhsMagnitude * rhsMagnitude).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    public static func dotProduct(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
        }
        return dot
    }

    public static func squaredL2Distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        var total: Float = 0
        for index in lhs.indices {
            let delta = lhs[index] - rhs[index]
            total += delta * delta
        }
        return total
    }
}

public enum SemanticEmbeddingText {
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var tokens: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current.lowercased())
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current.lowercased())
        }
        return tokens.joined(separator: " ")
    }

    public static func stableHashHex(for text: String) -> String {
        stableHashHex(forNormalizedText: normalized(text))
    }

    public static func stableHashHex(forNormalizedText normalizedText: String) -> String {
        String(format: "%016llx", stableHash64(normalizedText))
    }

    static func stableHash64(_ text: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

public struct DeterministicHashSemanticEmbeddingProvider: SemanticEmbeddingProvider {
    public let metadata: SemanticEmbeddingModelMetadata

    public init(
        modelID: String = "cascade.hash-token-fallback.v1",
        dimension: Int = 384,
        distanceMetric: VectorDistanceMetric = .cosine
    ) {
        self.metadata = SemanticEmbeddingModelMetadata(
            modelID: modelID,
            dimension: dimension,
            distanceMetric: distanceMetric
        )
    }

    public func embedding(for text: String) async throws -> [Float]? {
        let normalized = SemanticEmbeddingText.normalized(text)
        let tokens = normalized.split(separator: " ")
        guard !tokens.isEmpty else { return nil }

        var vector = [Float](repeating: 0, count: metadata.dimension)
        for token in tokens {
            add(token: String(token), into: &vector)
        }
        normalize(&vector)
        return vector
    }

    private func add(token: String, into vector: inout [Float]) {
        var hash = SemanticEmbeddingText.stableHash64("\(metadata.modelID)\u{0}\(token)")
        for _ in 0..<4 {
            hash = splitMix64(hash)
            let index = Int(hash % UInt64(metadata.dimension))
            let sign: Float = (hash & 0x1) == 0 ? 1 : -1
            let weight = Float(((hash >> 8) & 0xff) + 1) / 256
            vector[index] += sign * weight
        }
    }

    private func normalize(_ vector: inout [Float]) {
        var magnitude: Float = 0
        for value in vector {
            magnitude += value * value
        }
        magnitude = magnitude.squareRoot()
        guard magnitude > 0 else { return }
        for index in vector.indices {
            vector[index] /= magnitude
        }
    }

    private func splitMix64(_ value: UInt64) -> UInt64 {
        var next = value &+ 0x9e3779b97f4a7c15
        next = (next ^ (next >> 30)) &* 0xbf58476d1ce4e5b9
        next = (next ^ (next >> 27)) &* 0x94d049bb133111eb
        return next ^ (next >> 31)
    }
}
