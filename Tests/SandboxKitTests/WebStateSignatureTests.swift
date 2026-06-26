import Testing

@testable import SandboxKit

struct WebStateSignatureTests {
    @Test func staticFixtureDictionariesProduceStableSignatures() {
        let first = WebStateSignature(snapshot: Self.baseFixture)
        let second = WebStateSignature(snapshot: Self.baseFixture)

        #expect(first == second)
        #expect(first.stableHash == second.stableHash)
        #expect(first.stableHash.hasPrefix("fnv64:"))
        #expect(first.url == "https://hr.example.test/review")
        #expect(first.title == "Manager review")
    }

    @Test func formValueMutationChangesOnlyFormValuesHash() {
        let base = WebStateSignature(snapshot: Self.baseFixture)
        let changed = WebStateSignature(snapshot: Self.fixture(updating: [
            "formValues": [
                ["path": "#employee", "name": "employee", "type": "text", "value": "Asha"],
                ["path": "#password", "name": "password", "type": "password", "value": "new-secret"]
            ]
        ]))

        #expect(changed.formValuesHash != base.formValuesHash)
        #expect(changed.interactivesHash == base.interactivesHash)
        #expect(changed.checkedSelectedHash == base.checkedSelectedHash)
        #expect(changed.contentEditableTextHash == base.contentEditableTextHash)
        #expect(changed.ariaTextHash == base.ariaTextHash)
        #expect(changed.activeElement == base.activeElement)
        #expect(changed.scroll == base.scroll)
    }

    @Test func checkboxMutationChangesOnlyCheckedSelectedHash() {
        let base = WebStateSignature(snapshot: Self.baseFixture)
        let changed = WebStateSignature(snapshot: Self.fixture(updating: [
            "checkedSelected": [
                ["path": "#notify", "checked": false],
                ["path": "#priority", "selectedIndex": 1, "selected": [["index": 1, "valueHash": "fnv64:bbbbbbbbbbbbbbbb"]]]
            ]
        ]))

        #expect(changed.checkedSelectedHash != base.checkedSelectedHash)
        #expect(changed.formValuesHash == base.formValuesHash)
        #expect(changed.interactivesHash == base.interactivesHash)
        #expect(changed.contentEditableTextHash == base.contentEditableTextHash)
        #expect(changed.ariaTextHash == base.ariaTextHash)
    }

    @Test func focusMutationChangesOnlyActiveElementAndStableHash() {
        let base = WebStateSignature(snapshot: Self.baseFixture)
        let changed = WebStateSignature(snapshot: Self.fixture(updating: [
            "activeElement": [
                "tagName": "button",
                "id": "approve",
                "role": "button",
                "label": "Approve",
                "path": "#approve"
            ]
        ]))

        #expect(changed.activeElement != base.activeElement)
        #expect(changed.stableHash != base.stableHash)
        #expect(changed.formValuesHash == base.formValuesHash)
        #expect(changed.checkedSelectedHash == base.checkedSelectedHash)
        #expect(changed.interactivesHash == base.interactivesHash)
        #expect(changed.scroll == base.scroll)
    }

    @Test func scrollMutationChangesOnlyScrollAndStableHash() {
        let base = WebStateSignature(snapshot: Self.baseFixture)
        let changed = WebStateSignature(snapshot: Self.fixture(updating: [
            "scroll": ["x": 0, "y": 820]
        ]))

        #expect(changed.scroll != base.scroll)
        #expect(changed.stableHash != base.stableHash)
        #expect(changed.activeElement == base.activeElement)
        #expect(changed.formValuesHash == base.formValuesHash)
        #expect(changed.checkedSelectedHash == base.checkedSelectedHash)
        #expect(changed.contentEditableTextHash == base.contentEditableTextHash)
        #expect(changed.ariaTextHash == base.ariaTextHash)
    }

    @Test func textMutationsChangeTheRightTextSubhashes() {
        let base = WebStateSignature(snapshot: Self.baseFixture)
        let contentChanged = WebStateSignature(snapshot: Self.fixture(updating: [
            "contentEditableText": [
                ["path": "#note", "text": "Revised manager rationale with evidence."]
            ]
        ]))
        let ariaChanged = WebStateSignature(snapshot: Self.fixture(updating: [
            "ariaText": [
                ["path": "#risk", "aria": "High priority KPI risk"]
            ]
        ]))

        #expect(contentChanged.contentEditableTextHash != base.contentEditableTextHash)
        #expect(contentChanged.ariaTextHash == base.ariaTextHash)
        #expect(contentChanged.formValuesHash == base.formValuesHash)
        #expect(ariaChanged.ariaTextHash != base.ariaTextHash)
        #expect(ariaChanged.contentEditableTextHash == base.contentEditableTextHash)
        #expect(ariaChanged.formValuesHash == base.formValuesHash)
    }

    @Test func mutationSequenceContributesToStableHashWithoutMovingSubhashes() {
        let base = WebStateSignature(snapshot: Self.baseFixture)
        let changed = WebStateSignature(snapshot: Self.fixture(updating: ["mutationSequence": 43]))

        #expect(changed.mutationSequence == 43)
        #expect(changed.stableHash != base.stableHash)
        #expect(changed.formValuesHash == base.formValuesHash)
        #expect(changed.checkedSelectedHash == base.checkedSelectedHash)
        #expect(changed.contentEditableTextHash == base.contentEditableTextHash)
        #expect(changed.ariaTextHash == base.ariaTextHash)
    }

    @Test func sensitiveFieldValuesAreHashedNotSerialized() {
        let signature = WebStateSignature(snapshot: Self.baseFixture)
        let serialized = String(describing: signature)

        #expect(signature.formValuesHash.hasPrefix("fnv64:"))
        #expect(!signature.formValuesHash.contains("swordfish"))
        #expect(!serialized.contains("swordfish"))
        #expect(!serialized.contains("secret-answer"))
    }

    @Test func javascriptSnippetReturnsSignatureShapeAndMutationSequence() {
        let snippet = WebStateSignature.javaScriptSnippet

        #expect(snippet.contains("MutationObserver"))
        #expect(snippet.contains("mutationSequence"))
        #expect(snippet.contains("formValuesHash"))
        #expect(snippet.contains("checkedSelectedHash"))
        #expect(snippet.contains("contentEditableTextHash"))
        #expect(snippet.contains("ariaTextHash"))
        #expect(!snippet.contains("password.value"))
    }

    private static var baseFixture: [String: Any] {
        [
            "url": "https://hr.example.test/review",
            "title": "Manager review",
            "activeElement": [
                "tagName": "input",
                "id": "employee",
                "name": "employee",
                "type": "text",
                "role": "textbox",
                "label": "Employee",
                "path": "#employee"
            ],
            "scroll": ["x": 0, "y": 120],
            "interactives": [
                ["tagName": "input", "id": "employee", "name": "employee", "type": "text", "role": "textbox", "label": "Employee", "path": "#employee"],
                ["tagName": "input", "id": "password", "name": "password", "type": "password", "label": "Password", "path": "#password"],
                ["tagName": "button", "id": "approve", "role": "button", "label": "Approve", "path": "#approve"]
            ],
            "formValues": [
                ["path": "#employee", "name": "employee", "type": "text", "value": "Asha"],
                ["path": "#password", "name": "password", "type": "password", "value": "swordfish"],
                ["path": "#secret", "name": "secret", "type": "text", "value": "secret-answer"]
            ],
            "checkedSelected": [
                ["path": "#notify", "checked": true],
                ["path": "#priority", "selectedIndex": 2, "selected": [["index": 2, "valueHash": "fnv64:aaaaaaaaaaaaaaaa"]]]
            ],
            "contentEditableText": [
                ["path": "#note", "text": "Manager rationale with evidence."]
            ],
            "ariaText": [
                ["path": "#risk", "aria": "KPI risk"]
            ],
            "mutationSequence": 42
        ]
    }

    private static func fixture(updating updates: [String: Any]) -> [String: Any] {
        var fixture = baseFixture
        for (key, value) in updates {
            fixture[key] = value
        }
        return fixture
    }
}
