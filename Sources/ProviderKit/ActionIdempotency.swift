import CoreFoundation
import CryptoKit
import Foundation

public enum ActionIdempotencyError: Error, Equatable, Sendable {
    case emptyOperation
    case unsupportedJSONValue(String)
    case nonFiniteNumber
}

public enum ActionRetryClass: String, Codable, Equatable, Hashable, Sendable {
    case pureModelCall = "pure_model_call"
    case groundingLookup = "grounding_lookup"
    case readOnlyTool = "read_only_tool"
    case nonIdempotentAction = "non_idempotent_action"

    public var allowsAutomaticRetry: Bool {
        self != .nonIdempotentAction
    }
}

public struct ActionIdempotencyKey: Hashable, Sendable, CustomStringConvertible {
    public enum PrivateTextPolicy: String, Codable, Equatable, Hashable, Sendable {
        case exclude
        case hash
        case include
    }

    public static let defaultPrivateTextFields: Set<String> = [
        "text",
        "typedText",
        "typed_text",
        "textToType",
        "text_to_type",
        "privateText",
        "private_text"
    ]

    public let rawValue: String
    public let digest: String
    public let retryClass: ActionRetryClass
    public let canonicalPayload: String

    public var description: String { rawValue }

    public init(
        retryClass: ActionRetryClass,
        operation: String,
        model: String,
        prompt: String,
        schema: String,
        payload: Any,
        privateTextPolicy: PrivateTextPolicy = .exclude,
        privateTextFields: Set<String> = ActionIdempotencyKey.defaultPrivateTextFields
    ) throws {
        let trimmedOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOperation.isEmpty else {
            throw ActionIdempotencyError.emptyOperation
        }

        let canonicalPayload = try Self.renderCanonicalJSON(
            payload,
            privateTextPolicy: privateTextPolicy,
            privateTextFields: Self.normalizedPrivateTextFields(privateTextFields),
            path: []
        )
        let identity = Self.canonicalIdentity([
            ("retryClass", retryClass.rawValue),
            ("operation", trimmedOperation),
            ("model", model),
            ("prompt", prompt),
            ("schema", schema),
            ("privateTextPolicy", privateTextPolicy.rawValue),
            ("payload", canonicalPayload)
        ])
        let digest = Self.sha256Hex(identity)

        self.rawValue = "action:\(digest)"
        self.digest = digest
        self.retryClass = retryClass
        self.canonicalPayload = canonicalPayload
    }

    private static func normalizedPrivateTextFields(_ fields: Set<String>) -> Set<String> {
        Set(fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    private static func canonicalIdentity(_ fields: [(String, String)]) -> String {
        fields
            .map { key, value in "\(key.utf8.count):\(key)=\(value.utf8.count):\(value)" }
            .joined(separator: "\u{1f}")
    }

    private static func renderCanonicalJSON(
        _ value: Any,
        privateTextPolicy: PrivateTextPolicy,
        privateTextFields: Set<String>,
        path: [String]
    ) throws -> String {
        if value is NSNull {
            return "null"
        }

        if let dictionary = value as? [String: Any] {
            let fields = try dictionary.keys.sorted().map { key in
                let renderedValue: String
                if isPrivateTextField(key: key, path: path, privateTextFields: privateTextFields) {
                    renderedValue = try renderPrivateTextValue(
                        dictionary[key] as Any,
                        policy: privateTextPolicy,
                        privateTextFields: privateTextFields,
                        path: path + [key]
                    )
                } else {
                    renderedValue = try renderCanonicalJSON(
                        dictionary[key] as Any,
                        privateTextPolicy: privateTextPolicy,
                        privateTextFields: privateTextFields,
                        path: path + [key]
                    )
                }
                return "\(try quotedJSONString(key)):\(renderedValue)"
            }
            return "{\(fields.joined(separator: ","))}"
        }

        if let dictionary = value as? [AnyHashable: Any] {
            var stringKeyed: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key.base as? String else {
                    throw ActionIdempotencyError.unsupportedJSONValue("non-string dictionary key")
                }
                stringKeyed[key] = value
            }
            return try renderCanonicalJSON(
                stringKeyed,
                privateTextPolicy: privateTextPolicy,
                privateTextFields: privateTextFields,
                path: path
            )
        }

        if let array = value as? [Any] {
            let values = try array.map {
                try renderCanonicalJSON(
                    $0,
                    privateTextPolicy: privateTextPolicy,
                    privateTextFields: privateTextFields,
                    path: path
                )
            }
            return "[\(values.joined(separator: ","))]"
        }

        if let string = value as? String {
            return try quotedJSONString(string)
        }

        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }

        if let int = value as? Int {
            return String(int)
        }

        if let int8 = value as? Int8 {
            return String(int8)
        }

        if let int16 = value as? Int16 {
            return String(int16)
        }

        if let int32 = value as? Int32 {
            return String(int32)
        }

        if let int64 = value as? Int64 {
            return String(int64)
        }

        if let uint = value as? UInt {
            return String(uint)
        }

        if let uint8 = value as? UInt8 {
            return String(uint8)
        }

        if let uint16 = value as? UInt16 {
            return String(uint16)
        }

        if let uint32 = value as? UInt32 {
            return String(uint32)
        }

        if let uint64 = value as? UInt64 {
            return String(uint64)
        }

        if let double = value as? Double {
            return try renderNumber(double)
        }

        if let float = value as? Float {
            return try renderNumber(Double(float))
        }

        if let number = value as? NSNumber {
            return try renderNSNumber(number)
        }

        throw ActionIdempotencyError.unsupportedJSONValue(String(describing: type(of: value)))
    }

    private static func renderNSNumber(_ number: NSNumber) throws -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }

        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            return String(number.int64Value)
        case "C", "S", "I", "L", "Q":
            return String(number.uint64Value)
        case "f", "d":
            return try renderNumber(number.doubleValue)
        default:
            break
        }

        switch CFNumberGetType(number as CFNumber) {
        case .charType, .shortType, .intType, .longType, .longLongType,
             .cfIndexType, .nsIntegerType,
             .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type:
            return String(number.int64Value)
        case .floatType, .doubleType, .cgFloatType, .float32Type, .float64Type:
            return try renderNumber(number.doubleValue)
        @unknown default:
            throw ActionIdempotencyError.unsupportedJSONValue("unsupported NSNumber type")
        }
    }

    private static func renderPrivateTextValue(
        _ value: Any,
        policy: PrivateTextPolicy,
        privateTextFields: Set<String>,
        path: [String]
    ) throws -> String {
        switch policy {
        case .exclude:
            return #"{"__privateText":"excluded"}"#
        case .hash:
            let canonicalValue = try renderCanonicalJSON(
                value,
                privateTextPolicy: .include,
                privateTextFields: privateTextFields,
                path: path
            )
            return #"{"__privateTextSHA256":"\#(sha256Hex(canonicalValue))"}"#
        case .include:
            return try renderCanonicalJSON(
                value,
                privateTextPolicy: .include,
                privateTextFields: privateTextFields,
                path: path
            )
        }
    }

    private static func isPrivateTextField(key: String, path: [String], privateTextFields: Set<String>) -> Bool {
        let normalizedKey = key.lowercased()
        let normalizedPath = (path + [key]).joined(separator: ".").lowercased()
        return privateTextFields.contains(normalizedKey) || privateTextFields.contains(normalizedPath)
    }

    private static func renderNumber(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw ActionIdempotencyError.nonFiniteNumber
        }
        return String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func quotedJSONString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [])
        guard let rendered = String(data: data, encoding: .utf8) else {
            throw ActionIdempotencyError.unsupportedJSONValue("invalid UTF-8 string")
        }
        return String(rendered.dropFirst().dropLast())
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum RetryErrorClassification: String, Codable, Equatable, Hashable, Sendable {
    case transient
    case nonTransient
}

public enum RetryErrorClassifier {
    public static func classify(httpStatusCode: Int?) -> RetryErrorClassification {
        guard let httpStatusCode else { return .transient }

        switch httpStatusCode {
        case 408, 409, 425, 429:
            return .transient
        case 500...599:
            return .transient
        default:
            return .nonTransient
        }
    }

    public static func classify(urlErrorCode: URLError.Code) -> RetryErrorClassification {
        switch urlErrorCode {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .requestBodyStreamExhausted,
             .backgroundSessionWasDisconnected:
            return .transient
        default:
            return .nonTransient
        }
    }

    public static func classify(_ error: Error) -> RetryErrorClassification {
        if let urlError = error as? URLError {
            return classify(urlErrorCode: urlError.code)
        }
        return .nonTransient
    }
}

public struct RetryBackoffPolicy: Equatable, Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterFraction: Double
    public let jitterSeed: UInt64?

    public init(
        maxRetries: Int = 2,
        baseDelay: TimeInterval = 0.25,
        maxDelay: TimeInterval = 5,
        jitterFraction: Double = 0,
        jitterSeed: UInt64? = nil
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitterFraction = min(max(0, jitterFraction), 1)
        self.jitterSeed = jitterSeed
    }

    public func delay(
        afterRetryCount retryCount: Int,
        retryClass: ActionRetryClass,
        classification: RetryErrorClassification,
        key: ActionIdempotencyKey? = nil
    ) -> TimeInterval? {
        guard retryClass.allowsAutomaticRetry,
              classification == .transient,
              retryCount >= 0,
              retryCount < maxRetries else {
            return nil
        }

        let exponent = min(retryCount, 30)
        let exponentialDelay = baseDelay * pow(2, Double(exponent))
        var delay = min(exponentialDelay, maxDelay)

        if jitterFraction > 0, let jitterSeed {
            let unit = Self.deterministicUnit(seed: jitterSeed, retryCount: retryCount, key: key?.rawValue)
            let multiplier = 1 + ((unit * 2) - 1) * jitterFraction
            delay = min(max(0, delay * multiplier), maxDelay)
        }

        return delay
    }

    private static func deterministicUnit(seed: UInt64, retryCount: Int, key: String?) -> Double {
        var state = seed
        state &+= UInt64(bitPattern: Int64(retryCount)) &* 0x9E37_79B9_7F4A_7C15

        if let key {
            for byte in key.utf8 {
                state ^= UInt64(byte)
                state = state &* 0x100_0000_01B3
            }
        }

        let mixed = splitMix64(state)
        return Double(mixed >> 11) / Double(1 << 53)
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
