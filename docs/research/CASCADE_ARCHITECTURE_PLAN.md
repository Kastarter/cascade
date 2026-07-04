# CASCADE TARGET ARCHITECTURE & WORKFLOW PLAN
**Date: 2026-07-04 · Baseline: HEAD `04ba3e1` · Status: definitive engineering plan**

This document synthesizes the three lens-proposals (reliability-first, perception-first, product-first) and the 536-commit Evolution Ledger into ONE target architecture. The chosen spine is the **perception-first design** — one typed perception/verification contract with the recorder as grounding substrate — because the ledger's product-defining problem is the grounding wall (HP-5) and the moat is AX-first grounding, not the loop. Onto that spine we graft the reliability-first proposal's **EpisodeReliabilityKernel / ModelTransport / FailureLedger** (because the number that matters is the CU failure rate) and the product-first proposal's **GovernanceKit enterprise track** (because it closes the $1B blockers while touching the CU loop at exactly one carved-out, parity-gated seam — LAW 6 isolation constructed, not asserted; §3.1/§7).

Every choice below cites the law or commit that proves it. Nothing here is greenfield; every component evolves a real module in `Sources/`.

---

## 1. NORTH STAR

**The product.** Cascade is an enterprise-grade, local-first work-context recorder for macOS that earns the right to act. It continuously records what an employee does (screen frames, AX text, OCR, input events) into an encrypted, hash-chain-audited local store; mines that evidence for repeated workflows; proposes automations the employee reviews and approves; and then executes them as a supervised computer-use agent on the real screen (or a background web sandbox) — with structural safety gates, STOP, per-action verification, and a tamper-evident audit trail. The recorder is the product and the root of trust; the agent is the recorder's payoff. Competitors must define a workflow before automating it; Cascade discovers the workflow from evidence the user already produced, and grounds its actions in an AX tree plus a memory of verified anchors that no pure-vision, cloud-side competitor can replicate (confirmed 2026-07-02: Agent S3 at 70% OSWorld SOTA failed "open Notes and type hello" on the same grounding wall Cascade has spent a month dismantling).

**The single design principle.** **STRUCTURAL, NOT ADVISORY — VERIFIED BY RUNNING.** Every guarantee — grounding, safety, privacy, retry, completion — is a code gate or a typed contract the model cannot opt out of (LAW 1, proven ≥7 times: `a066e09`, `7114759`, `f8cfabd`, `be9cdec`, `dab9e5c`), and every default flip is earned by live `audit_event` rows, never by a green build (LAW 3: `d158243`, `84af9c1`). Everything else in this document is a corollary.

---

## 2. THE EVOLUTION LEDGER IN BRIEF

The architecture obeys eight proven laws. Full record in the Evolution Ledger; this is the operating summary.

| # | Law | Load-bearing proofs |
|---|-----|---------------------|
| 1 | **Structural, not advisory.** Prompt rules, pull tools, and model self-reports all fail under pressure. Withhold tools, gate in code, classify structurally. | `a066e09`, `7114759`, `f8cfabd`, `be9cdec`, `152df62`, `dab9e5c` |
| 2 | **AX-first is free and exact; vision is the audited exception** — with preconditions: normalized score scale (`34c2efa`), multi-sample stability (`27a6fc8`), off-main AX IPC (`b40ede8`), never own frontmost (`660af3c`), value read-back after write (`abd97e6`). | `fe6dc7e`, `7773679`, `5d06d63`, `a18ea8f`, `a89f9c6` |
| 3 | **Verify by running, not compiling.** Every pivotal defect compiled green: 37 dormant modules (`e6e5275`), 0-accept verifier (`4616f23`), units bug (`34c2efa`), eval 0.0 (`dab9e5c`). Ground truth = `audit_event` DB + `log show` + live run IDs. | `d158243`, `84af9c1`, `3a485c6` |
| 4 | **Push context; never a pull tool.** Advisory grounders were called zero times across all live runs, twice. Push SoM/skills/anchors at flail moments. | `7114759`, `f8cfabd`, `d009615`, `f505607` |
| 5 | **Model tiering is per-surface, capability-constrained, decided by live audit.** Sonnet-first planner reverted (`0451679`) yet native-CU-on-Sonnet later won by audit (`90336e4`) — both verdicts empirical. Haiku has no CU beta. Transport retry on every model call (`d5dda7a`). | `0451679`, `90336e4`, `a8f625f`, `e514d94`, `a0841e4` |
| 6 | **Isolate experiments or they degrade the floor.** Crossed PRs shipped five silent regressions incl. eval 0.0 (`dab9e5c`); a tidy "cleanup" regressed the live baseline (`b40ede8`). Default-OFF flag + byte-identical OFF-path + exercised ON-path test + one PR per seam off a pinned base (`0bf61d2`). | `dab9e5c`, `b40ede8`, `e6e5275`, `34df79af` |
| 7 | **Ship the provably-safe core; state honest limits.** Degrade to missed detection, never false detection. "A wrong output is worse than no output." | `1ac20d1`, `010e3d0`, `31c1251`, `3d26f96` |
| 8 | **Verify by mechanism, not proxy; gate state up front; fail fast.** Cookie-hydration not URL (`4a51353`); preflight not stream-failure (`85f945a`); read the value back (`abd97e6`); bail after 2 misses on a zero-control view (`4f62dab`); anti-oscillation first-class (`bfe89d6`/`6b98567`). | `4a51353`, `85f945a`, `ecc1b90`, `98c2f2a` |

**The graveyard — never rebuild:**
1. Screenpipe/Tauri soft-fork (killed `d9b5cc1`) — own the native layer; port patterns, never vendor apps.
2. URL-proxy login heuristic (killed `4a51353`).
3. "Directness" prompt rule (killed `390cbaa`) — A/B live, never intuit prompt wording.
4. AX perception pull tool (`read_screen_elements`, reverted `7114759`) — 584 lines, called zero times.
5. Sonnet-first planner with Opus-on-drift (reverted in `0451679`).
6. `find_element` advisory visual grounder (reverted `f8cfabd`) — engine sound, tool wrapper dead; correct form = structural `fill_target` (`a4ee2ee`).
7. Multi-cursor pid-mouse parallel agents (reverted `de2e427`) — verify the linchpin before the tower; salvaged pieces live in ghost mode on AX-press (`1e2dc14`).
8. In-page JS cursor (abandoned `f8408c6`) — native NSImageView overlay instead.
9. Fuzzy voice re-fire matcher (reverted `1878893`) — instrument every exit before tuning any heuristic.
10. Groq planner swaps (reverted `a0841e4`) — Groq serves one vision model; planner must see the screen.
11. "Cleanup" of the AX `Task.detached` hop (reverted `b40ede8`) — AX ≠ TIS on threading.
12. Rewind-chat perf via SemanticIndex changes (disproven, stash `b20532d`) — the hang's cause is elsewhere; instrument first.
13. No-op ON-path flags (`1b5dec2` fake-cache pattern) — banned shape.
14. Haiku for computer use — no CU beta exists (`0c98387`, `a8f625f`, `90336e4`).
15. Literal-token workflow mining core; shared delimiters across grammars (`93ae884`, `dab9e5c`).
16. Deferred-with-reasons (don't casually retry): MLX-VLM grounder, gap-tolerant mining, content-based session boundaries, local VM sandbox.

---

## 3. TARGET ARCHITECTURE

### 3.1 Spine choice and explicit conflict resolutions

The three proposals converge on ~80% of the design (they all obey the same ledger). Where they diverge, this plan resolves as follows:

| Conflict | Resolution | Why (traceable) |
|---|---|---|
| **Where do the grounding contract types live?** reliability-first: inside `MixtureGrounder`; product-first: ProviderKit; perception-first: new leaf target. | **New leaf target `PerceptionCore`** (~300 lines of types, zero deps). `ActionRisk` migrates here from ProviderKit under a typealias shim (callsites compile unchanged); `CUAction` stays put — leaf consumers speak a minimal `ActionDescriptor`, mapped once at the ProviderKit boundary. | ComputerUseKit, ProviderKit, SandboxKit, AppShell, and GroundingBench must all speak one shape; a leaf target is the only placement that avoids dependency cycles — and "zero deps" is only true if the leaf never names a ProviderKit type. Compat `CGPoint?` wrappers keep every callsite compiling (SEQ-06 shape; LAW 6 additive). |
| **Kernel vs Scaffold vs AgentRuntime** — three names for extracting the shared episode harness. | **One `EpisodeReliabilityKernel` in AgentOrchestrator, shipped in SHADOW MODE first** (computes verdicts alongside the inline code, audits `kernel.shadow.diverged`, changes nothing until N live runs show zero divergence). The full `AgentRuntime` decomposition of `CascadeAppModel` (10,457 lines) is deferred to the last phase. | HP-2's four generations happened because three lanes re-learned no-effect independently — extraction is right. But `b40ede8` proves a tidy extraction can regress the live-walked baseline — shadow mode is the only extraction discipline the ledger permits. Big decomposition last, per product-first Phase 3 logic. |
| **Verifier as hard gate vs advisory?** | **Advisory-to-audit by default; hard gate ONLY when `ActionRisk` is high.** Corroboration between sources ACCEPTS. Risk is classified STRUCTURALLY (action kind + target class, the `isIrreversibleCombo` shape) — never model-emitted (`152df62`); no risk-gate code exists yet, so the hard gate ships OFF until the classifier proves fail-closed live (its own §6 gate). | HP-9 twice: 0-accept/24-reject (`4616f23`), then 100%-abstain on AX+visual agreement (`517699f`). Stacked hard gates on signals they weren't designed for manufacture silent no-ops. Risk class decides pauses, not raw score — and an unproven gate is not a resolution (LAW 1/3). |
| **Phase ordering: enterprise encryption first (product-first) vs measurement first (reliability/perception)?** | **Phase 0 = measure (d21 + d14 executed); Phase 1 = transport + post-action verify. The enterprise track (SQLCipher, GovernanceKit) runs as a PARALLEL track starting Phase 1.** It shares exactly ONE seam with the CU loop — what the recorder persists feeds verify rung 2 — so that seam is carved out (verify reads pre-redaction in-memory OCR, §4a) and the FrameRedactor gate includes verify parity (§6). Everything else it touches is loop-orthogonal. | Open wound #3: the AX-first quantitative claim is unproven on this Mac — every later step is tuning blind without the baseline (`84af9c1`, `3a485c6`). LAW 6 isolation is constructed at the one shared seam, not asserted. |
| **AnchorMemory (recorder-learned anchors): ship or defer?** | **Graft it (perception-first §2.3): write path lands early as an additive default-empty hook (pure data collection, zero behavior change, `34df79af` pattern); read path stays flagged until live rows prove descriptor-resolve precision.** | It is the deepest moat mechanism (no cloud competitor sits on the user's machine all day), and the write path is provably safe: it degrades to missed recall, never false anchor (LAW 7). |
| **PolicyEnforcer choke point (product-first) — now or later?** | **Adopt the seam now (GovernanceKit skeleton in the parallel track); wire capture + actuation through it with today's behavior as the built-in default policy.** | Policy must be structural, not advisory (LAW 1); a seam added later means retrofitting every capture/actuation site. Fail-closed default = today's `CapturePrivacyPolicy` + refusal lists; private mode stays FRAME DROP, not redact-only (the `dab9e5c` reframing regression is a named test). |
| **Who owns no-effect/state signatures?** | **`StateSignatureProvider` protocol in PerceptionCore; per-surface impls: recorder `gridHashes` (screen), `WebStateSignature` (web).** | HP-2's final form: the web lane needed its own signature (`8bca67b`) — one protocol, per-surface implementations, so no lane ever re-learns the lesson. |

### 3.2 Component map (evolving the real modules)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ AppShell (SHRINKS over time; never rewritten)                                  │
│  CascadeRootView (Reel/Cascades/Manager + NEW Compliance tab)                  │
│  CascadeAppModel → end-state: flags, DI wiring, publish-to-UI                  │
│  NotchController · SandboxBoxController · Voice (VoiceFragmentGate, en-lock)   │
├────────────────────────────────────────────────────────────────────────────────┤
│ PerceptionCore (NEW leaf target — types only, no deps)                         │
│  Point<AXSpace|FrameSpace|EventSpace|WebViewportSpace> (phantom-typed)         │
│  AXMatchScore (raw 0..3) / Confidence (0..1) — distinct types, one explicit    │
│    .normalized() — the 34c2efa units-bug class becomes a compile error        │
│  AppTarget {pid, bundleID, windowHint} — pinned per subtask                    │
│  GroundingCandidate / GroundingVerdict / StableAXSnapshot                      │
│  ActionDescriptor + ActionRisk (migrated leaf-ward; ProviderKit typealias)     │
│  StateSignatureProvider · VerificationOracle · PerceptionSource protocols      │
├────────────────────────────────────────────────────────────────────────────────┤
│ PERCEPTION LAYER — GroundingRouter LANDS IN ProviderKit (deps: PerceptionCore; │
│  SandboxKit already sees ProviderKit, AppShell can never be a shared home).    │
│  Sources are INJECTED PerceptionSources: AppShell wires native AX/OCR/visual,  │
│  SandboxKit wires DOM. Extracting the live-walked MixtureGrounder routing is   │
│  the b40ede8 class → it ships SHADOW-FIRST with parity rows (kernel discipline,│
│  not just a flag) before it routes anything.                                   │
│  GroundingRouter (evolves MixtureGrounder.groundResult):                       │
│   ① AnchorMemorySource   recorder-learned verified anchors (NEW, flagged)     │
│   ② AXCandidateSource    pid-pinned, multi-sample keep-richest BUILT-IN       │
│                          (27a6fc8), off-main (b40ede8), actionable roles only │
│   ③ OCRSoMSource         Vision recognizeBoxes; gated on axRichness (b09194f) │
│   ④ SyntheticAXSource    Screen2AX nodes flagged .synthetic (e64f9fa)         │
│   ⑤ VisualGrounderSource UI-TARS/ElementLocator — FIVE audited reasons only   │
│                          (5d06d63); crop-first refine (6e75b1a, SEQ-03)       │
│  GroundingVerifier: corroboration ACCEPTS (517699f); advisory-to-audit;       │
│  hard gate only on high ActionRisk. Every route → grounding.route audit row.  │
├──────────────┬──────────────────┬───────────────────┬──────────────────────────┤
│ ProviderKit  │ ComputerUseKit   │ SandboxKit        │ AgentOrchestrator        │
│  ComputerUse-│  NativeCU-       │  BackgroundWeb-   │  NEW EpisodeReliability- │
│  Agent       │  Actuator        │  Agent            │   Kernel (shadow-first)  │
│  (.coordinate│  AXElement-      │  WebDOMGrounder   │  NEW FailureLedger       │
│  Sonnet dflt,│  Resolver        │  (= DOM face of   │   (audit → metrics)      │
│  .structural │  NEW PostAction- │   GroundingRouter)│  NEW RunEvidenceBundle   │
│  when proven)│  Verifier ladder │  WebStateSignature│  AgentFailureKind        │
│  ScoutAgent  │  GuidanceOverlay │  AgentTaskPlanner │  AgentRecoveryPolicy     │
│  (OFF, 8     │  InputSafety ·   │                   │  AgentTraceRecorder      │
│   gates)     │  AppSkill        │                   │  RecipeReplayRunner      │
│  NEW Model-  │                  │                   │   (extracted, SEQ-25/29) │
│  Transport + │                  │                   │                          │
│  SideEffect- │                  │                   │                          │
│  Fence       │                  │                   │                          │
├──────────────┴──────────────────┴───────────────────┴──────────────────────────┤
│ MacContextKit (recorder spine)          │ WasteDetection                       │
│  SCStream 1fps → gridHashes → dedup →   │  SessionSegmenter-first mining       │
│  PolicyEnforcer.evaluateCapture →       │  PrefixSpan + TypedActionAbstractor  │
│  FrameRedactor (HOT-PATH WIRED) →       │  WorkflowCurator (index-picks only,  │
│  AX-text-primary + gated OCR → store    │   010e3d0)                           │
├─────────────────────────────────────────┴───────────────────────────────────────┤
│ GovernanceKit (NEW target; deps: CascadeMemory + PerceptionCore)                │
│  TenantPolicy (MDM managed-prefs) · PolicyEnforcer (ONE choke point for        │
│  capture + actuation) · SIEMExporter (OTel GenAI semconv) · LegalHold ·        │
│  KeyCustodian (SQLCipher key lifecycle, Keychain + LocalAuth)                  │
│  Package.swift rule: everything that captures or actuates (MacContextKit,     │
│  ComputerUseKit, SandboxKit, AppShell) depends on GovernanceKit. It speaks    │
│  PerceptionCore's ActionDescriptor/ActionRisk, never CUAction — so no         │
│  ProviderKit cycle; policy is structural (LAW 1).                              │
├──────────────────────────────────────────────────────────────────────────────────┤
│ CascadeMemory (the root of trust)                                               │
│  CascadeStore → ENCRYPTED AT REST (SQLCipher; closes open wound #5)            │
│  AuditChain (hash chain, fail-closed aee4a7b) · AuditIdentity · PIIDetector    │
│  NEW perception_anchor table · SemanticIndex · RankFusion · AgentTraceStore    │
└──────────────────────────────────────────────────────────────────────────────────┘
   GroundingBench / grounding-bench CLI — the offline gate for ANY grounding change
```

### 3.3 The seams (contracts everything hangs off)

```swift
// PerceptionCore — the one perception contract
public struct AppTarget: Sendable { let pid: pid_t; let bundleID: String; let windowHint: String? }

public struct GroundingCandidate: Sendable {
  let point: Point<FrameSpace>; let rect: Rect<FrameSpace>?
  let role: String?; let label: String?; let targetText: String
  let source: GroundingSource          // .anchor, .ax, .ocr, .syntheticAX, .visual, .dom
  let confidence: Confidence           // typed 0..1; AXMatchScore normalized at the boundary
  let evidence: [Evidence]             // roleMatch, labelExact, ocrOverlap, sourceAgreement…
}
public struct GroundingVerdict: Sendable {
  let selected: GroundingCandidate?; let candidates: [GroundingCandidate]
  let reason: RouteReason              // axHit, anchorHit, canvas, ownUI, axUnreliable, sparse, stale
}
public protocol PerceptionSource: Sendable {
  func candidates(for target: TargetQuery, in snapshot: PerceptionSnapshot) async -> [GroundingCandidate]
}
public protocol StateSignatureProvider {      // HP-2's final form, one protocol
  func signature() async -> StateSignature    // gridHashes (screen) / URL+title+text (web)
  func settleRecheck(after: Duration) async -> Bool   // the 400ms slow-render re-check (336263d)
}
public struct ActionDescriptor: Sendable { /* kind, target, app — leaf-safe */ }
// CUAction (ProviderKit) maps to ActionDescriptor ONCE at the boundary; leaf
// targets never import ProviderKit. ActionRisk lives here (typealias shim back).
public protocol VerificationOracle: Sendable {        // per-surface verify ladder
  func verify(action: ActionDescriptor, before: FrameRef, after: FrameRef,
              expectation: PredictedEffect?) async -> VerifyOutcome  // effect / noEffect / unclear
}
// ProviderKit — one transport policy under EVERY model call (closes open wound #2)
public protocol ModelTransporting {
  func send(_ req: ModelRequest, fence: SideEffectFence) async throws -> ModelStream
}
// GovernanceKit — policy is code, not prose
public enum PolicyVerdict {   // redact rects are SPACE-TYPED: a mis-spaced rect = raw PII persisted
  case allow, redact(regions: [Rect<FrameSpace>]), drop(reason: String), pause(reason: String)
}
public protocol PolicyEnforcing {
  func evaluateCapture(_ ctx: CaptureContext) -> PolicyVerdict     // RewindEngine calls
  func evaluateAction(_ a: ActionDescriptor, risk: ActionRisk) -> PolicyVerdict  // executeCU maps CUAction at the callsite
}
// AgentOrchestrator — the AgentDriver seam (cua-style): LocalMacDriver / WebSandboxDriver /
// ReplayFixtureDriver, so eval runs headless in CI without Screen Recording TCC.
```

**Compat discipline:** `MixtureGrounder.ground()` keeps returning `CGPoint?` by unwrapping the verdict — every existing callsite compiles unchanged; the router lands behind `cascade.perceptionRouter`. All new capability: default-OFF flag, byte-identical OFF-path, exercised ON-path test (the `1b5dec2` no-op-flag shape is banned).

**Threading contract, stated in types and comments:** all AX IPC on a dedicated off-main executor with the `Task.detached` hop preserved inside the source (documented contract, uncleanable by future audits — `b40ede8`); TIS/Carbon main-thread only (`ee9f72d`, `4001912`).

---

## 4. THE CORE WORKFLOWS

### 4a. The on-screen CU loop — perceive → ground → act → verify, with the reliability harness

```
voice/hotkey → runAssistTask(goal)
  VoiceFragmentGate + en-locked transcription                     [HP-6: c4138b4, b29cd4c]
  PolicyEnforcer: app in scope? permissions preflight? STOP clear? [LAW 8: 85f945a]
  AgentTaskPlanner → ≤N subtasks; AppTarget PINNED per subtask; app pre-opened
  TrajectorySketch push if a close successful local trace exists   [LAW 4 push; SEQ-02]
  per subtask, per turn:

 PERCEIVE  PerceptionSnapshot: pid-pinned AX, multi-sample keep-richest (≥2 samples,
    │      constructor-enforced — no callsite can forget it, 27a6fc8), off-main
    │      (b40ede8); recorder frame + gridHashes cached; axRichness gate → OCR-SoM
    │      only when sparse (b09194f). AppTarget pinning makes Cascade-as-target
    │      RARE, not impossible (pre-open races, frontmost churn, tasks about
    │      Cascade's own UI) — the self-guard (660af3c) STAYS a runtime branch
    │      that degrades to the visual grounder, never an assertion (LAW 7).
 PLAN      Sonnet native-CU SSE stream via ModelTransport
    │       ├─ transient pre-action error → jittered retry ≤2      [closes wound #2, d5dda7a]
    │       └─ first executed action arms SideEffectFence → salvage-only, NEVER retry
    │          after an executed action (0c98387 is load-bearing)
 GATE      structural refusals BEFORE actuation — all code, no prompts (LAW 1):
    │      paste gate · irreversible-combo gate (188d1a6) · watched-app scripting
    │      denial (a066e09) · SecureInputGuard · STOP/health · PolicyEnforcer ·
    │      ActionRisk pre-action verify (high-risk only, HP-9) — risk classed
    │      STRUCTURALLY from action kind + target, never model-emitted (152df62);
    │      OFF until the classifier proves fail-closed live (§6 gate)
 GROUND    (.structural — computer tool WITHHELD, be9cdec) named target →
    │      GroundingRouter ladder (§4d); verdict + reason → grounding.route row
    │      (.coordinate — the forever-fallback) model pixels pass through;
    │      verdict row still written for the ledger
 ACT       NativeComputerUseActuator; Point<FrameSpace>→Point<EventSpace> exactly
    │      once, inside the actuator; semantic AXPress preferred (a89f9c6);
    │      safeBatchPrefix idempotency truncation (7773679); batch>1 re-grounds
    │      the remainder against the post-action frame (tightens 86ae0e0)
 VERIFY    PostActionVerifier ladder (cheapest first, LAW 8):
    │       (0) structural predicted-effect exemption — never model-self-reported (152df62)
    │       (1) mechanism: AX value read-back for typing (.success REQUIRES match,
    │           abd97e6); frontmost fingerprint for app switch; file-exists for saves
    │       (2) OCR text delta on the target rect, read PRE-REDACTION in-memory
    │           (never persisted — the §7 carve-out): recorder OCR when a frame
    │           lands inside the verify window, else bounded on-demand Vision on
    │           the rect. Zero MODEL calls, but not "free" — recorder OCR is
    │           AX-richness-gated (b09194f) and 1fps/async can lag the window
    │           (HP-12 cost honesty)
    │       (3) image diff last; ambiguous = "unclear", NEVER "failed" (85f945a)
    │      → assist.verify.* audit rows (these rows ARE the metrics feed)
    │      confirmed effect → perception_anchor upsert (+verified_count)   [§4d]
 ACCOUNT   no-effect: gridHashes diff, threshold 2, 400ms settle re-check (336263d);
    │      noEffectTurns SEPARATE from idleTurns (0451679); signature-based
    │      repetition counting (8aaea59); harness/recall work counts as activity
    │      (1d795db — "did the agent act" includes invisible lanes)
 RECOVER   noEffect≥2 → NoEffectVerifier once → flail-moment PUSH of AX
    │      interactables() labels or OCR-SoM into the nudge (LAW 4 — never a pull
    │      tool) → ONE Opus escalation per subgoal, min-dwell, generation-bump
    │      cancel (bfe89d6/6b98567) → fail-fast: 2 ground-misses on a zero-control
    │      view ends the subgoal (4f62dab) → .stalled
 COMPLETE  done ⇒ validator forced on multi-part/high-risk/Scout; terminated ≠
           succeeded in the outcome TYPE (98c2f2a); "done" is never ground truth
           on its own (HP-3, five recurrences)
```

All of this scaffolding lives once, in `EpisodeReliabilityKernel`, consumed by the assist, Scout, and web lanes — shipped shadow-first (§3.1).

### 4b. Record → memory → suggestion → agent → approve → run → audit → learn

```
RECORD    SCStream ~1fps → RewindStreamOutput (off-main): gridHashes → dedup
   │      (visual AND textDigest stability, SEQ-19)
   │      → PolicyEnforcer.evaluateCapture:
   │          .redact → FrameRedactor blurs Vision recognizeBoxes PII regions
   │                    BEFORE FrameStore.save — raw pixels never touch disk;
   │                    verify rung 2 reads the PRE-redaction OCR in-memory, so
   │                    redaction changes what PERSISTS, never what verify sees
   │          .drop   → nothing persists (private mode stays FAIL-CLOSED frame
   │                    drop, dab9e5c named regression test)
   │      → AX text primary, OCR appended, OCR gated on AX richness (db068ef, b09194f)
   │      → redaction BEFORE FTS/embedding — raw PII never embedded (SEQ-07)
MEMORY    CascadeStore (SQLCipher envelope: DB/WAL/FTS/embeddings/frames) ·
   │      retention honors TenantPolicy classes + LegalHold · typed text stays
   │      char-count-only (e41442f) · recall = FTS + semantic fused by RRF,
   │      never a fallback chain (aa2d391) · line-level redaction, never a
   │      kill-switch blanking the spine (14c90a6)
MINE      SessionSegmenter episodes FIRST, then PrefixSpan/TypedActionAbstractor
   │      within episodes (SEQ-08; literal-token core stays dead, 93ae884);
   │      minSupport=2 recall / promote at 3; delimiters never shared across
   │      grammars (dab9e5c); structural gate: ≥2 structural actions + intent
   │      marker — typing can't become a workflow (LAW 7)
PROPOSE   WorkflowCurator (haiku/Groq text tier, LAW 5) names/explains/rejects an
   │      index-picked shortlist ONLY — grounded-by-construction, can't invent
   │      (010e3d0). Cascades tab card = rewind thumbnail + WHEN-DEPLOYED preview
   │      + provenance line ("seen 4×, last Tue 14:02") — the evidence moat (SEQ-10)
APPROVE   human approves; audit actor "employee"; declines persist. Web workflows
   │      deploy as background sandbox agents; native as on-screen.
RUN       supervised run per §4a / §4c; every action + verdict → audit_event
   │      (hash-chained, PII-redacted on append, hashes in audit rows NEVER in
   │      model-facing prompts — dab9e5c)
AUDIT     RunEvidenceBundle per run: trace JSON + audit-chain proof segment +
   │      thumbnails-by-id + redaction manifest + ReliabilityReport (failure
   │      taxonomy, verifier outcomes, cost ledger) → Manager drill-in + SIEM
   │      export. "Reclaimed" counts genuine successes only (98c2f2a).
LEARN     three feedback edges, all review- or verification-gated:
          · verified effects → perception_anchor upserts (§4d) — grounding gets
            better with every confirmed click, human or agent
          · episodeAppActions tally → sonnet drafts SKILL.md → HUMAN REVIEW in
            Cascades → Skills/learned-<slug>/SKILL.md (pushed for weak planners,
            pull for strong — LAW 4/d009615)
          · replay repairs → healed_anchors, persisted ONLY after uiChanged
            confirms effect (SEQ-29, LAW 3 in miniature); recipe.drift audited
```

**Replay** (extracted `RecipeReplayRunner`, headless-testable, SEQ-25): pre-flight state gate — wrong app/window is a REPLAN input, not just a pause (`ecc1b90`, SEQ-13) → per step: `AXTargetDescriptorV2` ensemble resolve (high→AXPress) → merge healed/historical anchors, retry-NEXT-candidate never stale coordinates → OCR re-ground → crop-first vision → pause. B5's honest limit (literal replay would retype stale values) stays declared until typed-action slot induction fully lands (`3d26f96`, wound #8).

### 4c. The background web agent

```
createSandboxAgent(task) → BackgroundWebAgent → WebSandbox (WKWebView, persistent
data store = reuses sign-ins; one floating panel per agent)
  brain: Scout when Groq key present — a PROVISIONAL default (the 2026-06-24
         flip is RUNTIME-UNVERIFIED end-to-end); confirmed or reverted by its
         §6 gate, never by assertion (LAW 5). Sonnet opt-out path retained
  ground: WebDOMGrounder — DOM-first is the web analog of LAW 2 (c901690);
          implements PerceptionSource, so the web lane is the DOM face of the ONE
          GroundingRouter; UI-TARS snapshot fallback only with a key
  loop:   same EpisodeReliabilityKernel, injected with WebStateSignature
          (URL + title + first 4000 chars — immune to pixel churn, 8bca67b/b735d4c)
          + proactive Set-of-Marks PUSH every turn (weak planner → push, LAW 4)
  verify: page-grounded completion verifier biased toward trusting real wins
          (d553918); NEEDS_LOGIN / INCOMPLETE pause-resume protocol; login gated
          on cookie-hydration OUTCOME, never landed-URL heuristics (4a51353)
  safety: PolicyEnforcer domain allow-deny; STOP-gated harness; 25-step cap;
          per-episode fence identical to on-screen
  add:    drag_target for both surfaces (grounds both endpoints, SEQ-03/21)
```

### 4d. The grounding stack — AX-first → OCR/SoM → visual, preconditions structural

The routing ladder, per named target (all zero-model-call rungs first):

```
target "Reply button"
 ① AnchorMemorySource   descriptor-hash hit? → resolve AXTargetDescriptorV2
 │                      ensemble live; high agreement → candidate conf 0.97,
 │                      source .anchor                            [0 model calls]
 ② AXCandidateSource    pid-pinned StableAXSnapshot (multi-sample keep-richest —
 │                      the 270→7 flicker instant can never be the decision
 │                      input, 27a6fc8); actionable roles only; scored in
 │                      AXMatchScore units, threshold in the SAME units by
 │                      construction (34c2efa dies at compile time); on-display
 │                      only; widened label normalization (b117a3e) [0 model calls]
 ③ corroboration        anchor ∧ AX agree → confidence BOOST, ACCEPT — never
 │                      abstain-on-agreement (517699f)
 ④ OCRSoMSource         canvas TEXT / literal text / axUnreliable apps / sparse
 │                      AX → Apple Vision boxes (ecb792d, ac1238f); Keynote's
 │                      canvas is provably AX-blind (9d85fdb). OCR covers canvas
 │                      TEXT ONLY — shapes/sliders/image wells fall through to
 │                      ⑤, the honest vision residual (LAW 7)   [0 model calls]
 ⑤ VisualGrounderSource crop-first (from anchor frameBucket or router heuristic;
 │                      ScreenSpot-Pro 26.8→56.5% with 2-step zoom, SEQ-03/21)
 │                      → full-frame UI-TARS/ElementLocator; ONLY via the five
 │                      audited reasons (canvas/own-UI/axUnreliable/sparse/stale,
 │                      5d06d63); transport retry MANDATORY on this call (d5095c0,
 │                      d5dda7a); synthetic/visual nodes flagged, never
 │                      masquerading as native (e64f9fa)          [1 grounder call]
 ⑥ verdict              GroundingVerifier: bare confident visual point TRUSTED for
                        visual-source candidates (4616f23); disagreement → trust
                        order; reject/abstain → ONE re-describe nudge → risk-gated
                        pause. Every route decision → grounding.route audit row;
                        the live AX%/anchor%/OCR%/vision% share is the moat's
                        dashboard number.
```

**The structural fixes designed in, not patched on:**
- **Frontmost/flicker family killed at the root:** `AppTarget` resolved once per subtask; all AX reads go to `AXUIElementCreateApplication(pid)` — frontmost churn, own-UI collisions, and overlay animations stop mattering by construction.
- **Coordinate spaces:** four spaces exist (AX global top-left, CGEvent, 1920px-capped frame, WKWebView bottom-left). Phantom-typed `Point<Space>` + one `CoordinateTransform` (evolving `4be93a4`–`f2e33c8` + `DisplayCoordinateMapper`) is the only crossing; conversion happens exactly once, inside the actuator.
- **The recorder as grounding prior (the un-copyable moat):** every verified effect — agent click confirmed by the verify ladder, or a HUMAN click already captured by `InputRecorder` with its AX label — upserts `perception_anchor` (bundle_id, target-text hash, V2 descriptor ensemble, source, verified_count). The user's ordinary workday continuously trains Cascade's anchor map for free. Recall short-circuits everything including UI-TARS at zero model calls; on dense pro apps and non-text canvas a remembered `frameBucket` drives crop-first vision. Verification rungs 2–3 diff signals the recorder pipeline already computes (pre-redaction, in-window — §4a) — a pure-vision competitor pays a model round-trip for both grounding and verification on every action; Cascade pays zero MODEL calls on the common path (`a18ea8f`, `0451679`).

---

## 5. MODEL + COST STRATEGY

Per-surface, capability-constrained, decided only by live audit (LAW 5). Frozen until the FailureLedger says otherwise:

| Surface | Model | Ledger basis |
|---|---|---|
| On-screen CU planner+actor | **Sonnet, native CU (`computer-use-2025-11-24`), DEFAULT** | 7–9s/subgoal, one turn, fraction of Opus cost — live-audited flip (`90336e4`) |
| Escalation ceiling | **Opus, ONE per subgoal**, min-dwell, generation-bump cancel | `bfe89d6`/`6b98567`; bounded escalation, never a router |
| CU anywhere | **Haiku BANNED** — no CU beta exists | graveyard #14 (`0c98387`, `a8f625f`) |
| Structural (withheld-tool) mode | Dedicated grounder + planner — live-proven on OPUS only (`be9cdec` bring-up, Jun-23 Keynote A/B); Sonnet-structural is UNPROVEN (`90336e4` was coordinate mode) → the Phase-4 A/B holds the model CONSTANT across arms; coordinate fallback whenever no grounder configured — the proven path always runs | `be9cdec`; current `makeAssistAgent` guard |
| Background web CU brain | Scout (Groq) when key present — PROVISIONAL, runtime-unverified since the 2026-06-24 flip; Sonnet opt-out retained; confirm-or-revert gate in §6 | LAW 5; flip note 2026-06-24 |
| Visual grounder | AX (free) → hosted UI-TARS-1.5-7B → ElementLocator; UI-Venus self-host deferred | `7773679`, `ea66298` |
| Text-only validate/curate/plan-notes | Haiku / Groq — fine and cheap | `198a0b7`, `c551011`, `d553918` |
| Cheap-tier play (if ever) | brain/grounder split — weak model NAMES, grounder produces coordinates, weak model never emits pixels | `e514d94`; Groq has exactly one vision model (`a0841e4`) |
| Two-tier router / Scout on-screen | **stays OFF** behind the 8 go/no-go gates; baseline to beat = Sonnet native-CU | `00c2fc2` |

**No cheap-tier on the CU loop.** HP-7's lesson: cheap-model "unreliability" was transport + parity, not intelligence — and cheaper-per-turn was 2× slower end-to-end (`0451679`). The verdicts flip only by measurement.

**The safe cost levers (all proven, all kept):**
- Screenshot history cap 8→3 ≈ 7× cheaper/task (`1975ecb`); fixed image window, text summaries retained (SEQ-02).
- Prompt caching: byte-stable prefix (policy + tool defs) split from dynamic context; 3 moving breakpoints (SEQ-05).
- Real model-call cache — never fake discarded work (`1b5dec2` is the banned shape).
- OCR gated on AX richness (`b09194f`); no work a keyless consumer ignores (`4a626ed`).
- Transport retry on EVERY call — connection reliability is a hidden cost of cheap hosts (`d5dda7a`); structural API limits (>20 strict tools = silent 400 `d0a8aca`; `thinking:adaptive`+effort = hang `72a8221`) surfaced as diagnosis, never retried as "network flake".
- Streaming with never-retry-after-executed-action (`0c98387`) — duplicated actions are worse than a dead turn.

---

## 6. RELIABILITY + EVAL — the closed loop that keeps the failure rate down

The failure rate is one number, and this loop owns it:

```
MEASURE   FailureLedger (new, AgentOrchestrator): nightly + on-demand derivation
   │      from audit_event via AgentFailureKind.init?(auditAction:detail:) →
   │      per-surface metrics JSON: episode failure rate (terminated vs succeeded
   │      SPLIT, 98c2f2a), no-effect rate, grounding source shares (ax/anchor/
   │      ocr/visual/fallback), verifier accept/reject/abstain (a 0-accept or
   │      100%-abstain gate SCREAMS here instead of hiding for days, HP-9),
   │      transport retries, turn latency, escalations, cost.
WIRE      wiring smoke (HP-8 antidote): every flag-ON module must emit ≥1 audit
   │      row in a scripted live run or the ledger flags it DORMANT — green tests
   │      never again mean wired (e6e5275: 37 dormant modules).
BENCH     GroundingBench CLI vs ScreenSpot-v2/Pro + private macOS set = the
   │      offline pre-gate for ANY grounding change; d21 ablation
   │      (hybrid_failure_rate) + d14 live trio EXECUTED (open wound #3 closed) —
   │      the AX-first quantitative claim gets its number, or the roadmap re-plans.
   │      ReplayFixtureDriver runs scenario fixtures headless in CI, no TCC needed.
HARDEN    the harness itself (all structural, §4a): no-effect + settle re-check ·
   │      tiered stall guard · signature repetition · SideEffectFence transport
   │      policy (transient-retry pre-action only) · PostActionVerifier ladder ·
   │      anti-oscillation · fail-fast bails · forced completion validator.
GATE      one PR per change off a pinned base (0bf61d2); default-OFF flag,
   │      flag-off byte-identical; scripted live-run suite → new ledger snapshot
   │      → DIFF vs baseline attached to the PR; regression on failure-rate /
   │      no-effect / verifier-accept BLOCKS the flip. Named regression fixtures
   │      for every HP-9/HP-10 scar (0-accept verifier, 100%-abstain, units
   │      mismatch, redact-only private mode, no-op ON-path).
REVERT    whole stacks, cleanly; salvage sound pieces later (de2e427 → 1e2dc14).
   │      Never tune a heuristic against an unobserved failure — instrument every
   │      exit and no-op first (3a485c6, 1878893).
```

Go/no-go gates for the pending default flips (no default changes on green builds — LAW 3):

| Flip | Gate |
|---|---|
| `.structural` grounding default | d21 `hybrid_failure_rate` + d14 live trio executed; structural ≤ coordinate failure rate on bench + 10 live tasks, SAME model both arms (no model/mode confound) |
| GroundingVerifier ON | live accept-rate sane (not 0/24, not 100% abstain — named fixtures) |
| GroundingRouter authoritative | shadow-parity rows vs MixtureGrounder: zero route divergence over N live runs (`b40ede8` class) |
| High-risk hard gate ON | ActionRisk classifier is structural (action-kind/target, never model-emitted `152df62`); induced-fault live runs prove fail-CLOSED |
| Web-lane Scout default (confirm or revert) | N live background runs ledger'd; Scout failure rate ≤ Sonnet on the same task set |
| EpisodeReliabilityKernel authoritative | N live runs, zero `kernel.shadow.diverged` rows |
| FrameRedactor hot-path ON | 48h soak: 0 raw-PII frames (sampled OCR audit); recorder CPU delta <15%; verify rung-2 PARITY (pre-redaction read path — 0 verify regressions) |
| SQLCipher ON | round-trip migration on a real 5GB store; rewind/FTS/Ask latency within 20%; key-loss recovery tested |
| auditIntegrityEnforcement ON | 1-week soak, zero false chain breaks |
| Two-tier router ON | the existing 8 gates + A/B ≥ Sonnet-baseline accuracy; RiskyActionGate proven fail-closed |
| AnchorMemory read path ON | live descriptor-resolve precision on this Mac from the write-path data |

---

## 7. ENTERPRISE SPINE

Privacy, audit, and governance are the product's trust boundary. This track shares exactly ONE seam with the CU loop — the recorder's persisted output feeds verify rung 2 — so that seam is constructed, not asserted: verify reads pre-redaction in-memory OCR (§4a) and the FrameRedactor gate includes verify parity (§6). Everything else here is loop-orthogonal and runs in parallel without floor risk (LAW 6).

- **Encryption at rest (closes open wound #5, the named biggest blocker):** SQLCipher envelope over DB/WAL/FTS/embeddings; frame JPEGs move inside the encrypted envelope (or an encrypted blob store) so no plaintext sidecar survives. `KeyCustodian` owns key lifecycle via Keychain + LocalAuthentication; one-time `sqlcipher_export` migration; key-loss recovery a tested path before the flip.
- **Redaction before persistence:** `FrameRedactor` hot-path wired — Vision `recognizeBoxes` → PII entities → region blur BEFORE `FrameStore.save`; redaction before FTS/embedding (raw PII never embedded, SEQ-07). Redaction rects are `Rect<FrameSpace>`-typed (a mis-spaced rect = raw PII persisted — the `34c2efa` class, killed the same way). The CU carve-out: post-action verify reads the PRE-redaction OCR in-memory only, never persisted — redaction and TenantPolicy DLP classes narrow what the STORE keeps, never what verify sees. Private mode = fail-closed frame DROP (`dab9e5c` named test). Typed text audited as char-count only (`e41442f`); credential paths refused (`ea25b81`).
- **Audit chain:** `audit_event` stays the immutable hash-chained ledger (`aee4a7b`, fail-closed verification) with out-of-band Keychain anchor; PII redacted on append; hashes live in audit rows, NEVER in model-facing prompts (`dab9e5c`). `cascade.auditIntegrityEnforcement` flips ON after soak: agent actions refuse on a broken chain. Trace layer (`AgentTraceRecorder`) references audit row ids, never embeds raw OCR/screenshots (SEQ-14; round-5 leak fix is a regression test).
- **Permissions + STOP:** prompt-once, preflight-polled, fail-closed permissions (`85f945a`); STOP + health gates on every actuation; STOP must never be blockable by a hung AX call (the off-main contract, `b40ede8`). PolicyEnforcer is the single choke point for capture AND action — app/domain allow-deny, DLP classes, retention by data class from MDM `TenantPolicy` managed prefs; no policy loaded → built-in fail-closed default.
- **Evidence + SIEM:** `RunEvidenceBundle` per run (trace JSON, audit-chain proof segment, thumbnails-by-id, redaction manifest, ReliabilityReport) surfaced in Manager and exported via `SIEMExporter` (OTel GenAI semconv naming; webhook/CLI/JSON schema). `LegalHold` pins rows against retention prune.
- **Deployment/compliance:** signed + notarized package, Jamf/Intune profiles, TCC preflight docs; CI made green for the first time by pinning the runner toolchain to local Swift 6.3 (open wound #7 — enterprise buyers will ask); SOC 2 readiness rides on the above artifacts. Phase-4 platform (SSO/SAML + SCIM, tenancy, admin console) is a **policy-and-identity plane only** — work context never leaves the Mac; the server distributes TenantPolicy and receives only SIEM-exported hashes/counts/ids.

---

## 8. SEQUENCED ROADMAP FROM TODAY'S MAIN

One isolated PR per step off a pinned base (`0bf61d2` discipline); every phase shippable, measurable, and revertible as a whole stack. **Default-OFF register and isolation rules follow the phase list.**

**Phase 0 — Measure the wall (≈1–3 wks, near-zero product code, QUOTA-BOUND).**
Model quota is the proven velocity ceiling (wound #10: sweeps repeatedly halted; the SEQ walk has cleared 7 items since it started) — so Phase 0 is evidence-PRIORITIZED, not everything-at-once: (1) d21 ablation (`hybrid_failure_rate`), (2) d14 live trio, (3) `FailureLedger` derivation + wiring smoke, (4) pin the CI toolchain → first green main (wound #7). The SEQ walk (seq-08→31) continues opportunistically on leftover quota — it is NOT a Phase-0 blocker. Degraded-evidence protocol: a quota-halted sweep ships at the evidence tier reached with verdicts marked PROVISIONAL, never claimed live-verified; default flips WAIT for quota rather than run on thin ledgers (LAW 3).
*Ship/measure:* baseline ledger JSON; every subsequent phase diffs against it.

**Phase 1 — Kill the whole-turn killers (flags: `cascade.transportPolicy`, `cascade.postActionVerifier`).**
`ModelTransport` + `SideEffectFence` (closes wound #2; acceptance = induced-fault live runs showing retry rows pre-action and salvage-only post-action). `PostActionVerifier` ladder + `assist.verify.*` rows — HP-3's five recurrences get one mechanized answer, and the ledger gets its richest feed. Instrument the rewind-chat hang's blocking path (wound #1): timing/audit rows on every exit — observation only, no fix before the cause is seen (`1878893`, graveyard #12).
*Parallel enterprise track begins (loop-orthogonal):* GovernanceKit skeleton (TenantPolicy decode, PolicyEnforcer choke points with today's behavior as default policy, SIEMExporter over existing TraceExport), SQLCipher + KeyCustodian behind its gate, FrameRedactor hot-path behind its gate, notarized packaging.
*Measure:* transport-retry saves/run; verify-verdict distribution; redactor soak; SQLCipher latency delta.

**Phase 2 — One perception contract (flags: `cascade.perceptionSnapshot`, then `cascade.perceptionRouter`).**
PR-2a: `PerceptionCore` leaf target — phantom-typed points/scores, Candidate/Verdict, compat wrappers; byte-identical behavior; the `34c2efa` and coordinate-space bug classes die at compile time. PR-2a also lands the `ActionRisk`→PerceptionCore migration (typealias shim, callsites compile unchanged) + `ActionDescriptor`. PR-2b: `AppTarget` pinning + constructor-enforced multi-sample snapshot inside `axGround`/`ScreenElementIndex` (flicker `27a6fc8` becomes structural; the `660af3c` self-guard BRANCH is kept — pinning shrinks the case, LAW 7 keeps the graceful path). PR-2c: GroundingRouter lands in ProviderKit with injected sources, SHADOW-parity vs MixtureGrounder before it routes (`b40ede8` discipline, §6 gate); WebDOMGrounder conforms.
*Measure:* AX-hit share + flicker-class misses in `grounding.route` vs Phase-0; verifier accept-rate fixtures.

**Phase 3 — Kernel + anchors (flags: `cascade.reliabilityKernel` shadow → per-lane authoritative; anchor write = additive default-empty hook; `cascade.anchorRecall` for reads).**
`EpisodeReliabilityKernel` in SHADOW MODE across assist/Scout/web; flip per-lane only on zero-divergence live runs (`b40ede8` discipline). `perception_anchor` write path (human clicks + verified agent clicks — pure data collection); read source ON only after live precision data. `RecipeReplayRunner` extraction + V2 descriptors + healed_anchors (SEQ-25/29 modules exist default-OFF).
*Measure:* kernel divergence rows = 0; anchor precision; replay AX-resolved share; `recipe.heal` success rate.

**Phase 4 — Flip the proven moat (ledger-gated flips only).**
`.structural` grounding default (gated on Phase-0/2 numbers, model held constant across arms); GroundingVerifier ON; high-risk hard gate ON only after its fail-closed proof; web-lane Scout default confirmed or reverted by its gate; crop-first refine + `drag_target` on both surfaces; auditIntegrityEnforcement ON; trace assembly ON; RunEvidenceBundle + Manager drill-in + Compliance tab. Canvas iteration continues by ledger evidence: OCR-SoM covers canvas text; non-text canvas rides anchor-frameBucket crop-first vision; UI-Venus self-host ONLY if the ledger shows canvas dominating residual failures (`ea66298`).
*Measure:* structural vs coordinate failure rate live; verifier accept/abstain sanity; canvas residual share.

**Phase 5 — Decompose for scale + platform (last, additively).**
`AgentRuntime` extraction of episode runners/coordinator out of `CascadeAppModel` — one seam per PR, live-parity-verified (graveyard #11 is the warning). Typed-action slot induction completes parameterized replay (wound #8). Two-tier router through its 8 gates (baseline to beat: Sonnet native-CU). Event-driven capture + video segments behind the battery gate. Phase-4-style enterprise platform (SSO/SCIM/admin) as policy-and-identity plane only.

**What stays default-OFF (the register):** `tierRouter.*` / `scoutPlanner.*` (8 gates), `guardIrreversibleActions` (until ledger-gated), `assistValidator` (force-trigger stays), `experimentalGroundingVerifier` → ON only via its gate, `experimentalGroundingCache`, `experimentalEpisodeMining` and the rest of the experimental register, plus every NEW flag above — each with an exercised ON-path test and byte-identical OFF-path.

**How experiments stay isolated so they can't degrade the floor:** (1) one flag per capability, OFF-path byte-identical, ON-path exercised — no `1b5dec2` no-op shapes; (2) one PR per seam off a pinned base — no crossed stacks (`dab9e5c`); (3) shadow mode for any extraction of live-walked code (`b40ede8`); (4) the FailureLedger diff attached to every flip PR, regression blocks; (5) the wiring smoke catches dormant modules (`e6e5275`); (6) reverts are whole-stack, salvage later (`de2e427`); (7) the enterprise track touches only CascadeMemory/MacContextKit/GovernanceKit, with its ONE CU-adjacent seam (redaction vs verify rung 2) carved out in §4a/§7 and gated on verify parity — everywhere else it cannot move the failure rate.

---

**The contract, restated:** grounding is the wall and AX-first is the answer — but only structurally (withheld tools, pinned targets, typed scales, stability-sampled snapshots, off-main IPC, value read-back), only verified by live audit rows, with the recorder feeding both the cheapest grounding candidates and the cheapest verification signals, every model verdict earned per-surface by measurement, every experiment isolated behind byte-identical default-OFF flags, and the enterprise spine — encryption, redaction, audit chain, policy, STOP — running as code the model can never talk its way around.

**Rejected critiques (2026-07-04 adversarial review):** none rejected outright — all 13 defects were valid and are fixed above. Two were accepted only in part: (#7) the moat's cost claim was always about MODEL round-trips — on-device Vision OCR stays zero-model-call, so the claim survives restated in those units (the "free"/latency defect is fixed); (#11) "no new mechanism for non-text canvas" is half-wrong — anchor-`frameBucket` crop-first vision (rung ⑤, §4d) is that mechanism — but the "④ OCR is the canvas tier" wording overstated coverage and is corrected to canvas TEXT only.
