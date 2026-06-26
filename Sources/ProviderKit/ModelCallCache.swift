import CoreFoundation
import CryptoKit
import Foundation

public enum ModelCallCacheError: Error, Equatable, Sendable {
    case invalidJSONBody
    case unsupportedJSONValue(String)
    case nonFiniteTemperature
}

public struct ModelCallRequest: Hashable, Sendable {
    public let model: String
    public let apiVersion: String
    public let betaVersion: String?
    public let temperature: Double?
    public let maxTokens: Int
    public let promptVersion: String
    public let schemaVersion: String
    public let callsite: String
    public let canonicalBody: String
    public let canonicalRequestHash: String

    public init(
        model: String,
        apiVersion: String,
        betaVersion: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        promptVersion: String,
        schemaVersion: String,
        callsite: String,
        body: Data
    ) throws {
        if let temperature, !temperature.isFinite {
            throw ModelCallCacheError.nonFiniteTemperature
        }

        let canonicalBody = try Self.canonicalJSON(from: body)

        self.model = model
        self.apiVersion = apiVersion
        self.betaVersion = betaVersion
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.callsite = callsite
        self.canonicalBody = canonicalBody
        self.canonicalRequestHash = Self.hash(
            model: model,
            apiVersion: apiVersion,
            betaVersion: betaVersion,
            temperature: temperature,
            maxTokens: maxTokens,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion,
            callsite: callsite,
            canonicalBody: canonicalBody
        )
    }

    public static func canonicalJSON(from body: Data) throws -> String {
        do {
            let object = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
            return try renderCanonicalJSON(object)
        } catch let error as ModelCallCacheError {
            throw error
        } catch {
            throw ModelCallCacheError.invalidJSONBody
        }
    }

    private static func hash(
        model: String,
        apiVersion: String,
        betaVersion: String?,
        temperature: Double?,
        maxTokens: Int,
        promptVersion: String,
        schemaVersion: String,
        callsite: String,
        canonicalBody: String
    ) -> String {
        let canonical = [
            ("model", model),
            ("apiVersion", apiVersion),
            ("betaVersion", betaVersion ?? ""),
            ("temperature", temperature.map(canonicalTemperature) ?? "nil"),
            ("maxTokens", String(maxTokens)),
            ("promptVersion", promptVersion),
            ("schemaVersion", schemaVersion),
            ("callsite", callsite),
            ("body", canonicalBody)
        ]
            .map { key, value in "\(key.utf8.count):\(key)=\(value.utf8.count):\(value)" }
            .joined(separator: "\u{1f}")

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalTemperature(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func renderCanonicalJSON(_ value: Any) throws -> String {
        if value is NSNull {
            return "null"
        }

        if let dictionary = value as? [String: Any] {
            let fields = try dictionary.keys.sorted().map { key in
                let renderedValue = try renderCanonicalJSON(dictionary[key] as Any)
                return "\(try quotedJSONString(key)):\(renderedValue)"
            }
            return "{\(fields.joined(separator: ","))}"
        }

        if let array = value as? [Any] {
            let values = try array.map(renderCanonicalJSON)
            return "[\(values.joined(separator: ","))]"
        }

        if let string = value as? String {
            return try quotedJSONString(string)
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            guard number.doubleValue.isFinite else {
                throw ModelCallCacheError.unsupportedJSONValue("non-finite number")
            }
            return try canonicalJSONNumber(number)
        }

        throw ModelCallCacheError.unsupportedJSONValue(String(describing: type(of: value)))
    }

    private static func quotedJSONString(_ string: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes])
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.first == "[",
              encoded.last == "]" else {
            throw ModelCallCacheError.invalidJSONBody
        }
        return String(encoded.dropFirst().dropLast())
    }

    private static func canonicalJSONNumber(_ number: NSNumber) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [number], options: [])
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.first == "[",
              encoded.last == "]" else {
            throw ModelCallCacheError.invalidJSONBody
        }
        let rendered = String(encoded.dropFirst().dropLast())
        return rendered == "-0" ? "0" : rendered
    }
}

public actor ModelCallCache {
    private struct Entry: Sendable {
        let payload: Data
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    public func lookup<Payload: Decodable & Sendable>(
        _ request: ModelCallRequest,
        as type: Payload.Type = Payload.self,
        now: Date = Date()
    ) throws -> Payload? {
        guard let entry = entries[request.canonicalRequestHash] else { return nil }
        guard now < entry.expiresAt else {
            entries.removeValue(forKey: request.canonicalRequestHash)
            return nil
        }
        return try JSONDecoder().decode(Payload.self, from: entry.payload)
    }

    public func store<Payload: Encodable & Sendable>(
        _ payload: Payload,
        for request: ModelCallRequest,
        now: Date = Date()
    ) throws {
        let data = try JSONEncoder().encode(payload)
        entries[request.canonicalRequestHash] = Entry(
            payload: data,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    public func value<Payload: Codable & Sendable>(
        for request: ModelCallRequest,
        as type: Payload.Type = Payload.self,
        now: Date = Date(),
        load: @Sendable @escaping () async throws -> Payload
    ) async throws -> Payload {
        if let cached: Payload = try lookup(request, as: Payload.self, now: now) {
            return cached
        }

        let hash = request.canonicalRequestHash
        let task: Task<Data, Error>
        if let existing = inFlight[hash] {
            task = existing
        } else {
            let newTask = Task<Data, Error> {
                let payload = try await load()
                return try JSONEncoder().encode(payload)
            }
            inFlight[hash] = newTask
            task = newTask
        }

        do {
            let data = try await task.value
            let completedAt = Date()
            entries[hash] = Entry(payload: data, expiresAt: completedAt.addingTimeInterval(ttl))
            inFlight[hash] = nil
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            inFlight[hash] = nil
            throw error
        }
    }

    public func removeAll() {
        entries.removeAll()
        inFlight.removeAll()
    }
}

public enum CachedMessageCompleterError: Error, Equatable, Sendable {
    case invalidResponse
}

public struct CachedMessageCompleter: Sendable {
    private struct CachedCompletion: Codable, Sendable {
        let text: String
    }

    private let client: any MessageCompleting
    private let cache: ModelCallCache

    public init(client: any MessageCompleting, cache: ModelCallCache) {
        self.client = client
        self.cache = cache
    }

    public func complete(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions,
        validating validate: @Sendable @escaping (String) throws -> Void = { _ in }
    ) async throws -> String {
        let body = try AnthropicClient.completionBodyData(
            system: system,
            user: user,
            model: model,
            maxTokens: maxTokens,
            options: options
        )
        let request = try options.cacheRequest(model: model, maxTokens: maxTokens, body: body)
        let payload = try await cache.value(for: request, as: CachedCompletion.self) {
            let text = try await client.complete(
                system: system,
                user: user,
                model: model,
                maxTokens: maxTokens,
                options: options
            )
            try validate(text)
            return CachedCompletion(text: text)
        }
        return payload.text
    }
}
