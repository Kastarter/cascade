import CascadeMemory
import Foundation
import Security

public struct ProviderMessage: Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol ContextQuestionAnswering: Sendable {
    func answer(question: String, contexts: [RecordedContext]) async throws -> String
}

public struct LocalGroundedAnswerer: ContextQuestionAnswering {
    public init() {}

    public func answer(question: String, contexts: [RecordedContext]) async throws -> String {
        let latest = contexts.sorted { $0.capturedAt > $1.capturedAt }.prefix(6)
        guard let first = latest.first else {
            return "I do not have enough recorded context yet."
        }

        let apps = Array(Set(latest.map(\.appName))).sorted().joined(separator: ", ")
        let window = first.windowTitle.map { " The latest window was “\($0)”." } ?? ""
        return "From the local record, you were mostly in \(apps).\(window) This answer is grounded only in the stored context samples."
    }
}

public enum ProviderKeyStoreError: Error, LocalizedError {
    case emptyKey
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            "Paste a non-empty API key."
        case .unexpectedStatus(let status):
            "Keychain returned status \(status)."
        }
    }
}

public struct AnthropicKeyStore: Sendable {
    private let service = "com.humain.cascade"
    private let account = "anthropic-api-key"

    public init() {}

    public func hasKey() -> Bool {
        readKey() != nil
    }

    public func readKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderKeyStoreError.emptyKey }
        try delete(allowMissing: true)

        var item = baseQuery()
        item[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderKeyStoreError.unexpectedStatus(status)
        }
    }

    public func delete() throws {
        try delete(allowMissing: true)
    }

    private func delete(allowMissing: Bool) throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound && allowMissing { return }
        guard status == errSecSuccess else {
            throw ProviderKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Keychain-backed store for the user's OpenAI API key (used by the GPT-Realtime voice).
public struct OpenAIKeyStore: Sendable {
    private let service = "com.humain.cascade"
    private let account = "openai-api-key"

    public init() {}

    public func hasKey() -> Bool { readKey() != nil }

    public func readKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderKeyStoreError.emptyKey }
        try? delete()
        var item = baseQuery()
        item[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProviderKeyStoreError.unexpectedStatus(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw ProviderKeyStoreError.unexpectedStatus(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
