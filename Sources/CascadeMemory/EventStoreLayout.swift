import Foundation
#if canImport(Compression)
import Compression
#endif

public enum EventStoreLayout: Sendable {
    public static let millisecondsPerSecond: Int64 = 1_000
    public static let millisecondsPerDay: Int64 = 86_400_000

    public static func capturedMilliseconds(for date: Date) -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * Double(millisecondsPerSecond)
        if milliseconds.isNaN { return 0 }
        if milliseconds >= Double(Int64.max) { return Int64.max }
        if milliseconds <= Double(Int64.min) { return Int64.min }
        return Int64(milliseconds.rounded(.toNearestOrAwayFromZero))
    }

    public static func date(fromCapturedMilliseconds capturedMilliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(capturedMilliseconds) / TimeInterval(millisecondsPerSecond))
    }

    public static func utcDayKey(for date: Date) -> String {
        utcDayKey(capturedMilliseconds: capturedMilliseconds(for: date))
    }

    public static func utcDayKey(capturedMilliseconds: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date(fromCapturedMilliseconds: capturedMilliseconds)
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    public static func retentionChunks(
        from lowerBound: Int64,
        upTo upperBound: Int64,
        maxChunkMilliseconds: Int64 = millisecondsPerDay
    ) -> [CapturedMillisecondsRange] {
        guard lowerBound < upperBound, maxChunkMilliseconds > 0 else { return [] }

        var chunks: [CapturedMillisecondsRange] = []
        var start = lowerBound
        while start < upperBound {
            let end: Int64
            if start > Int64.max - maxChunkMilliseconds {
                end = upperBound
            } else {
                end = min(start + maxChunkMilliseconds, upperBound)
            }
            guard end > start else { break }
            chunks.append(CapturedMillisecondsRange(lowerBound: start, upperBound: end))
            start = end
        }
        return chunks
    }
}

public struct CapturedMillisecondsRange: Equatable, Sendable {
    public let lowerBound: Int64
    public let upperBound: Int64

    public init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var spanMilliseconds: Int64 {
        max(0, upperBound - lowerBound)
    }

    public func contains(_ capturedMilliseconds: Int64) -> Bool {
        lowerBound <= capturedMilliseconds && capturedMilliseconds < upperBound
    }
}

public struct DayPartitionManifest: Codable, Equatable, Sendable {
    public let dayKey: String
    public private(set) var rowCount: Int
    public private(set) var byteCount: Int
    public private(set) var firstCapturedMilliseconds: Int64?
    public private(set) var lastCapturedMilliseconds: Int64?
    public private(set) var firstID: Int64?
    public private(set) var lastID: Int64?

    public init(
        dayKey: String,
        rowCount: Int = 0,
        byteCount: Int = 0,
        firstCapturedMilliseconds: Int64? = nil,
        lastCapturedMilliseconds: Int64? = nil,
        firstID: Int64? = nil,
        lastID: Int64? = nil
    ) {
        self.dayKey = dayKey
        self.rowCount = rowCount
        self.byteCount = byteCount
        self.firstCapturedMilliseconds = firstCapturedMilliseconds
        self.lastCapturedMilliseconds = lastCapturedMilliseconds
        self.firstID = firstID
        self.lastID = lastID
    }

    public var isEmpty: Bool {
        rowCount == 0
    }

    public mutating func include(rowID: Int64, capturedMilliseconds: Int64, byteCount: Int) {
        rowCount += 1
        self.byteCount += max(0, byteCount)

        if firstCapturedMilliseconds == nil
            || capturedMilliseconds < (firstCapturedMilliseconds ?? capturedMilliseconds)
            || (capturedMilliseconds == firstCapturedMilliseconds && rowID < (firstID ?? rowID)) {
            firstCapturedMilliseconds = capturedMilliseconds
            firstID = rowID
        }

        if lastCapturedMilliseconds == nil
            || capturedMilliseconds > (lastCapturedMilliseconds ?? capturedMilliseconds)
            || (capturedMilliseconds == lastCapturedMilliseconds && rowID > (lastID ?? rowID)) {
            lastCapturedMilliseconds = capturedMilliseconds
            lastID = rowID
        }
    }

    public mutating func merge(_ other: DayPartitionManifest) {
        precondition(dayKey == other.dayKey, "cannot merge manifests from different day partitions")
        guard !other.isEmpty else { return }

        rowCount += other.rowCount
        byteCount += other.byteCount

        if let otherFirstCaptured = other.firstCapturedMilliseconds, let otherFirstID = other.firstID,
           firstCapturedMilliseconds == nil
            || otherFirstCaptured < (firstCapturedMilliseconds ?? otherFirstCaptured)
            || (otherFirstCaptured == firstCapturedMilliseconds && otherFirstID < (firstID ?? otherFirstID)) {
            firstCapturedMilliseconds = otherFirstCaptured
            firstID = otherFirstID
        }

        if let otherLastCaptured = other.lastCapturedMilliseconds, let otherLastID = other.lastID,
           lastCapturedMilliseconds == nil
            || otherLastCaptured > (lastCapturedMilliseconds ?? otherLastCaptured)
            || (otherLastCaptured == lastCapturedMilliseconds && otherLastID > (lastID ?? otherLastID)) {
            lastCapturedMilliseconds = otherLastCaptured
            lastID = otherLastID
        }
    }

    public func merged(with other: DayPartitionManifest) -> DayPartitionManifest {
        var copy = self
        copy.merge(other)
        return copy
    }
}

public enum ContextTextBlobError: Error, Equatable, Sendable {
    case corruptedPayload
    case invalidUTF8
}

public struct ContextTextBlob: Equatable, Sendable {
    public enum Codec: UInt8, Codable, Equatable, Sendable {
        case plainUTF8 = 0
        case lzfse = 1
    }

    public let codec: Codec
    public let originalByteCount: Int
    public let excerptUTF8: Data
    public let payload: Data

    public init(codec: Codec, originalByteCount: Int, excerptUTF8: Data, payload: Data) {
        self.codec = codec
        self.originalByteCount = originalByteCount
        self.excerptUTF8 = excerptUTF8
        self.payload = payload
    }

    public static func encode(
        _ text: String,
        excerptCharacterLimit: Int = 512,
        preferCompression: Bool = true
    ) -> ContextTextBlob {
        let original = Data(text.utf8)
        let excerptLimit = max(0, excerptCharacterLimit)
        let excerpt = Data(String(text.prefix(excerptLimit)).utf8)

        if preferCompression,
           let compressed = ContextTextCompressor.compress(original),
           compressed.count < original.count {
            return ContextTextBlob(
                codec: .lzfse,
                originalByteCount: original.count,
                excerptUTF8: excerpt,
                payload: compressed
            )
        }

        return ContextTextBlob(
            codec: .plainUTF8,
            originalByteCount: original.count,
            excerptUTF8: excerpt,
            payload: original
        )
    }

    public var payloadByteCount: Int {
        payload.count
    }

    public var storedByteCount: Int {
        payload.count + excerptUTF8.count
    }

    public func decodeText() throws -> String {
        let decoded: Data
        switch codec {
        case .plainUTF8:
            decoded = payload
        case .lzfse:
            guard let inflated = ContextTextCompressor.decompress(payload, byteCount: originalByteCount) else {
                throw ContextTextBlobError.corruptedPayload
            }
            decoded = inflated
        }

        guard decoded.count == originalByteCount else {
            throw ContextTextBlobError.corruptedPayload
        }
        guard let text = String(data: decoded, encoding: .utf8) else {
            throw ContextTextBlobError.invalidUTF8
        }
        return text
    }

    public func excerpt(maxCharacters: Int) -> String {
        guard maxCharacters > 0,
              let preview = String(data: excerptUTF8, encoding: .utf8) else {
            return ""
        }
        return String(preview.prefix(maxCharacters))
    }
}

private enum ContextTextCompressor {
    static func compress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return Data() }

        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: max(64, data.count + (data.count / 16) + 64))
        let encodedCount = source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    destinationBuffer.count,
                    sourceBase,
                    sourceBuffer.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }

        guard encodedCount > 0 else { return nil }
        return Data(destination.prefix(encodedCount))
        #else
        return nil
        #endif
    }

    static func decompress(_ data: Data, byteCount: Int) -> Data? {
        #if canImport(Compression)
        guard byteCount >= 0 else { return nil }
        guard byteCount > 0 else { return Data() }

        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: byteCount)
        let decodedCount = source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    destinationBuffer.count,
                    sourceBase,
                    sourceBuffer.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }

        guard decodedCount == byteCount else { return nil }
        return Data(destination)
        #else
        return nil
        #endif
    }
}
