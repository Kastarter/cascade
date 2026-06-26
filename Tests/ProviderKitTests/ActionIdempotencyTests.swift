import Foundation
import ProviderKit
import Testing

struct ActionIdempotencyTests {
    @Test func dictionaryKeyOrderDoesNotChangeActionKey() throws {
        let first = try makeKey(payload: [
            "b": 2,
            "a": ["d": 4, "c": 3],
            "list": [["z": 1, "y": 2]]
        ])
        let second = try makeKey(payload: [
            "list": [["y": 2, "z": 1]],
            "a": ["c": 3, "d": 4],
            "b": 2
        ])

        #expect(first.canonicalPayload == second.canonicalPayload)
        #expect(first.rawValue == second.rawValue)
    }

    @Test func excludedPrivateTypedTextDoesNotAffectOrLeakKey() throws {
        let first = try makeKey(payload: [
            "action": "type",
            "text": "employee ssn 111-22-3333",
            "target": "notes field"
        ])
        let second = try makeKey(payload: [
            "target": "notes field",
            "text": "different private text",
            "action": "type"
        ])

        #expect(first.rawValue == second.rawValue)
        #expect(first.canonicalPayload.contains("excluded"))
        #expect(!first.canonicalPayload.contains("111-22-3333"))
        #expect(!first.canonicalPayload.contains("different private text"))
    }

    @Test func hashedPrivateTypedTextDoesNotLeakButChangesKey() throws {
        let first = try makeKey(
            payload: ["action": "type", "text": "private payroll note"],
            privateTextPolicy: .hash
        )
        let same = try makeKey(
            payload: ["text": "private payroll note", "action": "type"],
            privateTextPolicy: .hash
        )
        let changed = try makeKey(
            payload: ["action": "type", "text": "other private note"],
            privateTextPolicy: .hash
        )

        #expect(first.rawValue == same.rawValue)
        #expect(first.rawValue != changed.rawValue)
        #expect(first.canonicalPayload.contains("__privateTextSHA256"))
        #expect(!first.canonicalPayload.contains("private payroll note"))
    }

    @Test func modelPromptAndSchemaChangesAlterKey() throws {
        let base = try makeKey()

        #expect(try makeKey(model: "claude-opus-4-8").rawValue != base.rawValue)
        #expect(try makeKey(prompt: "planner prompt v2").rawValue != base.rawValue)
        #expect(try makeKey(schema: #"{"type":"array"}"#).rawValue != base.rawValue)
    }

    @Test func largeAdjacentIntegerPayloadsDoNotCollide() throws {
        let first = try makeKey(payload: ["sequence": Int64(9_007_199_254_740_992)])
        let second = try makeKey(payload: ["sequence": Int64(9_007_199_254_740_993)])

        #expect(first.canonicalPayload == #"{"sequence":9007199254740992}"#)
        #expect(second.canonicalPayload == #"{"sequence":9007199254740993}"#)
        #expect(first.canonicalPayload != second.canonicalPayload)
        #expect(first.rawValue != second.rawValue)
    }

    @Test func errorClassifierSeparatesTransientAndNonTransientFailures() {
        #expect(RetryErrorClassifier.classify(httpStatusCode: nil) == .transient)
        #expect(RetryErrorClassifier.classify(httpStatusCode: 408) == .transient)
        #expect(RetryErrorClassifier.classify(httpStatusCode: 429) == .transient)
        #expect(RetryErrorClassifier.classify(httpStatusCode: 503) == .transient)
        #expect(RetryErrorClassifier.classify(httpStatusCode: 400) == .nonTransient)
        #expect(RetryErrorClassifier.classify(httpStatusCode: 404) == .nonTransient)
        #expect(RetryErrorClassifier.classify(urlErrorCode: .networkConnectionLost) == .transient)
        #expect(RetryErrorClassifier.classify(urlErrorCode: .badURL) == .nonTransient)
    }

    @Test func transientRetryClassesScheduleBoundedRetries() {
        let policy = RetryBackoffPolicy(maxRetries: 2, baseDelay: 0.5, maxDelay: 0.75)

        #expect(policy.delay(afterRetryCount: 0, retryClass: .pureModelCall, classification: .transient) == 0.5)
        #expect(policy.delay(afterRetryCount: 1, retryClass: .groundingLookup, classification: .transient) == 0.75)
        #expect(policy.delay(afterRetryCount: 1, retryClass: .readOnlyTool, classification: .transient) == 0.75)
        #expect(policy.delay(afterRetryCount: 2, retryClass: .pureModelCall, classification: .transient) == nil)
        #expect(policy.delay(afterRetryCount: 0, retryClass: .pureModelCall, classification: .nonTransient) == nil)
    }

    @Test func nonIdempotentActionsRefuseAutomaticRetry() throws {
        let key = try makeKey(retryClass: .nonIdempotentAction)
        let policy = RetryBackoffPolicy(maxRetries: 3, baseDelay: 0.1, maxDelay: 1, jitterFraction: 0.2, jitterSeed: 7)

        #expect(!key.retryClass.allowsAutomaticRetry)
        #expect(policy.delay(afterRetryCount: 0, retryClass: key.retryClass, classification: .transient, key: key) == nil)
    }

    @Test func seededJitterIsDeterministic() throws {
        let key = try makeKey()
        let first = RetryBackoffPolicy(maxRetries: 3, baseDelay: 1, maxDelay: 10, jitterFraction: 0.25, jitterSeed: 42)
        let second = RetryBackoffPolicy(maxRetries: 3, baseDelay: 1, maxDelay: 10, jitterFraction: 0.25, jitterSeed: 42)
        let differentSeed = RetryBackoffPolicy(maxRetries: 3, baseDelay: 1, maxDelay: 10, jitterFraction: 0.25, jitterSeed: 43)

        let firstDelay = first.delay(afterRetryCount: 1, retryClass: .readOnlyTool, classification: .transient, key: key)
        let secondDelay = second.delay(afterRetryCount: 1, retryClass: .readOnlyTool, classification: .transient, key: key)
        let differentSeedDelay = differentSeed.delay(afterRetryCount: 1, retryClass: .readOnlyTool, classification: .transient, key: key)

        #expect(firstDelay == secondDelay)
        #expect(firstDelay != differentSeedDelay)
        #expect(firstDelay! <= 10)
    }
}

private func makeKey(
    retryClass: ActionRetryClass = .pureModelCall,
    operation: String = "ClaudeSingleStepPlanner.plan",
    model: String = "claude-sonnet-4-6",
    prompt: String = "planner prompt v1",
    schema: String = #"{"type":"object"}"#,
    payload: Any = ["messages": [["role": "user", "content": "Plan this"]]],
    privateTextPolicy: ActionIdempotencyKey.PrivateTextPolicy = .exclude
) throws -> ActionIdempotencyKey {
    try ActionIdempotencyKey(
        retryClass: retryClass,
        operation: operation,
        model: model,
        prompt: prompt,
        schema: schema,
        payload: payload,
        privateTextPolicy: privateTextPolicy
    )
}
