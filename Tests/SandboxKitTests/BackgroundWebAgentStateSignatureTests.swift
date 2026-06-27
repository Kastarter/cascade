import Testing

@testable import SandboxKit

struct BackgroundWebAgentStateSignatureTests {
    @Test func mutableDomStateChangesHashWhenVisibleTextIsUnchanged() {
        let baseHash = BackgroundWebAgent.pageStateSignatureHash(snapshot: Self.baseSnapshot)

        let changedSnapshots: [[String: Any]] = [
            Self.snapshot(updating: [
                "formValues": [
                    ["path": "#query", "name": "query", "type": "text", "value": "second value"]
                ]
            ]),
            Self.snapshot(updating: [
                "checkedSelected": [
                    ["path": "#notify", "checked": false]
                ]
            ]),
            Self.snapshot(updating: [
                "activeElement": [
                    "tagName": "button",
                    "id": "submit",
                    "role": "button",
                    "label": "Submit",
                    "path": "#submit"
                ]
            ]),
            Self.snapshot(updating: [
                "interactives": [
                    ["tagName": "input", "id": "query", "name": "query", "type": "text", "label": "Query", "path": "#query"],
                    ["tagName": "button", "id": "submit", "role": "button", "label": "Submit", "path": "#submit"],
                    ["tagName": "a", "id": "next", "role": "link", "label": "Next", "path": "#next"]
                ]
            ])
        ]

        for snapshot in changedSnapshots {
            #expect(snapshot["visibleText"] as? String == Self.visibleText)
            #expect(BackgroundWebAgent.pageStateSignatureHash(snapshot: snapshot) != baseHash)
        }
    }

    @Test func noEffectSignatureStringDoesNotEmbedRawPageText() {
        let rawText = String(repeating: "private raw page text ", count: 300)
        let signature = BackgroundWebAgent.pageStateSignatureHash(snapshot: Self.snapshot(updating: [
            "visibleText": rawText,
            "bodyText": rawText,
            "innerText": rawText
        ]))

        #expect(signature.hasPrefix("fnv64:"))
        #expect(signature.count < 80)
        #expect(!signature.contains("private raw page text"))
        #expect(!signature.contains(rawText))
    }

    private static let visibleText = "Status unchanged"

    private static var baseSnapshot: [String: Any] {
        [
            "url": "https://sandbox.example.test/form",
            "title": "Sandbox form",
            "visibleText": visibleText,
            "activeElement": [
                "tagName": "input",
                "id": "query",
                "name": "query",
                "type": "text",
                "role": "textbox",
                "label": "Query",
                "path": "#query"
            ],
            "scroll": ["x": 0, "y": 0],
            "interactives": [
                ["tagName": "input", "id": "query", "name": "query", "type": "text", "label": "Query", "path": "#query"],
                ["tagName": "button", "id": "submit", "role": "button", "label": "Submit", "path": "#submit"]
            ],
            "formValues": [
                ["path": "#query", "name": "query", "type": "text", "value": "first value"]
            ],
            "checkedSelected": [
                ["path": "#notify", "checked": true]
            ],
            "contentEditableText": [],
            "ariaText": [],
            "mutationSequence": 1
        ]
    }

    private static func snapshot(updating updates: [String: Any]) -> [String: Any] {
        var snapshot = baseSnapshot
        for (key, value) in updates {
            snapshot[key] = value
        }
        return snapshot
    }
}
