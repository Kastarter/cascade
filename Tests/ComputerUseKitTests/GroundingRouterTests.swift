import Testing

@testable import ComputerUseKit

// d15: the single routing gate — AX-first by default, visual grounder ONLY for
// canvas / non-AX / stale-AX, every visual route carrying an audited reason.
struct GroundingRouterTests {
    private func richProfile(
        staleNodeCount: Int = 0,
        sampledNodeCount: Int = 80
    ) -> AXRuntimeProfile {
        AXRuntimeProfile(
            bundleIdentifier: "com.example.Native",
            appName: "Native",
            sampledNodeCount: sampledNodeCount,
            actionableRoleCount: 20,
            labeledActionableCount: 15,
            identifierCount: 6,
            frameFailureCount: 1,
            timeoutOrErrorCount: 0,
            axErrorSummary: AXElementResolver.AXErrorSummary(staleNodeCount: staleNodeCount),
            canvasSizedElementRatio: 0.05
        )
    }

    private var sparseProfile: AXRuntimeProfile {
        AXRuntimeProfile(
            bundleIdentifier: "com.example.Sparse",
            appName: "Sparse",
            sampledNodeCount: 8,
            actionableRoleCount: 1,
            labeledActionableCount: 0,
            identifierCount: 0,
            frameFailureCount: 0,
            timeoutOrErrorCount: 0,
            canvasSizedElementRatio: 0
        )
    }

    @Test func defaultRouteIsAXFirst() {
        let decision = GroundingRouter.route(
            target: "the New Note button",
            frontmostBundleIdentifier: "com.apple.Notes",
            ownBundleIdentifier: "com.humain.cascade",
            axUnreliable: false,
            runtimeProfile: { self.richProfile() }
        )
        #expect(decision.allowsAX)
        #expect(decision.visualReason == nil)
        #expect(decision.runtimeProfile != nil)
    }

    @Test func canvasConceptRoutesToVisual() {
        let decision = GroundingRouter.route(
            target: "the title placeholder",
            frontmostBundleIdentifier: "com.apple.iWork.Keynote",
            axUnreliable: false
        )
        #expect(!decision.allowsAX)
        #expect(decision.visualReason == .canvasConcept)
    }

    @Test func ownUIRoutesToVisualForEveryRequestKind() {
        for kind in [GroundingRouter.RequestKind.labelMatch, .markPick] {
            let decision = GroundingRouter.route(
                target: "the Save button",
                requestKind: kind,
                frontmostBundleIdentifier: "com.humain.cascade",
                ownBundleIdentifier: "com.humain.cascade",
                axUnreliable: false
            )
            #expect(!decision.allowsAX)
            #expect(decision.visualReason == .ownUI)
        }
    }

    @Test func axUnreliableAppRoutesToVisualForEveryRequestKind() {
        for kind in [GroundingRouter.RequestKind.labelMatch, .markPick] {
            let decision = GroundingRouter.route(
                target: "the Render button",
                requestKind: kind,
                frontmostBundleIdentifier: "org.blenderfoundation.blender",
                ownBundleIdentifier: "com.humain.cascade",
                axUnreliable: true
            )
            #expect(!decision.allowsAX)
            #expect(decision.visualReason == .axUnreliableApp)
        }
    }

    @Test func sparseTreeRoutesToVisualAndCarriesTheProfile() {
        let decision = GroundingRouter.route(
            target: "the Save button",
            frontmostBundleIdentifier: "com.example.Sparse",
            axUnreliable: false,
            runtimeProfile: { self.sparseProfile }
        )
        #expect(!decision.allowsAX)
        #expect(decision.visualReason == .sparseAX)
        #expect(decision.runtimeProfile?.isSparse == true)
    }

    @Test func staleDominatedTreeRoutesToVisualOnlyWhenGateEnabled() {
        let stale = richProfile(staleNodeCount: 40, sampledNodeCount: 80)
        #expect(GroundingRouter.isStaleDominated(stale))
        // Gate off (shipped default): routing is byte-identical to pre-d15.
        let off = GroundingRouter.route(
            target: "the Save button",
            frontmostBundleIdentifier: "com.example.Native",
            axUnreliable: false,
            staleAXGateEnabled: false,
            runtimeProfile: { stale }
        )
        #expect(off.allowsAX)
        // Gate on: stale-node-dominated trees defer to the visual grounder.
        let on = GroundingRouter.route(
            target: "the Save button",
            frontmostBundleIdentifier: "com.example.Native",
            axUnreliable: false,
            staleAXGateEnabled: true,
            runtimeProfile: { stale }
        )
        #expect(!on.allowsAX)
        #expect(on.visualReason == .staleAX)
        #expect(on.runtimeProfile == stale)
    }

    @Test func fewStaleNodesAreNoiseNotStaleness() {
        // Below the minimum count: noisy, not dying.
        #expect(!GroundingRouter.isStaleDominated(richProfile(staleNodeCount: 3, sampledNodeCount: 8)))
        // Above the count but a small share of a big healthy sample.
        #expect(!GroundingRouter.isStaleDominated(richProfile(staleNodeCount: 5, sampledNodeCount: 600)))
    }

    @Test func markPickSkipsFuzzyLabelProtectionsAndProfileScrape() {
        var scraped = false
        let decision = GroundingRouter.route(
            target: "ax:1a2b3c4d canvas placeholder",
            requestKind: .markPick,
            frontmostBundleIdentifier: "com.apple.iWork.Keynote",
            ownBundleIdentifier: "com.humain.cascade",
            axUnreliable: false,
            staleAXGateEnabled: true,
            runtimeProfile: {
                scraped = true
                return self.sparseProfile
            }
        )
        #expect(decision.allowsAX)
        #expect(!scraped)
        #expect(decision.runtimeProfile == nil)
    }

    @Test func profileScrapeIsNotPaidWhenEarlierChecksDecide() {
        var scraped = false
        _ = GroundingRouter.route(
            target: "the Render button",
            frontmostBundleIdentifier: "org.blenderfoundation.blender",
            axUnreliable: true,
            runtimeProfile: {
                scraped = true
                return self.richProfile()
            }
        )
        #expect(!scraped)
    }

    @Test func auditDetailCarriesReasonAndCountsButNeverRawText() {
        let decision = GroundingRouter.route(
            target: "the secret invoice field",
            frontmostBundleIdentifier: "com.example.Sparse",
            axUnreliable: false,
            runtimeProfile: { self.sparseProfile }
        )
        let detail = decision.safeAuditDetail
        #expect(detail.contains("route=visual_only"))
        #expect(detail.contains("reason=sparse_ax"))
        #expect(detail.contains("kind=label"))
        #expect(detail.contains("bundleHash="))
        #expect(detail.contains("nodes=8"))
        #expect(detail.contains("sparse=true"))
        #expect(!detail.contains("secret"))
        #expect(!detail.contains("invoice"))
        #expect(!detail.contains("com.example.Sparse"))
    }

    @Test func axFirstAuditDetailHasNoReason() {
        let decision = GroundingRouter.route(
            target: "the New Note button",
            frontmostBundleIdentifier: "com.apple.Notes",
            axUnreliable: false,
            runtimeProfile: { self.richProfile() }
        )
        let detail = decision.safeAuditDetail
        #expect(detail.contains("route=ax_first"))
        #expect(!detail.contains("reason="))
    }
}
