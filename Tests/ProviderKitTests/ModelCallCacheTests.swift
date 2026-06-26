import Foundation
import ProviderKit
import Testing

struct ModelCallCacheTests {
    @Test func dictionaryKeyOrderDoesNotChangeHash() throws {
        let first = try makeRequest(body: #"{"b":2,"a":{"d":4,"c":3},"list":[{"z":1,"y":2}]}"#)
        let second = try makeRequest(body: #"{"list":[{"y":2,"z":1}],"a":{"c":3,"d":4},"b":2}"#)

        #expect(first.canonicalBody == second.canonicalBody)
        #expect(first.canonicalRequestHash == second.canonicalRequestHash)
    }

    @Test func requestIdentityFieldsChangeHash() throws {
        let base = try makeRequest()

        #expect(try makeRequest(model: "claude-opus-4-8").canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(apiVersion: "2025-11-24").canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(betaVersion: "computer-use-2025-11-24").canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(temperature: 0.2).canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(maxTokens: 512).canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(promptVersion: "planner-v2").canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(schemaVersion: "schema-v2").canonicalRequestHash != base.canonicalRequestHash)
        #expect(try makeRequest(callsite: "ElementLocator.locate").canonicalRequestHash != base.canonicalRequestHash)
    }

    @Test func concurrentIdenticalRequestsShareOneCompletion() async throws {
        let cache = ModelCallCache(ttl: 60)
        let request = try makeRequest()
        let completer = FakeCompleter()

        async let first = cache.value(for: request, as: CachedPayload.self) {
            try await completer.complete()
        }
        async let second = cache.value(for: request, as: CachedPayload.self) {
            try await completer.complete()
        }
        async let third = cache.value(for: request, as: CachedPayload.self) {
            try await completer.complete()
        }

        let results = try await [first, second, third]

        #expect(results == [
            CachedPayload(text: "validated"),
            CachedPayload(text: "validated"),
            CachedPayload(text: "validated")
        ])
        #expect(await completer.count == 1)
    }

    @Test func expiredEntriesMiss() async throws {
        let cache = ModelCallCache(ttl: 1)
        let request = try makeRequest()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await cache.store(CachedPayload(text: "fresh"), for: request, now: start)

        #expect(try await cache.lookup(request, as: CachedPayload.self, now: start.addingTimeInterval(0.5)) == CachedPayload(text: "fresh"))
        #expect(try await cache.lookup(request, as: CachedPayload.self, now: start.addingTimeInterval(1.5)) == nil)
    }
}

private struct CachedPayload: Codable, Equatable, Sendable {
    let text: String
}

private actor FakeCompleter {
    private(set) var count = 0

    func complete() async throws -> CachedPayload {
        count += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return CachedPayload(text: "validated")
    }
}

private func makeRequest(
    model: String = "claude-sonnet-4-6",
    apiVersion: String = "2023-06-01",
    betaVersion: String? = nil,
    temperature: Double? = 0,
    maxTokens: Int = 256,
    promptVersion: String = "planner-v1",
    schemaVersion: String = "schema-v1",
    callsite: String = "ClaudeSingleStepPlanner.plan",
    body: String = #"{"messages":[{"role":"user","content":"Plan this"}],"system":"You are concise"}"#
) throws -> ModelCallRequest {
    try ModelCallRequest(
        model: model,
        apiVersion: apiVersion,
        betaVersion: betaVersion,
        temperature: temperature,
        maxTokens: maxTokens,
        promptVersion: promptVersion,
        schemaVersion: schemaVersion,
        callsite: callsite,
        body: Data(body.utf8)
    )
}
