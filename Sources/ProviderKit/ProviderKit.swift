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

/// Everything the chat knows when it answers: the whole recorded window plus
/// question-targeted recall, layered so any kind of question about the user's
/// day has grounding — shape ("what did I do?") via `timeline`, content ("what
/// did that page say?") via `samples` and `relevant`, and "what just happened?"
/// via `recent`.
public struct ChatGrounding: Sendable {
    /// Selected Reel moment and its nearby context. When present this is the primary
    /// evidence for "this/current/on screen" wording from the scrubbed playhead.
    public let focused: [RecordedContext]
    /// The whole window, lightweight rows (no OCR) — drives the session digest.
    public let timeline: [RecordedContext]
    /// Representative on-screen text excerpts sampled across the window.
    public let samples: [RecordedContext]
    /// Moments whose recorded text matches the question's terms, best first.
    public let relevant: [RecordedContext]
    /// The freshest fully-decoded moments, OCR included.
    public let recent: [RecordedContext]

    public init(
        focused: [RecordedContext] = [],
        timeline: [RecordedContext] = [],
        samples: [RecordedContext] = [],
        relevant: [RecordedContext] = [],
        recent: [RecordedContext] = []
    ) {
        self.focused = focused
        self.timeline = timeline
        self.samples = samples
        self.relevant = relevant
        self.recent = recent
    }

    /// All moments deduped by id, preferring the OCR-rich copy of a row that
    /// appears in several layers. Rows with id 0 (unsaved) are kept as-is.
    public var allMoments: [RecordedContext] {
        var seen = Set<Int64>()
        var result: [RecordedContext] = []
        for context in focused + recent + relevant + samples + timeline {
            if context.id != 0 {
                guard seen.insert(context.id).inserted else { continue }
            }
            result.append(context)
        }
        return result
    }
}

public protocol ContextQuestionAnswering: Sendable {
    func answer(question: String, grounding: ChatGrounding) async throws -> String
}

public struct LocalGroundedAnswerer: ContextQuestionAnswering {
    public init() {}

    public func answer(question: String, grounding: ChatGrounding) async throws -> String {
        if RecordSearchAnswerer.isInstructionalQuestion(question) {
            return "Step-by-step help for that requires a connected model. Connect Claude in Settings and ask again."
        }

        let sorted = grounding.allMoments.sorted { $0.capturedAt > $1.capturedAt }
        guard let newest = sorted.first else {
            return "I do not have enough recorded context yet."
        }

        var counts: [String: Int] = [:]
        for context in sorted {
            counts[context.appName, default: 0] += 1
        }
        let apps = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4)
            .map(\.key)
            .joined(separator: ", ")
        let window = newest.windowTitle.map { " The latest window was “\($0)”." } ?? ""
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

/// Keychain-backed store for the user's OpenRouter API key. OpenRouter hosts the
/// UI-TARS grounding model over an OpenAI-compatible endpoint, so the on-screen
/// agent's grounder (`UITARSGrounder`) authenticates with this key — end users
/// never run a 7B model locally. See [[cascade-cu-downgrade-research]].
public struct OpenRouterKeyStore: Sendable {
    private let service = "com.humain.cascade"
    private let account = "openrouter-api-key"

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
