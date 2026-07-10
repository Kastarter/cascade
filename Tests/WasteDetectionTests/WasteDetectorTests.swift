import CascadeMemory
import Foundation
@testable import WasteDetection
import Testing

private let base = Date(timeIntervalSince1970: 1_700_000_000)

func normalizedSignatureTokensForTest(_ signature: String) -> [String] {
    let payload: String
    if signature.hasPrefix("routine:v2:") {
        payload = signature
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first
            .map(String.init) ?? ""
    } else {
        payload = signature
    }
    let parts = payload.components(separatedBy: "|")
    guard parts.contains("v1") else {
        return parts.map { $0.lowercased() }
    }

    var actionTokens: [[String]] = []
    var current: [String] = []
    for part in parts {
        if part == "v1", !current.isEmpty {
            actionTokens.append(current)
            current = [part]
        } else {
            current.append(part)
        }
    }
    if !current.isEmpty {
        actionTokens.append(current)
    }

    return actionTokens.map { fields in
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            let split = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard split.count == 2 else { continue }
            values[String(split[0])] = String(split[1])
        }
        let kind = values["kind"] ?? ""
        let surface = values["surface"] ?? ""
        switch kind {
        case "key":
            let modifiers = values["modifiers"]?.isEmpty == false ? "\(values["modifiers"]!)+" : ""
            return "key:\(modifiers)\(values["key"] ?? "")@\(surface)"
        case "click", "doubleclick", "rightclick":
            let label = values["label"] ?? ""
            return label.isEmpty ? "\(kind)@\(surface)" : "\(kind):\(label)@\(surface)"
        case "type":
            return "type@\(surface)"
        default:
            return "\(kind)@\(surface)"
        }
    }
}

private func event(_ i: Int, _ kind: InputEventKind, app: String, key: String? = nil, modifiers: [String] = []) -> InputEvent {
    InputEvent(
        id: Int64(i),
        capturedAt: base.addingTimeInterval(Double(i)),
        kind: kind,
        x: kind == .click ? 10 : nil,
        y: kind == .click ? 10 : nil,
        key: key,
        modifiers: modifiers,
        appName: app
    )
}

// MARK: - H1 element-identity token

@Test
func tokenEncodesClickedElementIdentity() {
    let reply = InputEvent(kind: .click, text: "Reply All", appName: "Mail")
    let archive = InputEvent(kind: .click, text: "Archive", appName: "Mail")
    let unlabeled = InputEvent(kind: .click, appName: "Mail")
    // Distinct buttons → distinct tokens (the detector can now tell routines apart).
    #expect(WasteDetector.token(reply, surface: "Mail") != WasteDetector.token(archive, surface: "Mail"))
    // Casing/whitespace don't fork the token.
    let replyMessy = InputEvent(kind: .click, text: "  reply   all ", appName: "Mail")
    #expect(WasteDetector.token(reply, surface: "Mail") == WasteDetector.token(replyMessy, surface: "Mail"))
    // An unlabeled click degrades to the old coarse token (no regression).
    #expect(normalizedSignatureTokensForTest(WasteDetector.token(unlabeled, surface: "Mail")) == ["click@mail"])
}

@Test
func distinctButtonSequencesAreDistinctWorkflows() {
    // Two repeated single-app routines that differ ONLY by which buttons are clicked —
    // before H1 both tokenized to "click@App,click@App" and false-merged; now distinct.
    func runs(_ a: String, _ b: String, app: String, start: Int) -> [InputEvent] {
        var out: [InputEvent] = []; var i = start
        for _ in 0..<3 {
            out.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, text: a, appName: app)); i += 1
            out.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: app)); i += 1
            out.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 2, y: 2, text: b, appName: app)); i += 1
        }
        return out
    }
    let events = runs("Open Invoice", "Mark Paid", app: "Books", start: 0)
    let sig = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first?.signature ?? ""
    #expect(sig.contains("open invoice"))
    #expect(sig.contains("mark paid"))
}

// MARK: - H3 infrequent-token noise filter

@Test
func noiseFilterDropsOneOffsButKeepsRepeatedSteps() {
    let surface: (InputEvent) -> String = { $0.appName }
    // "Open" + ⌘C each appear 3×; "Junk-N" clicks each appear once.
    var events: [InputEvent] = []
    var i = 0
    for run in 0..<3 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, text: "Open", appName: "Books")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, text: "Junk-\(run)", appName: "Books")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Books")); i += 1
    }
    let kept = WasteDetector.keepingRepeatableTokens(events, surface: surface, minSupport: 2)
    // The one-off junk clicks are gone; every repeated step survives.
    #expect(!kept.contains { ($0.text ?? "").hasPrefix("Junk") })
    #expect(kept.count(where: { $0.text == "Open" }) == 3)
    #expect(kept.count(where: { $0.kind == .key }) == 3)
}

@Test
func interruptedRoutineIsRescuedByNoiseFilter() {
    // A routine [click "Open", ⌘C] done 3×, but each run is interrupted by a UNIQUE
    // stray click in the middle — so no contiguous [open, ⌘C] window ever exists.
    // After the noise filter removes the one-off strays it closes up and is detected.
    var events: [InputEvent] = []
    var i = 0
    for run in 0..<3 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, text: "Open", appName: "Books")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 9, y: 9, text: "Stray-\(run)", appName: "Books")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Books")); i += 1
    }
    let results = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false)
    let waste = try? #require(results.first)
    if let waste {
        #expect(waste.occurrences == 3)
        #expect(normalizedSignatureTokensForTest(waste.signature) == ["click:open@books", "key:command+c@books"])
        #expect(!waste.recipe.steps.contains { ($0.ocrAnchor ?? "").hasPrefix("Stray") })
    }
}

// MARK: - H4 idle-gap session boundary

@Test
func isWithinOneSessionRejectsBigInternalGaps() {
    // 1s-apart steps = one session; a 5-min internal gap = a boundary.
    let tight = (0..<3).map { event($0, .click, app: "A") }
    #expect(WasteDetector.isWithinOneSession(tight, start: 0, length: 3))
    let split = [
        InputEvent(id: 0, capturedAt: base, kind: .click, appName: "A"),
        InputEvent(id: 1, capturedAt: base.addingTimeInterval(300), kind: .click, appName: "A"),
    ]
    #expect(!WasteDetector.isWithinOneSession(split, start: 0, length: 2))
}

@Test
func patternStraddlingAnIdleGapIsNotCounted() {
    // [click "Open", ⌘C] three times seconds apart, then a fourth pair whose two events
    // are 5 minutes apart — that window straddles a session boundary and must not count.
    func pair(_ i: Int, clickAt: TimeInterval, keyAt: TimeInterval) -> [InputEvent] {
        [InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(clickAt), kind: .click, x: 1, y: 1, text: "Open", appName: "Books"),
         InputEvent(id: Int64(i + 1), capturedAt: base.addingTimeInterval(keyAt), kind: .key, key: "c", modifiers: ["command"], appName: "Books")]
    }
    var events = pair(0, clickAt: 0, keyAt: 1) + pair(2, clickAt: 2, keyAt: 3) + pair(4, clickAt: 4, keyAt: 5)
    events += pair(6, clickAt: 400, keyAt: 700) // 300s internal gap → rejected
    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first
    #expect(waste?.occurrences == 3) // the gap-straddling 4th pair is not counted
}

// MARK: - H5 variant merging

@Test
func sequenceSimilarityScoresEditDistance() {
    #expect(WasteDetector.sequenceSimilarity(["a", "b", "c"], ["a", "b", "c"]) == 1)
    #expect(abs(WasteDetector.sequenceSimilarity(["a", "b", "c"], ["a", "x", "c"]) - 2.0 / 3.0) < 1e-9) // one substitution
    #expect(WasteDetector.sequenceSimilarity(["a", "b"], ["x", "y"]) == 0)
    #expect(WasteDetector.levenshtein(["a", "b", "c"], ["a", "c"]) == 1) // one deletion
}

@Test
func mergeVariantsCollapsesNearDuplicatesAndSumsOccurrences() {
    // Two variants of one routine differing by a single step (4-token sigs, 1 diff →
    // 0.75 sim... use 5-token so one diff = 0.8 ≥ threshold) merge; occurrences sum.
    let a = rankWaste(occ: 2, steps: [], sig: "click:open@A|key:command+c@A|click:row@A|key:command+v@B|key:command+s@B")
    let b = rankWaste(occ: 2, steps: [], sig: "click:open@A|key:command+c@A|click:cell@A|key:command+v@B|key:command+s@B")
    let merged = WasteDetector.mergeVariants([a, b])
    #expect(merged.count == 1)
    #expect(merged[0].occurrences == 4) // 2 + 2 — now clears the ≥3 bar
}

@Test
func mergeVariantsKeepsGenuinelyDifferentRoutinesApart() {
    let mail = rankWaste(occ: 3, steps: [], sig: "click:reply@Mail|key:command+v@Mail")
    let sheet = rankWaste(occ: 3, steps: [], sig: "click:cell@Numbers|type@Numbers|key:command+s@Numbers")
    let merged = WasteDetector.mergeVariants([mail, sheet])
    #expect(merged.count == 2) // dissimilar → not merged
}

@Test
func preThresholdVariantAggregationLetsSplitSupportClearRepetitionBar() {
    var events: [InputEvent] = []
    var i = 0
    func appendRun(run: Int, thirdClick: String) {
        let start = TimeInterval(run * 300)
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start), kind: .click, x: 1, y: 1, text: "Open", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 1), kind: .key, key: "c", modifiers: ["command"], appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 2), kind: .click, x: 2, y: 2, text: thirdClick, appName: "Numbers")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 3), kind: .key, key: "v", modifiers: ["command"], appName: "Numbers")); i += 1
    }
    appendRun(run: 0, thirdClick: "Row")
    appendRun(run: 1, thirdClick: "Row")
    appendRun(run: 2, thirdClick: "Cell")

    let waste = try? #require(WasteDetector().detect(contexts: [], inputEvents: events).first)

    #expect(waste?.occurrences == 3)
    #expect(waste?.evidence.count == Set(waste?.evidence ?? []).count)
}

// MARK: - H6 noisy-app exclusion

@Test
func noisyMeetingAppsAreExcludedFromDetection() {
    #expect(WasteDetector.isNoisyApp(appName: "zoom.us", bundleIdentifier: "us.zoom.xos"))
    #expect(WasteDetector.isNoisyApp(appName: "Microsoft Teams", bundleIdentifier: nil))
    #expect(!WasteDetector.isNoisyApp(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")) // chat ≠ excluded
    #expect(!WasteDetector.isNoisyApp(appName: "Mail", bundleIdentifier: "com.apple.mail"))
    // A repeated action sequence inside a meeting app produces no workflow.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<3 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, text: "Mute", appName: "zoom.us", bundleIdentifier: "us.zoom.xos")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "a", modifiers: ["command"], appName: "zoom.us", bundleIdentifier: "us.zoom.xos")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

// MARK: - H2 composite ranking

private func rankWaste(occ: Int = 3, perRun: Int = 30, steps: [RecipeStep], lastSeen: Date = base, sig: String = "s") -> DetectedWaste {
    DetectedWaste(title: "t", apps: ["A"], occurrences: occ, estimatedSecondsPerRun: perRun,
                  estimatedTotalSeconds: occ * perRun, recipe: AgentRecipe(steps: steps),
                  evidence: [], confidence: 0.7, signature: sig, lastSeenAt: lastSeen)
}

@Test
func rankingScoreRewardsFrequencyRecencyAndLength() {
    let now = base.addingTimeInterval(100)
    let clicks = (0..<3).map { RecipeStep(order: $0, kind: .click, appName: "A") }
    let baseW = rankWaste(occ: 3, steps: clicks, lastSeen: now)
    // More occurrences ranks higher (all else equal).
    #expect(WasteDetector.rankingScore(rankWaste(occ: 9, steps: clicks, lastSeen: now), now: now)
          > WasteDetector.rankingScore(baseW, now: now))
    // More recent ranks higher.
    #expect(WasteDetector.rankingScore(baseW, now: now)
          > WasteDetector.rankingScore(rankWaste(occ: 3, steps: clicks, lastSeen: now.addingTimeInterval(-30 * 86_400)), now: now))
    // Longer (more cohesive) ranks higher.
    let longer = (0..<7).map { RecipeStep(order: $0, kind: .click, appName: "A") }
    #expect(WasteDetector.rankingScore(rankWaste(occ: 3, steps: longer, lastSeen: now), now: now)
          > WasteDetector.rankingScore(baseW, now: now))
}

@Test
func crossAppCopyPasteIsDetectedAndBoosted() {
    let transfer = [RecipeStep(order: 0, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
                    RecipeStep(order: 1, kind: .key, key: "v", modifiers: ["command"], appName: "Numbers")]
    let sameApp = [RecipeStep(order: 0, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
                   RecipeStep(order: 1, kind: .key, key: "v", modifiers: ["command"], appName: "Mail")]
    #expect(WasteDetector.hasCrossAppCopyPaste(transfer))
    #expect(!WasteDetector.hasCrossAppCopyPaste(sameApp))
    // The data-transfer routine outranks an otherwise-identical same-app one.
    let now = base.addingTimeInterval(100)
    #expect(WasteDetector.rankingScore(rankWaste(steps: transfer, lastSeen: now), now: now)
          > WasteDetector.rankingScore(rankWaste(steps: sameApp, lastSeen: now), now: now))
}

@Test
func routineQualityRewardsCompactDeterministicRoutines() {
    func makeEvents(startID: Int, gap: TimeInterval, label: String) -> [InputEvent] {
        var output: [InputEvent] = []
        var id = startID
        for run in 0..<3 {
            let start = Double(run) * 400
            output.append(InputEvent(id: Int64(id), capturedAt: base.addingTimeInterval(start), kind: .click, x: 1, y: 1, text: label, appName: "Mail")); id += 1
            output.append(InputEvent(id: Int64(id), capturedAt: base.addingTimeInterval(start + gap), kind: .key, key: "c", modifiers: ["command"], appName: "Mail")); id += 1
        }
        return output
    }
    let compact = WasteDetector().detect(contexts: [], inputEvents: makeEvents(startID: 0, gap: 2, label: "Inbox"), useEpisodeMining: false).first
    let loose = WasteDetector().detect(contexts: [], inputEvents: makeEvents(startID: 20, gap: 100, label: "Archive"), useEpisodeMining: false).first

    #expect((compact?.quality?.score ?? 0) > (loose?.quality?.score ?? 0))
    #expect((compact?.quality?.compactnessScore ?? 0) > (loose?.quality?.compactnessScore ?? 0))
}

@Test
func routineQualityPenalizesFreeTextParametersBeforeCuration() {
    func makeParameterized(values: [String], label: String) -> DetectedWaste {
        var events: [InputEvent] = []
        var i = 0
        for value in values {
            events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, text: label, appName: "Notes")); i += 1
            events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: value, appName: "Notes")); i += 1
            events.append(event(i, .key, app: "Notes", key: "s", modifiers: ["command"])); i += 1
        }
        return WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    }
    let numeric = makeParameterized(values: ["INV-001", "INV-002", "INV-003"], label: "Invoice number")
    let freeText = makeParameterized(values: ["Please call me later", "Can you review this", "Draft the note"], label: "Message body")

    #expect((numeric.quality?.privacyPenalty ?? 1) < (freeText.quality?.privacyPenalty ?? 0))
    #expect((numeric.quality?.score ?? 0) > (freeText.quality?.score ?? 0))
}

// MARK: - B5 parameter extraction

private func typeEvent(_ i: Int, app: String, text: String) -> InputEvent {
    InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: text, appName: app)
}

@Test
func variableTypePositionsFindsValuesThatChangeAcrossRuns() {
    // Two occurrences of [click, type, key]; only the typed value differs → position 1
    // is a parameter, the click and key are fixed.
    let runA = [event(0, .click, app: "Mail"), typeEvent(1, app: "Mail", text: "INV-001"), event(2, .key, app: "Mail", key: "s", modifiers: ["command"])]
    let runB = [event(0, .click, app: "Mail"), typeEvent(1, app: "Mail", text: "INV-002"), event(2, .key, app: "Mail", key: "s", modifiers: ["command"])]
    #expect(WasteDetector.variableTypePositions([runA, runB]) == [1])
}

@Test
func variableTypePositionsIgnoresConstantTypingAndSingleRuns() {
    let runA = [typeEvent(0, app: "Mail", text: "ls"), event(1, .click, app: "Mail")]
    let runB = [typeEvent(0, app: "Mail", text: "ls"), event(1, .click, app: "Mail")]
    // Same typed value every run → fixed content, not a parameter.
    #expect(WasteDetector.variableTypePositions([runA, runB]).isEmpty)
    // A single demonstration can't reveal what changes.
    #expect(WasteDetector.variableTypePositions([runA]).isEmpty)
    // A position that isn't a `.type` in every run is never a parameter.
    let mixed = [[typeEvent(0, app: "Mail", text: "a")], [event(0, .click, app: "Mail")]]
    #expect(WasteDetector.variableTypePositions(mixed).isEmpty)
}

@Test
func variableTypePositionsAlignsByTargetWhenPositionsVary() {
    let runA = [
        InputEvent(id: 0, capturedAt: base, kind: .click, text: "Invoice number", appName: "Books"),
        typeEvent(1, app: "Books", text: "INV-001"),
        event(2, .key, app: "Books", key: "s", modifiers: ["command"])
    ]
    let runB = [
        InputEvent(id: 3, capturedAt: base.addingTimeInterval(3), kind: .click, text: "Open", appName: "Books"),
        InputEvent(id: 4, capturedAt: base.addingTimeInterval(4), kind: .click, text: "Invoice number", appName: "Books"),
        typeEvent(5, app: "Books", text: "INV-002"),
        event(6, .key, app: "Books", key: "s", modifiers: ["command"])
    ]

    #expect(WasteDetector.variableTypePositions([runA, runB]) == [1])
}

@Test
func detectCarriesTypedParameterMetadata() {
    var events: [InputEvent] = []
    var i = 0
    for value in ["INV-001", "INV-002"] {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, text: "Invoice number", appName: "Books")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: value, appName: "Books")); i += 1
        events.append(event(i, .key, app: "Books", key: "s", modifiers: ["command"])); i += 1
    }

    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    let parameter = waste.recipe.steps.first { $0.kind == .type }

    #expect(parameter?.isParameter == true)
    #expect(parameter?.parameterKey == "invoice_number")
    #expect(parameter?.parameterKind == .number)
    #expect(parameter?.valueExamples.contains { $0.contains("number:") } == true)
    #expect(parameter?.valueHashes.isEmpty == false)
    #expect(parameter?.sourceStepIDs.isEmpty == false)
}

@Test
func detectMarksVaryingTypedValueAsParameter() {
    // A repeated save-with-a-changing-name workflow: the typed value differs each run,
    // so the deployed recipe must flag it (don't blindly retype the stale value).
    var events: [InputEvent] = []
    let values = ["report-q1", "report-q2"]
    var i = 0
    for run in 0..<2 {
        events.append(event(i, .click, app: "TextEdit")); i += 1
        events.append(typeEvent(i, app: "TextEdit", text: values[run])); i += 1
        events.append(event(i, .key, app: "TextEdit", key: "s", modifiers: ["command"])); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    let typeStep = waste.recipe.steps.first { $0.kind == .type }
    #expect(typeStep?.isParameter == true)
    // Fixed steps stay fixed.
    #expect(waste.recipe.steps.filter { $0.kind == .click }.allSatisfy { !$0.isParameter })
    #expect(waste.recipe.steps.filter { $0.kind == .key }.allSatisfy { !$0.isParameter })
}

@Test
func detectsRepeatedCrossAppWorkflow() {
    // Copy from Mail → paste into Numbers, done twice.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(event(i, .click, app: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
        events.append(event(i, .click, app: "Numbers")); i += 1
        events.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    }

    let result = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false)
    #expect(result.count == 1)
    let waste = result.first!
    #expect(waste.occurrences == 2)
    #expect(waste.apps == ["Mail", "Numbers"])
    // activateApp Mail, click, key, activateApp Numbers, click, key
    #expect(waste.recipe.steps.count == 6)
    #expect(waste.recipe.steps.first?.kind == .activateApp)
    #expect(waste.recipe.steps.contains { $0.kind == .key && $0.key == "v" })
}

@Test
func crossAppPasteCarriesDataflowParameterMetadata() {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, text: "Invoice total", appName: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 2, y: 2, text: "A1", appName: "Numbers")); i += 1
        events.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    }

    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    let copy = waste.recipe.steps.first { $0.kind == .key && $0.key == "c" }
    let paste = waste.recipe.steps.first { $0.kind == .key && $0.key == "v" }

    #expect(paste?.isParameter == true)
    #expect(paste?.parameterKey?.hasPrefix("paste:field_") == true)
    #expect(paste?.parameterKey?.contains(":from:field_") == true)
    #expect(paste?.parameterKind == .freeText)
    #expect(paste?.valueExamples == ["freeText:clipboard"])
    #expect(paste?.valueHashes.isEmpty == true)
    #expect(paste?.dataflowEdgeID?.isEmpty == false)
    #expect(copy.map { paste?.sourceStepIDs.contains($0.order) == true } == true)
}

@Test
func nonRepeatingActivityDetectsNothing() {
    let events = (0..<6).map { event($0, .click, app: "App\($0)") }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

@Test
func scrollSpamIsNeverAWorkflow() {
    // Hours of reading in iTerm2 — hundreds of wheel ticks, no real actions.
    // This was surfacing as "Repeated steps in iTerm2 · scroll · scroll · …".
    let events = (0..<60).map { event($0, .scroll, app: "iTerm2") }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

@Test
func scrollThenOneActionIsStillNotAWorkflow() {
    // Scroll, type a command, repeat — that's just using a terminal.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<4 {
        for _ in 0..<6 { events.append(event(i, .scroll, app: "iTerm2")); i += 1 }
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "ls", appName: "iTerm2")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

@Test
func scrollBurstsCollapseToOneGesture() {
    var events: [InputEvent] = []
    var i = 0
    // 8-tick wheel burst, then a click, a key — twice.
    for _ in 0..<2 {
        for _ in 0..<8 { events.append(event(i, .scroll, app: "Mail")); i += 1 }
        events.append(event(i, .click, app: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "r", modifiers: ["command"])); i += 1
    }
    let results = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false)
    #expect(results.count == 1)
    let waste = results[0]
    // The burst is one step, not eight — recipes and time-saved stay honest.
    let scrollSteps = waste.recipe.steps.filter { $0.kind == .scroll }.count
    #expect(scrollSteps <= 1)
    #expect(waste.estimatedSecondsPerRun <= 12)
}

@Test
func recipeStepsCarryRealCoordinatesAndText() {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 42, y: 99, appName: "Safari")); i += 1
        events.append(event(i, .key, app: "Safari", key: "l", modifiers: ["command"])); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "hello", appName: "Safari")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    #expect(waste.recipe.steps.contains { $0.kind == .click && $0.x == 42 && $0.y == 99 })
    #expect(waste.recipe.steps.contains { $0.kind == .type && $0.text == "hello" })
}

@Test
func editingKeysAreNeverAWorkflow() {
    // The real-world garbage this gate exists for: "Delete → Delete → type"
    // in Chrome is someone fixing a sentence, not an automatable task.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<3 {
        events.append(event(i, .key, app: "Google Chrome", key: "Delete")); i += 1
        events.append(event(i, .key, app: "Google Chrome", key: "Delete")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "fix", appName: "Google Chrome")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

@Test
func anonymousSameAppClickingIsNotAWorkflow() {
    // Click, click, click around a browser — that's reading. No named element,
    // no shortcut, one app: no agent.
    let events = (0..<12).map { event($0, .click, app: "Google Chrome") }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

@Test
func clickPlusTypingAloneIsNotAWorkflow() {
    // Click a field and type — that's just using a text box (the "type →
    // Delete → type" cards). One structural action isn't a workflow.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<3 {
        events.append(event(i, .click, app: "Google Chrome")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .type, text: "words", appName: "Google Chrome")); i += 1
        events.append(event(i, .key, app: "Google Chrome", key: "Delete")); i += 1
    }
    #expect(WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).isEmpty)
}

@Test
func clickAXLabelBecomesTheAnchor() {
    // The recorder stores the clicked element's AX label in `text` for clicks —
    // the strongest re-targeting anchor at replay time.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 42, y: 99, text: "Send Message", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "w", modifiers: ["command"], appName: "Mail")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    let click = waste.recipe.steps.first { $0.kind == .click }!
    #expect(click.ocrAnchor == "Send Message")
}

@Test
func contextAnchorMustComeFromTheSameApp() {
    // The nearest prior context is from a DIFFERENT app — it must not become the
    // anchor for Safari clicks (it would re-target the click at the wrong thing).
    let foreign = RecordedContext(
        capturedAt: base.addingTimeInterval(-1),
        source: .screen,
        appName: "Slack",
        bundleIdentifier: "com.slack",
        windowTitle: "Slack — #general",
        ocrText: "unrelated"
    )
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 1, y: 1, appName: "Safari", windowTitle: "Safari window")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "r", modifiers: ["command"], appName: "Safari")); i += 1
    }
    let waste = WasteDetector().detect(contexts: [foreign], inputEvents: events, useEpisodeMining: false).first!
    let click = waste.recipe.steps.first { $0.kind == .click }!
    #expect(click.ocrAnchor == "Safari window")
}

@Test
func copyPasteAcrossAppsGetsNamedOutright() {
    // ⌘C in Mail then ⌘V in Numbers — the title should say what it IS.
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
        events.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    #expect(waste.title == "Copy from Mail into Numbers")
}

@Test
func titleTellsTheStoryFromAnchorsNotJustTheApp() {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(
            id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)),
            kind: .click, x: 10, y: 10, text: "Reply All", appName: "Mail"
        )); i += 1
        events.append(event(i, .key, app: "Mail", key: "r", modifiers: ["command"])); i += 1
    }
    let waste = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).first!
    #expect(waste.title.contains("Mail"))
    #expect(waste.title.contains("Reply All"))
    #expect(!waste.title.contains("Repeated steps"))
    // And the card can date the evidence.
    #expect(waste.lastSeenAt > base)
}

@Test
func resultsSortByRoutineQualityDescending() {
    var events: [InputEvent] = []
    var i = 0
    // Small workflow: 2 occurrences × 2 events in TextEdit.
    for _ in 0..<2 {
        events.append(event(i, .click, app: "TextEdit")); i += 1
        events.append(event(i, .key, app: "TextEdit", key: "s", modifiers: ["command"])); i += 1
    }
    // Big workflow: 4 occurrences × 2 events in Mail (distinct shortcut).
    for _ in 0..<4 {
        events.append(event(i, .click, app: "Mail")); i += 1
        events.append(event(i, .key, app: "Mail", key: "e", modifiers: ["command"])); i += 1
    }
    let results = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false)
    #expect(results.count >= 2)
    #expect(WasteDetector.rankingScore(results[0], now: base) >= WasteDetector.rankingScore(results[1], now: base))
    #expect(results[0].quality != nil)
}

@Test
func overlappingWorkflowsAreNotDoubleCounted() {
    // Two length-2 shapes share a boundary event: [click "Inbox", ⌘C] and
    // [⌘C, ⌘V]. The ⌘C in the middle belongs to BOTH the moment the detector
    // forgets what it has already claimed — surfacing two cards for one stretch
    // of activity and counting that time twice. Dictionary iteration order is
    // per-process random, so before the fix this also made the output flaky.
    // The earliest/strongest shape must claim its events once; the overlapping
    // neighbour is then left with too few free occurrences and drops out.
    func click(_ i: Int) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")
    }
    func key(_ i: Int, _ k: String) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: k, modifiers: ["command"], appName: "Mail")
    }
    // click ⌘C ⌘V ⌘S click ⌘C ⌘X ⌘C ⌘V  →  [click,⌘C]@{0,4} and [⌘C,⌘V]@{1,7}
    let events: [InputEvent] = [
        click(0), key(1, "c"), key(2, "v"), key(3, "s"),
        click(4), key(5, "c"), key(6, "x"), key(7, "c"), key(8, "v"),
    ]
    let results = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false)
    #expect(results.count == 1)
    // H1: the click token now carries the element identity ("Inbox").
    #expect(normalizedSignatureTokensForTest(results.first?.signature ?? "") == ["click:inbox@mail", "key:command+c@mail"])
    // The hard invariant: no event id is ever counted into two workflows.
    let allEvidence = results.flatMap(\.evidence)
    #expect(Set(allEvidence).count == allEvidence.count)
}

// MARK: - waste(fromInstance:) — the reusable single-range entry point (Teach-once)

/// One occurrence of the cross-app copy/paste, offset so two of them form the
/// repeated workflow `detect` mines.
private func copyPasteInstance(_ start: Int) -> [InputEvent] {
    var e: [InputEvent] = []
    var i = start
    e.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")); i += 1
    e.append(event(i, .key, app: "Mail", key: "c", modifiers: ["command"])); i += 1
    e.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers")); i += 1
    e.append(event(i, .key, app: "Numbers", key: "v", modifiers: ["command"])); i += 1
    return e
}

private func scrollEvent(
    _ i: Int,
    dx: Int,
    dy: Int,
    at offset: TimeInterval? = nil,
    x: Double = 100,
    y: Double = 100,
    app: String = "Safari",
    bundle: String? = "com.apple.Safari",
    window: String? = "Inbox - Gmail"
) -> InputEvent {
    InputEvent(
        id: Int64(i),
        capturedAt: base.addingTimeInterval(offset ?? Double(i)),
        kind: .scroll,
        x: x,
        y: y,
        modifiers: ["\(dx)", "\(dy)"],
        appName: app,
        bundleIdentifier: bundle,
        windowTitle: window
    )
}

@Test
func wasteFromInstanceBuildsTheSameRecipeAsDetect() {
    // The intentional path (Teach-once) must yield the very recipe the automatic path
    // would for that instance — one creation spine, not a divergent second one.
    let detector = WasteDetector()
    let detected = detector.detect(contexts: [], inputEvents: copyPasteInstance(0) + copyPasteInstance(4), useEpisodeMining: false).first!
    let taught = detector.waste(fromInstance: copyPasteInstance(0), contexts: [])

    let one = try! #require(taught)
    #expect(one.signature == detected.signature)               // same token shape
    #expect(one.recipe.steps.count == detected.recipe.steps.count) // activateApp×2 + 4 actions
    #expect(one.apps == ["Mail", "Numbers"])
    #expect(one.occurrences == 1)                              // a single demonstration
    #expect(one.recipe.steps.contains { $0.kind == .key && $0.key == "v" })
}

@Test
func wasteFromInstanceRefusesPassiveScrollSpam() {
    let detector = WasteDetector()
    let scrolls = (0..<8).map { scrollEvent($0, dx: 0, dy: 0, at: Double($0) * 0.1) }
    #expect(detector.waste(fromInstance: scrolls, contexts: []) == nil)
}

@Test
func wasteFromInstanceRefusesBareEditingKeys() {
    let detector = WasteDetector()
    let keys = [
        event(0, .key, app: "Notes", key: "Delete"),
        event(1, .key, app: "Notes", key: "ArrowDown"),
        event(2, .key, app: "Notes", key: "Return"),
    ]
    #expect(detector.waste(fromInstance: keys, contexts: []) == nil)
}

@Test
func wasteFromInstanceAcceptsSingleTypedDemo() {
    let detector = WasteDetector()
    let typing = [InputEvent(id: 1, capturedAt: base, kind: .type, text: "typed 5 chars", appName: "Notes")]
    let taught = detector.waste(fromInstance: typing, contexts: [])
    #expect(taught?.recipe.steps.contains { $0.kind == .type && $0.isParameter } == true)
}

@Test
func singleTypedDemosBecomeLiveParameters() throws {
    let detector = WasteDetector()
    let cases: [(String, RecipeParameterKind, Bool)] = [
        ("mira@example.com", .email, true),
        ("4471", .number, true),
        ("please call later", .freeText, true),
        ("typed 12 chars", .freeText, false),
    ]

    for (raw, expectedKind, expectsHash) in cases {
        let taught = try #require(detector.waste(
            fromInstance: [InputEvent(id: 1, capturedAt: base, kind: .type, text: raw, appName: "Notes")],
            contexts: []
        ))
        let type = try #require(taught.recipe.steps.first { $0.kind == .type })
        #expect(type.isParameter)
        #expect(type.parameterKind == expectedKind)
        #expect(type.text != raw || raw.hasPrefix("typed "))
        #expect(type.valueExamples.first?.hasPrefix("\(expectedKind.rawValue):") == true)
        #expect(type.valueHashes.isEmpty != expectsHash)
    }
}

@Test
func singleAppClickTypeReturnDemoBuildsAParameterizedRecipe() throws {
    let detector = WasteDetector()
    let events = [
        InputEvent(id: 1, capturedAt: base, kind: .click, x: 10, y: 20, text: "Message", appName: "Notes"),
        InputEvent(id: 2, capturedAt: base.addingTimeInterval(1), kind: .type, text: "Call Sam at 4", appName: "Notes"),
        event(3, .key, app: "Notes", key: "Return"),
    ]

    let taught = try #require(detector.waste(fromInstance: events, contexts: []))
    let type = try #require(taught.recipe.steps.first { $0.kind == .type })
    #expect(taught.apps == ["Notes"])
    #expect(type.isParameter)
    #expect(type.parameterKind == .freeText)
    #expect(type.text == "freeText:typed 13 chars")
    #expect(!taught.recipe.steps.contains { $0.text == "Call Sam at 4" })
}

@Test
func singleClickedDataTargetBecomesALiveParameter() throws {
    let descriptor = AXTargetDescriptorV2.encode(label: "Acme Corp", role: "AXRow")
    let events = [
        InputEvent(id: 1, capturedAt: base, kind: .click, x: 10, y: 20, text: "Acme Corp", appName: "CRM", targetDescriptor: descriptor),
        InputEvent(id: 2, capturedAt: base.addingTimeInterval(1), kind: .key, key: "Return", appName: "CRM"),
    ]

    let taught = try #require(WasteDetector().waste(fromInstance: events, contexts: []))
    let click = try #require(taught.recipe.steps.first { $0.kind == .click })

    #expect(click.isParameter)
    #expect(click.parameterKind == .personName)
    #expect(click.parameterKey?.hasPrefix("target_personName_") == true)
    #expect(click.text == "personName slot")
    #expect(click.ocrAnchor == "personName slot")
    #expect(AXTargetDescriptorV2.decode(click.targetDescriptor)?.label == "personName slot")
    #expect(click.valueHashes == [AuditIdentity.hash("acme corp")])
    #expect(!taught.recipe.steps.contains { step in
        [step.text, step.ocrAnchor, step.targetDescriptor, step.parameterKey].contains { $0?.contains("Acme Corp") == true }
    })
}

@Test
func singleClickedCommandTargetStaysAReplayAnchor() throws {
    let events = [
        InputEvent(id: 1, capturedAt: base, kind: .click, x: 10, y: 20, text: "Send", appName: "Mail"),
        InputEvent(id: 2, capturedAt: base.addingTimeInterval(1), kind: .key, key: "Return", appName: "Mail"),
    ]

    let taught = try #require(WasteDetector().waste(fromInstance: events, contexts: []))
    let click = try #require(taught.recipe.steps.first { $0.kind == .click })

    #expect(!click.isParameter)
    #expect(click.text == "Send")
    #expect(click.ocrAnchor == "Send")
}

@Test
func singleCopyPasteDemoKeepsPasteAsLiveDataflow() throws {
    let taught = try #require(WasteDetector().waste(fromInstance: copyPasteInstance(0), contexts: []))
    let copy = try #require(taught.recipe.steps.first { $0.kind == .key && $0.key == "c" })
    let paste = try #require(taught.recipe.steps.first { $0.kind == .key && $0.key == "v" })
    #expect(paste.isParameter)
    #expect(paste.parameterKind == .freeText)
    #expect(paste.valueExamples == ["freeText:clipboard"])
    #expect(paste.valueHashes.isEmpty)
    #expect(paste.sourceStepIDs.contains(copy.order))
    #expect(paste.dataflowEdgeID?.isEmpty == false)
}

@Test
func detectStillIgnoresSingleRunsAndConstantRepeatedTyping() throws {
    let detector = WasteDetector()
    let singleRun = [
        InputEvent(id: 1, capturedAt: base, kind: .click, x: 10, y: 20, text: "Message", appName: "Notes"),
        InputEvent(id: 2, capturedAt: base.addingTimeInterval(1), kind: .type, text: "same", appName: "Notes"),
        event(3, .key, app: "Notes", key: "s", modifiers: ["command"]),
    ]
    #expect(detector.detect(contexts: [], inputEvents: singleRun, useEpisodeMining: false).isEmpty)

    let repeated = singleRun + [
        InputEvent(id: 4, capturedAt: base.addingTimeInterval(10), kind: .click, x: 10, y: 20, text: "Message", appName: "Notes"),
        InputEvent(id: 5, capturedAt: base.addingTimeInterval(11), kind: .type, text: "same", appName: "Notes"),
        InputEvent(id: 6, capturedAt: base.addingTimeInterval(12), kind: .key, key: "s", modifiers: ["command"], appName: "Notes"),
        InputEvent(id: 7, capturedAt: base.addingTimeInterval(20), kind: .click, x: 10, y: 20, text: "Message", appName: "Notes"),
        InputEvent(id: 8, capturedAt: base.addingTimeInterval(21), kind: .type, text: "same", appName: "Notes"),
        InputEvent(id: 9, capturedAt: base.addingTimeInterval(22), kind: .key, key: "s", modifiers: ["command"], appName: "Notes"),
    ]
    let waste = try #require(detector.detect(contexts: [], inputEvents: repeated, useEpisodeMining: false).first)
    let type = try #require(waste.recipe.steps.first { $0.kind == .type })
    #expect(!type.isParameter)
    #expect(type.text == "same")
}

@Test
func teachScrollTicksCoalesceByDirectionAndSumDeltas() {
    let events = [
        scrollEvent(1, dx: 0, dy: -3, at: 0.0),
        scrollEvent(2, dx: 0, dy: -4, at: 0.1),
        scrollEvent(3, dx: 0, dy: -5, at: 0.2),
    ]
    let collapsed = WasteDetector.teachInstanceEvents(from: events)
    #expect(collapsed.count == 1)
    #expect(collapsed.first?.modifiers == ["0", "-12"])
}

@Test
func teachScrollGesturesSplitOnWindowPointerAndDirection() {
    let events = [
        scrollEvent(1, dx: 0, dy: -3, at: 0.0, x: 10, y: 10, window: "Inbox - Gmail"),
        scrollEvent(2, dx: 0, dy: -4, at: 0.1, x: 10, y: 10, window: "Tasks - Notion"),
        scrollEvent(3, dx: 0, dy: -5, at: 0.2, x: 220, y: 10, window: "Tasks - Notion"),
        scrollEvent(4, dx: 0, dy: 6, at: 0.3, x: 220, y: 10, window: "Tasks - Notion"),
    ]
    let collapsed = WasteDetector.teachInstanceEvents(from: events)
    #expect(collapsed.count == 4)
}

@Test
func teachScrollDirectionChangeIsPreservedBeforeClick() throws {
    let detector = WasteDetector()
    let events = [
        scrollEvent(1, dx: 0, dy: -6, at: 0.0),
        scrollEvent(2, dx: 0, dy: 5, at: 0.1),
        InputEvent(id: 3, capturedAt: base.addingTimeInterval(0.2), kind: .click, x: 10, y: 20, text: "Open", appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Inbox - Gmail"),
    ]
    let taught = try #require(detector.waste(fromInstance: events, contexts: []))
    #expect(taught.recipe.steps.filter { $0.kind == .scroll }.count == 2)
}

@Test
func wasteFromInstanceHonorsTheWebSurfaceResolver() {
    // With a web-identity resolver a browser demonstration is named for the web app,
    // exactly as the detector names it — while still recording the real browser.
    let detector = WasteDetector()
    var events: [InputEvent] = []
    var i = 0
    events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Compose", appName: "Google Chrome", windowTitle: "Inbox - Gmail")); i += 1
    events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Google Chrome", windowTitle: "Inbox - Gmail")); i += 1
    let resolver: @Sendable (InputEvent) -> String? = { WebAppIdentity.surface(fromWindowTitle: $0.windowTitle) }
    let taught = try! #require(detector.waste(fromInstance: events, contexts: [], surface: resolver))
    #expect(taught.title.contains("Gmail"))
    #expect(taught.apps == ["Google Chrome"])
}

@Test
func webAppsInSameBrowserAreDistinctWorkflows() {
    // Two different web apps, BOTH in Google Chrome, each a repeated click + ⌘C.
    // Keyed only on the macOS app they tokenize identically and merge into one
    // "Chrome" workflow; with a web-app resolver they become two distinct agents,
    // each named for the web app — while still recording the real browser.
    func click(_ i: Int, _ title: String) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Compose", appName: "Google Chrome", windowTitle: title)
    }
    func copy(_ i: Int, _ title: String) -> InputEvent {
        InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Google Chrome", windowTitle: title)
    }
    let gmail = "Inbox - me@example.com - Gmail"
    let notion = "Tasks - Notion"
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 { events.append(click(i, gmail)); i += 1; events.append(copy(i, gmail)); i += 1 }
    for _ in 0..<2 { events.append(click(i, notion)); i += 1; events.append(copy(i, notion)); i += 1 }

    let resolver: @Sendable (InputEvent) -> String? = { WebAppIdentity.surface(fromWindowTitle: $0.windowTitle) }
    let results = WasteDetector().detect(contexts: [], inputEvents: events, webAppIdentity: resolver, useEpisodeMining: false)
    #expect(results.count == 2)
    #expect(results.contains { $0.title.contains("Gmail") })
    #expect(results.contains { $0.title.contains("Notion") })
    // The real browser is still what's recorded, so replay + background routing work.
    #expect(results.allSatisfy { $0.apps == ["Google Chrome"] })

    // Without a resolver the document identity still keeps the workflows distinct,
    // but the cards fall back to the browser name instead of the web-app names.
    let browserOnly = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false)
    #expect(browserOnly.count == 2)
    #expect(browserOnly.allSatisfy { $0.title.contains("Google Chrome") })
}
