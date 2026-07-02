import AppKit
import CascadeMemory
import CoreGraphics
import Testing

@testable import AppShell
@testable import ComputerUseKit
@testable import ProviderKit

// d14: pins the AX-SoM picker PATH — the planner names a mark id from the
// d10/d11 note, the d12 picker resolves it to the SAME control, and the
// grounded point is the element's EXACT frame center in the executor's space,
// where the d06 semantic activation (`elementAtPosition` → AXPress) fires on
// the very control the planner picked. Scenarios mirror tonight's live
// failures: Notes → "New Note", System Settings → "Privacy & Security",
// Keynote start screen → a template.
//
// These tests are the deterministic half of d14. The FINAL proof is the live
// run only the user can perform (see the commit note): flag
// `cascade.experimentalCompressedObservation` on, run the three tasks, and
// confirm in `audit_event` that `grounding.verifier` rows carry the
// ax_som_mark_pick reason, the click lands, and each task advances.
struct AXSoMPickerPathTests {
    // MARK: - Fixture geometry: synthetic 1440×900 Retina primary display

    private static let displayCGBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private static func fixtureTransform() throws -> CoordinateTransform {
        let screen = try #require(CoordinateTransform.ScreenGeometry(
            displayID: 7,
            logicalFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingPixelSize: CGSize(width: 2880, height: 1800)
        ))
        return try #require(CoordinateTransform(screen: screen))
    }

    private static func match(
        id: String,
        label: String,
        role: String,
        container: String,
        frame: CGRect?,
        actions: [String] = ["AXPress"]
    ) -> AXElementResolver.Match {
        AXElementResolver.Match(
            id: id,
            center: frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 60, y: 35),
            frame: frame,
            role: role,
            title: label,
            score: 1,
            descriptor: AXTargetDescriptorV2(
                label: label,
                role: role,
                container: container,
                supportedActions: actions
            ),
            actionableNode: AXElementResolver.ActionableNode(
                stableID: id,
                role: role,
                title: label,
                supportedActions: actions
            )
        )
    }

    /// One tonight-failure scenario: the control the planner must pick, a
    /// decoy sharing the surface, the goal that surfaces it, and the exact
    /// expected executor-space point + frame for the pick.
    private struct Scenario {
        let name: String
        let goal: String
        let target: AXElementResolver.Match
        let decoy: AXElementResolver.Match
        /// Exact expected display-local AppKit point (bottom-left origin):
        /// the CG frame center with y flipped inside the 900pt display.
        let expectedPoint: CGPoint
        /// The exact element frame recentred on the expected point.
        let expectedRegion: CGRect
    }

    private static let scenarios: [Scenario] = [
        Scenario(
            name: "Notes → New Note",
            goal: "open Notes and create a new note",
            // CG top-left frame (708,52,84×24) → center (750,64) → AppKit (750, 900-64=836).
            target: match(
                id: "ax:1a2b3c4d5e6f708192a3b4c5",
                label: "New Note",
                role: "AXButton",
                container: "toolbar: Notes",
                frame: CGRect(x: 708, y: 52, width: 84, height: 24)
            ),
            decoy: match(
                id: "ax:dddd0000dddd0000dddd0000",
                label: "Delete",
                role: "AXButton",
                container: "toolbar: Notes",
                frame: CGRect(x: 806, y: 52, width: 60, height: 24)
            ),
            expectedPoint: CGPoint(x: 750, y: 836),
            expectedRegion: CGRect(x: 708, y: 824, width: 84, height: 24)
        ),
        Scenario(
            name: "System Settings → Privacy & Security",
            goal: "open System Settings and open Privacy & Security",
            // CG frame (12,418,210×28) → center (117,432) → AppKit (117, 900-432=468).
            target: match(
                id: "ax:feedbead0011223344556677",
                label: "Privacy & Security",
                role: "AXRow",
                container: "sidebar: System Settings",
                frame: CGRect(x: 12, y: 418, width: 210, height: 28)
            ),
            decoy: match(
                id: "ax:eeee1111eeee1111eeee1111",
                label: "General",
                role: "AXRow",
                container: "sidebar: System Settings",
                frame: CGRect(x: 12, y: 386, width: 210, height: 28)
            ),
            expectedPoint: CGPoint(x: 117, y: 468),
            expectedRegion: CGRect(x: 12, y: 454, width: 210, height: 28)
        ),
        Scenario(
            name: "Keynote start screen → template",
            goal: "open Keynote and pick the White theme",
            // CG frame (400,300,180×120) → center (490,360) → AppKit (490, 900-360=540).
            target: match(
                id: "ax:0badc0de5566778899aabbcc",
                label: "White",
                role: "AXCell",
                container: "collection: Choose a Theme",
                frame: CGRect(x: 400, y: 300, width: 180, height: 120)
            ),
            decoy: match(
                id: "ax:ffff2222ffff2222ffff2222",
                label: "Black",
                role: "AXCell",
                container: "collection: Choose a Theme",
                frame: CGRect(x: 600, y: 300, width: 180, height: 120)
            ),
            expectedPoint: CGPoint(x: 490, y: 540),
            expectedRegion: CGRect(x: 400, y: 480, width: 180, height: 120)
        ),
    ]

    // MARK: - Mark id → exact frame (the tonight-failure trio, note → pick round trip)

    @Test func renderedNoteIDResolvesToTheExactFrameForEachTonightFailure() throws {
        let transform = try Self.fixtureTransform()
        for scenario in Self.scenarios {
            let harvest = [scenario.target, scenario.decoy]

            // 1. The d10/d11 note renders the control with a display id …
            let note = try #require(AXCompressedObservation.render(matches: harvest, goal: scenario.goal))
            let line = try #require(
                note.text.components(separatedBy: "\n").first { $0.contains("“\(scenario.target.title)”") },
                "\(scenario.name): note must render the target control"
            )
            let noteMark = try #require(
                AXCompressedObservation.markToken(in: line),
                "\(scenario.name): rendered line must carry a parseable [ax:…] id"
            )

            // 2. … the planner echoes it in a target string …
            let plannerTarget = "click the [\(noteMark)] “\(scenario.target.title)”"
            #expect(AXCompressedObservation.markToken(in: plannerTarget) == noteMark)

            // 3. … and the d12 picker resolves the SAME id against the SAME
            //    harvest to the exact frame — no visual model, no label fuzz.
            let candidate = try #require(
                MixtureGrounder.markPickCandidate(
                    mark: noteMark,
                    matches: harvest,
                    displayCGBounds: Self.displayCGBounds,
                    transform: transform
                ),
                "\(scenario.name): the note's own id must resolve"
            )
            #expect(candidate.point == scenario.expectedPoint, "\(scenario.name)")
            #expect(candidate.region == scenario.expectedRegion, "\(scenario.name)")
            #expect(candidate.displayBounds == scenario.expectedRegion, "\(scenario.name)")
            #expect(candidate.candidateID == AXCompressedObservation.stableID(for: scenario.target))
            #expect(candidate.source == .accessibility)
            #expect(candidate.coordinateSpace == .displayLocalAppKitPoints)
            #expect(candidate.confidence == MixtureGrounder.markPickConfidence)
            #expect(candidate.reason == "ax_som_mark_pick")
            #expect(candidate.role == scenario.target.role)
            // The typed coordinate chain is persisted for the agent.ground audit.
            let chain = try #require(candidate.coordinateChain)
            #expect(chain.mappedPoint == scenario.expectedPoint)
        }
    }

    // MARK: - Exact frame → action (the d06 semantic-activation contract)

    @Test func pickedPointIsTheSemanticActivationHitPointInsideTheExactFrame() throws {
        // executeCU's d06 path runs `elementAtPosition(point)` then AXPress on
        // the hit element. The pick contract that makes that land on the
        // planner's control: point == center of the EXACT element frame, and
        // the frame is the element's own size — never the generic 96×28 chip
        // when AX exposed a real frame.
        let transform = try Self.fixtureTransform()
        for scenario in Self.scenarios {
            let candidate = try #require(MixtureGrounder.markPickCandidate(
                mark: scenario.target.id!,
                matches: [scenario.target, scenario.decoy],
                displayCGBounds: Self.displayCGBounds,
                transform: transform
            ))
            let region = try #require(candidate.region)
            let point = try #require(candidate.point)
            #expect(point == CGPoint(x: region.midX, y: region.midY))
            #expect(region.size == scenario.target.frame?.size)
        }
    }

    @Test func markPickConfidenceClearsEveryRiskGateAndHarvestCoversTheNote() {
        // The pick names identity, not a fuzzy label match — it must clear the
        // strictest per-risk minimum-confidence gate or high-risk actions
        // (System Settings toggles) would re-ground through the visual model.
        #expect(MixtureGrounder.markPickConfidence >= GroundingRequestOptions.highRisk().minimumConfidence)
        #expect(MixtureGrounder.markPickConfidence >= GroundingRequestOptions.default.minimumConfidence)
        #expect(MixtureGrounder.markPickConfidence <= 1)
        // Every id the planner can possibly have seen must be re-findable: the
        // pick re-harvest must cover the note render bound (20) and the d10/d11
        // note harvests (24).
        #expect(MixtureGrounder.markPickHarvestLimit >= AXCompressedObservation.defaultMaxCandidates)
        #expect(MixtureGrounder.markPickHarvestLimit >= 24)
    }

    // MARK: - Refusals fall back instead of guessing

    @Test func unknownAmbiguousAndOffDisplayMarksResolveToNil() throws {
        let transform = try Self.fixtureTransform()
        let harvest = [Self.scenarios[0].target, Self.scenarios[0].decoy]

        // Unknown id (stale note, control vanished) → nil → ordinary grounding.
        #expect(MixtureGrounder.markPickCandidate(
            mark: "ax:deadbeef",
            matches: harvest,
            displayCGBounds: Self.displayCGBounds,
            transform: transform
        ) == nil)

        // Two DIFFERENT identities sharing the named prefix → refuse, never guess.
        let colliding = [
            Self.match(
                id: "ax:aaaa5555bbbb000000000001",
                label: "One", role: "AXButton", container: "toolbar: App",
                frame: CGRect(x: 100, y: 100, width: 80, height: 24)
            ),
            Self.match(
                id: "ax:aaaa5555cccc000000000002",
                label: "Two", role: "AXButton", container: "toolbar: App",
                frame: CGRect(x: 200, y: 100, width: 80, height: 24)
            ),
        ]
        #expect(MixtureGrounder.markPickCandidate(
            mark: "ax:aaaa5555",
            matches: colliding,
            displayCGBounds: Self.displayCGBounds,
            transform: transform
        ) == nil)
        // A longer prefix disambiguates.
        #expect(MixtureGrounder.markPickCandidate(
            mark: "ax:aaaa5555bbbb",
            matches: colliding,
            displayCGBounds: Self.displayCGBounds,
            transform: transform
        )?.label == "One")

        // A resolved control whose center is NOT on the captured display must
        // refuse (never click blind on the wrong monitor).
        let offDisplay = Self.match(
            id: "ax:0ff5c4ee40ff5c4ee40ff5c4",
            label: "Elsewhere", role: "AXButton", container: "toolbar: App",
            frame: CGRect(x: 2000, y: 100, width: 80, height: 24)
        )
        #expect(MixtureGrounder.markPickCandidate(
            mark: "ax:0ff5c4ee",
            matches: [offDisplay],
            displayCGBounds: Self.displayCGBounds,
            transform: transform
        ) == nil)
    }

    @Test func frameLessMatchFallsBackToTheGenericChipSize() throws {
        // Legacy harvests without the d05/d10 frame capture still pick — with
        // the conservative generic chip, not an invented frame.
        let transform = try Self.fixtureTransform()
        let frameLess = Self.match(
            id: "ax:ab12cd34ef56ab12cd34ef56",
            label: "Legacy", role: "AXButton", container: "toolbar: App",
            frame: nil
        )
        let candidate = try #require(MixtureGrounder.markPickCandidate(
            mark: "ax:ab12cd34",
            matches: [frameLess],
            displayCGBounds: Self.displayCGBounds,
            transform: transform
        ))
        #expect(candidate.region?.size == CGSize(width: 96, height: 28))
    }

    // MARK: - Public grounding path: pick short-circuits, fallback strips, flag-off is byte-identical

    @Test func plannerNamedMarkShortCircuitsPublicGroundingWithoutVisualModel() async throws {
        // Runs against the REAL primary display (the same NSScreen matching
        // `captureDisplayGeometry` uses live). Skips when the environment
        // can't provide an unambiguous screen (headless, mirrored-size
        // externals) — the pure-path tests above still pin the math.
        struct ScreenFixture: Sendable {
            let widthPoints: Int
            let heightPoints: Int
            let expectedPoint: CGPoint
        }
        let cgCenter = CGPoint(x: 200, y: 100)
        let fixture: ScreenFixture? = await MainActor.run {
            guard let screen = NSScreen.screens.first else { return nil }
            let width = Int(screen.frame.width.rounded())
            let height = Int(screen.frame.height.rounded())
            let sameSize = NSScreen.screens.filter {
                Int($0.frame.width.rounded()) == width && Int($0.frame.height.rounded()) == height
            }
            guard sameSize.count == 1, width >= 240, height >= 140 else { return nil }
            guard let transform = CoordinateTransform(screen: screen),
                  let mapping = MixtureGrounder.displayLocalMapping(
                    cgGlobalCenter: cgCenter,
                    displayCGBounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                    transform: transform
                  ) else { return nil }
            return ScreenFixture(widthPoints: width, heightPoints: height, expectedPoint: mapping.point)
        }
        guard let fixture else { return }

        let pickedStableID = "ax:00aa11bb22cc33dd44ee55ff"
        let harvest = [Self.match(
            id: pickedStableID,
            label: "Fixture Control",
            role: "AXButton",
            container: "toolbar: Fixture",
            frame: CGRect(x: cgCenter.x - 42, y: cgCenter.y - 12, width: 84, height: 24)
        )]
        let recorder = TargetRecorder()
        let outcomes = VerifierOutcomeBox()
        let grounder = MixtureGrounder(
            base: RecordingGrounder(recorder: recorder, point: nil),
            skills: .init(),
            axPickerEnabled: true,
            markPickHarvestOverride: { harvest },
            onVerifierOutcome: { await outcomes.add($0) }
        )

        let result = await grounder.groundResult(
            screenshot: Data(),
            target: "[ax:00aa11bb] the “Fixture Control” button",
            displayWidthPoints: fixture.widthPoints,
            displayHeightPoints: fixture.heightPoints
        )

        // Exact-frame pick, executor space, verdict accept — and the visual
        // grounder was NEVER called.
        #expect(result.selectedPoint == fixture.expectedPoint)
        #expect(result.verifierVerdict == .accept)
        let candidate = try #require(result.selectedCandidate)
        #expect(candidate.source == .accessibility)
        #expect(candidate.reason == "ax_som_mark_pick")
        #expect(candidate.confidence == MixtureGrounder.markPickConfidence)
        #expect(candidate.candidateID == pickedStableID)
        #expect(candidate.region?.size == CGSize(width: 84, height: 24))
        #expect(candidate.coordinateChain != nil)
        #expect(await recorder.recorded().isEmpty)

        // The pick is audited through the same grounding.verifier row —
        // selected, accessibility-sourced, and the candidate identity is a
        // fixed-width HASH, never the raw id.
        let audited = await outcomes.all()
        #expect(audited.count == 1)
        #expect(audited.first?.outcome == .selected)
        #expect(audited.first?.selectedSource == .accessibility)
        #expect(audited.first?.candidateCount == 1)
        let auditedHash = try #require(audited.first?.selectedCandidateHash)
        #expect(auditedHash.count == 16)
        #expect(auditedHash != pickedStableID)
    }

    @Test func unresolvableMarkFallsBackToStrippedTargetThroughTheOrdinaryPath() async {
        // Stale/vanished mark: the picker strips the mark reference and grounds
        // the REMAINING description through the unchanged path (here: a canvas
        // target, so it goes straight to the visual grounder).
        let recorder = TargetRecorder()
        let grounder = MixtureGrounder(
            base: RecordingGrounder(recorder: recorder, point: CGPoint(x: 10, y: 10)),
            skills: .init(),
            axPickerEnabled: true,
            markPickHarvestOverride: { [] }
        )
        let point = await grounder.ground(
            screenshot: Data(),
            target: "[ax:0123456789ab] the canvas target",
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )
        #expect(point == CGPoint(x: 10, y: 10))
        #expect(await recorder.recorded() == ["the canvas target"])
    }

    @Test func pickerFlagOffLeavesTheTargetByteIdentical() async {
        // Flag off (shipped default): no pick, no stripping — the visual
        // grounder receives EXACTLY what the planner said, mark and all.
        let recorder = TargetRecorder()
        let grounder = MixtureGrounder(
            base: RecordingGrounder(recorder: recorder, point: CGPoint(x: 5, y: 5)),
            skills: .init(),
            axPickerEnabled: false,
            markPickHarvestOverride: { [] }
        )
        let target = "[ax:0123456789ab] the canvas target"
        _ = await grounder.ground(
            screenshot: Data(),
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )
        #expect(await recorder.recorded() == [target])
    }
}

// MARK: - Test doubles

private actor TargetRecorder {
    private var targets: [String] = []

    func record(_ target: String) {
        targets.append(target)
    }

    func recorded() -> [String] {
        targets
    }
}

/// A base visual grounder that records every target it is asked to ground —
/// the probe for "the visual model was (never) called, and with WHAT text".
private struct RecordingGrounder: VisualGrounder {
    let recorder: TargetRecorder
    let point: CGPoint?

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        await recorder.record(target)
        return point
    }
}

private actor VerifierOutcomeBox {
    private var outcomes: [MixtureGrounder.VerifierOutcome] = []

    func add(_ outcome: MixtureGrounder.VerifierOutcome) {
        outcomes.append(outcome)
    }

    func all() -> [MixtureGrounder.VerifierOutcome] {
        outcomes
    }
}
