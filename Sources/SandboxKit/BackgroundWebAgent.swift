import Foundation
import ProviderKit

/// Runs a job entirely inside a `WebSandbox` — the isolated, background browser —
/// using Claude's Computer Use vision loop, but routing every action to the sandbox
/// (JavaScript) instead of the user's real screen. The user can keep working; the
/// agent's progress streams out as snapshots + status.
///
/// Multi-part jobs ("find X on site A, then use it on site B") are first split by
/// `AgentTaskPlanner` into ordered subtasks. Each part runs as its own Computer
/// Use episode with its own step budget, and every finished part hands a one-line
/// finding to the next — so facts survive screenshot pruning, one slow part can't
/// starve the rest of the job, and a login pause resumes at the pending part instead
/// of redoing everything.
@MainActor
public final class BackgroundWebAgent {
    public struct Update: Sendable {
        public let status: String
        public let snapshotPNG: Data?
        public let url: String
        public let done: Bool
        public let result: String?
        public var needsLogin: Bool = false
        /// True ONLY for a genuine, finished run — never a stop, a failure, or
        /// running out of steps. Gates the reclaimed-time accounting downstream so
        /// an aborted run is never counted (or announced) as a completion.
        public var completed: Bool = false

        public init(
            status: String, snapshotPNG: Data?, url: String, done: Bool, result: String?,
            needsLogin: Bool = false, completed: Bool = false
        ) {
            self.status = status
            self.snapshotPNG = snapshotPNG
            self.url = url
            self.done = done
            self.result = result
            self.needsLogin = needsLogin
            self.completed = completed
        }
    }

    private let keyStore: AnthropicKeyStore
    private let model: String
    private let planner: AgentTaskPlanner
    /// Cheap second opinion that checks a claimed completion against the actual page.
    private let verifier: any MessageCompleting
    private var stopped = false
    /// A mid-run correction the user typed into the watch box. Injected into the next
    /// turn as a prominent note, then cleared — the agent's "cursor for agents".
    private var pendingSteer: String?

    // The current plan. Survives a login pause so `resume()` re-enters at
    // `nextIndex` with the earlier parts' findings intact.
    private var originalTask = ""
    private var plan: [AgentSubtask] = []
    private var nextIndex = 0
    private var findings: [(task: String, result: String)] = []
    private var skipped: [AgentSubtask] = []
    /// Set once the first steer supersedes the auto-planned remainder — so later steers
    /// ADD to the queue instead of dropping the ones already queued.
    private var droppedOriginalPlanForSteer = false

    public let sandbox = WebSandbox()

    /// Fired with the page point (top-left coords) after each action the agent takes, so
    /// the watch box can fly its native cursor overlay there.
    public var onCursor: (@MainActor (CGPoint) -> Void)?

    /// Fired for every web action / tool / turn outcome (action, detail) so the run is
    /// AUDITABLE — without it the background agent was a black box (only its final
    /// `sandbox.task` row was recorded), which made misbehavior impossible to diagnose.
    public var onAudit: (@MainActor (_ action: String, _ detail: String) -> Void)?

    /// A short, stable tag identifying THIS run, prefixed onto every audited detail so
    /// concurrent background agents (up to the cap) can be told apart in the one shared
    /// audit log. Without it, parallel runs' rows interleave unattributably — exactly
    /// what made the multi-run audit window impossible to read back. Set by the owner.
    public var auditTag: String = ""

    /// Emits an audit row through `onAudit`, prefixing the run tag so the row stays
    /// attributable to this run even when several agents log into the same stream.
    private func audit(_ action: String, _ detail: String) {
        onAudit?(action, Self.taggedDetail(tag: auditTag, detail))
    }

    /// Prefixes `detail` with the run tag (pure, so the format is unit-tested).
    nonisolated static func taggedDetail(tag: String, _ detail: String) -> String {
        tag.isEmpty ? detail : "[\(tag)] \(detail)"
    }

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), model: String = AnthropicModel.sonnet) {
        self.keyStore = keyStore
        self.model = model
        // The planner only splits a job into ≤5 subtasks + picks start URLs — a
        // structurally simple task. Run it on haiku so the up-front round trip (pure
        // latency before any visible progress) is cheap; the agent loop stays on `model`.
        self.planner = AgentTaskPlanner(client: AnthropicClient(keyStore: keyStore), model: AnthropicModel.haiku)
        self.verifier = AnthropicClient(keyStore: keyStore)
    }

    public func stop() { stopped = true }

    /// Mid-run course-correction from the user (typed into the watch box). Queued and
    /// delivered to the agent on its next turn — like talking to the cursor agent.
    public func steer(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSteer = pendingSteer.map { "\($0)\n\(trimmed)" } ?? trimmed
    }

    /// Plans `task` into parts, then carries them out in the sandbox, calling
    /// `onUpdate` after each step.
    public func run(task: String, onUpdate: @escaping @MainActor (Update) -> Void) async {
        stopped = false
        originalTask = task
        nextIndex = 0
        findings = []
        skipped = []
        droppedOriginalPlanForSteer = false
        onUpdate(Update(status: "Planning…", snapshotPNG: nil, url: "", done: false, result: nil))
        plan = await planner.plan(for: task, in: .webSandbox)
        await execute(onUpdate: onUpdate)
    }

    /// Continues a paused job (e.g. after the user signed in inside the box):
    /// re-runs the pending part — now authenticated — keeping earlier findings.
    public func resume(onUpdate: @escaping @MainActor (Update) -> Void) async {
        guard !plan.isEmpty else { return }
        stopped = false
        await execute(onUpdate: onUpdate)
    }

    private func execute(onUpdate: @escaping @MainActor (Update) -> Void) async {
        episodes: while nextIndex < plan.count, !stopped {
            let sub = plan[nextIndex]
            // Feasibility triage: parts that genuinely need the Mac itself are
            // reported in the summary, never attempted blind in a browser.
            guard sub.web else {
                skipped.append(sub)
                nextIndex += 1
                continue
            }
            switch await runEpisode(sub, index: nextIndex, total: plan.count, onUpdate: onUpdate) {
            case .finished(let finding):
                findings.append((task: sub.task, result: finding))
                nextIndex += 1
            case .needsLogin(let site):
                let message = "I need you to sign in to \(site). I've opened it in the box — sign in, then press Continue."
                onUpdate(Update(status: message, snapshotPNG: await sandbox.snapshotPNG(), url: sandbox.currentURL, done: true, result: message, needsLogin: true))
                return  // nextIndex unchanged — resume() retries this part signed in
            case .stepLimit:
                let summary = AgentTaskPlanner.summary(findings: findings, skipped: skipped, ranLongOn: sub.task)
                onUpdate(Update(status: summary, snapshotPNG: await sandbox.snapshotPNG(), url: sandbox.currentURL, done: true, result: summary))
                return
            case .failed(let reason):
                onUpdate(Update(status: reason, snapshotPNG: nil, url: sandbox.currentURL, done: true, result: nil))
                return
            case .stopped:
                break episodes
            }
        }
        if stopped {
            onUpdate(Update(status: "Stopped.", snapshotPNG: nil, url: sandbox.currentURL, done: true, result: nil))
            return
        }
        // The one genuine completion: every part ran to its end without a stop,
        // failure, login wall, or step-limit. Only this counts as a reclaimed run.
        let summary = AgentTaskPlanner.summary(findings: findings, skipped: skipped, ranLongOn: nil)
        onUpdate(Update(status: summary, snapshotPNG: await sandbox.snapshotPNG(), url: sandbox.currentURL, done: true, result: summary, completed: true))
    }

    private enum EpisodeOutcome {
        case finished(String)
        case needsLogin(String)
        case stepLimit
        case stopped
        case failed(String)
    }

    /// Runs one part as its own Computer Use episode. If the model stops without
    /// taking a single action — narrating or asking instead of working — it gets
    /// one firmer retry; the second answer stands either way.
    private func runEpisode(
        _ sub: AgentSubtask, index: Int, total: Int,
        onUpdate: @escaping @MainActor (Update) -> Void
    ) async -> EpisodeOutcome {
        var attempt = await episodeOnce(sub, index: index, total: total, firmer: false, onUpdate: onUpdate)
        if case .finished = attempt.outcome, !attempt.acted, !stopped {
            attempt = await episodeOnce(sub, index: index, total: total, firmer: true, onUpdate: onUpdate)
        }
        // The model's "done" is not enough — verify the outcome against the actual page
        // before trusting it (the false-completion the user kept hitting). Only a CLEAR
        // mismatch downgrades to a failure; doubt leans verified so real wins still pass.
        if case .finished(let finding) = attempt.outcome, !stopped {
            if let reason = await verifyCompletion(task: sub.task, claimed: finding) {
                audit("sandbox.verify", "INCOMPLETE: \(reason.prefix(80))")
                return .failed("Couldn't finish — \(reason)")
            }
            audit("sandbox.verify", "verified: \(finding.prefix(70))")
        }
        return attempt.outcome
    }

    /// A cheap, page-grounded second opinion on a claimed completion. Returns an
    /// INCOMPLETE reason only when the page CLEARLY shows the task isn't done; returns
    /// nil (accept) on success, doubt, or an unavailable verifier — so it never
    /// false-fails a genuine win.
    private func verifyCompletion(task: String, claimed: String) async -> String? {
        let page = await sandbox.readPageText()
        // Can't judge a page we couldn't READ (a JS error) — accept rather than
        // false-fail a win. A short-but-readable page (a blank artifact) is exactly
        // what we DO want to catch, so it must still go to the verifier.
        if page.hasPrefix("Couldn't read") { return nil }
        let user = """
        A background web agent was asked to: \(task)
        When it claimed DONE it reported: \(claimed)
        The page it ended on (title, URL, visible text):
        \(page.prefix(2800))

        Judging ONLY by that page, did it ACTUALLY accomplish the task — is the result or \
        artifact the task wanted genuinely present (the page made and filled, the form \
        submitted, the info clearly shown)? If yes, or if you're not sure, reply exactly: \
        VERIFIED. Only if the page CLEARLY shows it is not done (blank/wrong page, nothing \
        created, the thing isn't there) reply: INCOMPLETE: <one short line on what's missing>
        """
        guard let reply = try? await verifier.complete(
            system: "You verify whether a web agent truly finished its task, judging only by the page it ended on. Lean VERIFIED unless it's clearly not done.",
            user: user, model: AnthropicModel.haiku, maxTokens: 120
        ) else { return nil } // verifier unavailable → don't block the completion
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("INCOMPLETE") else { return nil } // VERIFIED / unclear → accept
        let reason = trimmed.dropFirst("INCOMPLETE".count)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
        return reason.isEmpty ? "the page doesn't show the task was completed" : reason
    }

    private func episodeOnce(
        _ sub: AgentSubtask, index: Int, total: Int, firmer: Bool,
        onUpdate: @escaping @MainActor (Update) -> Void
    ) async -> (outcome: EpisodeOutcome, acted: Bool) {
        let prefix = total > 1 ? "Part \(index + 1)/\(total) — " : ""

        // Every part needs somewhere to start; "" means continue on the current
        // page, which only works once an earlier part has loaded one.
        var startURL = sub.startURL
        if startURL.isEmpty, sandbox.webView.url == nil {
            startURL = AgentTaskPlanner.searchURL(for: sub.task)
        }
        if !startURL.isEmpty {
            let host = URL(string: startURL)?.host() ?? startURL
            onUpdate(Update(status: "\(prefix)Opening \(host)…", snapshotPNG: nil, url: startURL, done: false, result: nil))
            await sandbox.navigate(to: startURL)
        }

        // WebKit can hand back a blank snapshot on a cold start; retry a few times
        // before declaring failure so a transient blank doesn't abort the episode.
        var shotData = await sandbox.snapshotPNG()
        var snapTries = 0
        while shotData == nil, snapTries < 3, !stopped {
            try? await Task.sleep(for: .milliseconds(400))
            shotData = await sandbox.snapshotPNG()
            snapTries += 1
        }
        guard var shot = shotData else {
            // A stop during the retry loop is a clean stop, not a browser failure.
            return (stopped ? .stopped : .failed("Couldn't open the sandbox browser."), false)
        }
        onUpdate(Update(status: "\(prefix)Working: \(sub.task)", snapshotPNG: shot, url: sandbox.currentURL, done: false, result: nil))

        var acted = false
        // Per-turn count of STATE-CHANGING actions (clicks/fills/navigation) — NOT
        // reads. Both efficiency guards key off it: a turn with zero state changes
        // is the model narrating or only reading (stall guard); a turn that DID
        // change state but left the page identical did nothing (no-effect guard).
        // Read-only DOM tools deliberately don't count, so a read never false-fires
        // no-effect. Incremented in the sink/harness/leftover sites, read + reset
        // once per loop iteration.
        var turnStateChanges = 0
        let agent = ComputerUseAgent(
            keyStore: keyStore, model: model, environmentNote: Self.sandboxNote,
            skillProvider: { WebSkills.content(named: $0) },
            harnessProvider: { [weak self, sandbox] name, input in
                // Using any tool IS acting (reading/clicking/filling) — not the model
                // narrating instead of working, so it must clear the firmer-retry guard.
                acted = true
                if name == "click_text" || name == "fill_field" { turnStateChanges += 1 }
                let result = await WebHarness.run(name, input, sandbox: sandbox)
                // DOM tools (click_text / fill_field) act by element — surface where they
                // landed so the watch-box cursor follows them too.
                if let pt = sandbox.consumeActionPoint() { self?.onCursor?(pt) }
                self?.audit("sandbox.tool", "\(name) \(Self.argSummary(input)) → \(result.prefix(70))")
                return result
            },
            extraTools: WebHarness.toolDefinitions()
        )
        // Stream like the cursor agent: each narration clause lands in the chat AND each
        // action runs the instant it's generated (the cursor moves seconds sooner) rather
        // than waiting for the whole turn. A pending steer returns false → the stream
        // halts immediately, so the user's message is handled now, not after the turn.
        agent.streamSink = { [weak self] item in
            guard let self, !self.stopped else { return false }
            switch item {
            case .text(let line):
                onUpdate(Update(status: prefix + line, snapshotPNG: nil, url: self.sandbox.currentURL, done: false, result: nil))
                return true
            case .action(let action):
                if self.pendingSteer != nil { return false }
                await self.apply(action)
                if let pt = self.sandbox.consumeActionPoint() { self.onCursor?(pt) }
                acted = true
                if Self.isStateChanging(action) { turnStateChanges += 1 }
                return true
            }
        }
        // Structural efficiency circuit-breakers (parity with the on-screen agent):
        // a page signature for no-effect detection and an idle-turn counter for the
        // stall guard, so a stuck run ends early instead of spinning to the 80-step
        // cap. lastSignature is the page BEFORE this episode's first actions.
        var lastSignature = await pageSignature()
        var noEffectTurns = 0
        var idleTurns = 0
        var step = await agent.begin(
            goal: AgentTaskPlanner.goal(for: sub, index: index, total: total, job: originalTask, findings: findings, firmer: firmer),
            screenshot: shot,
            displayWidthPoints: Int(WebSandbox.width),
            displayHeightPoints: Int(WebSandbox.height),
            skillIndex: WebSkills.index()
        )

        // Runaway backstop, not a budget — research/multi-page tasks routinely
        // need 30+ steps; the real terminators are the model finishing, the user
        // stopping the box, or a sign-in wall.
        let maxSteps = 80
        var count = 0
        while count < maxSteps, !stopped {
            if step.done {
                switch Self.classifyDone(rawText: step.text, failed: step.failed) {
                case .transportFailure:
                    // The turn never reached the model (network / encoding) — this "done"
                    // is an artifact of the failure, NOT a finished task. Counting it as a
                    // completion (while the page-verifier fails open on the SAME outage) was
                    // the false-completion the audit log caught: a mid-task run reported
                    // "done — I couldn't reach Claude" and was marked completed. Report it
                    // honestly and count nothing.
                    audit("sandbox.done", "unreachable — couldn't reach Claude (acted=\(acted))")
                    return (.failed("I couldn't reach Claude just now — ask again and I'll continue."), acted)
                case .needsLogin(let site):
                    audit("sandbox.done", "needs-login: \(site) · acted=\(acted)")
                    return (.needsLogin(site), acted)
                case .incomplete(let reason):
                    // The agent said done but flagged it couldn't actually finish — report
                    // it honestly and do NOT let it count as a completion.
                    audit("sandbox.done", "incomplete: \(reason.prefix(80)) · acted=\(acted)")
                    return (.failed("Couldn't finish — \(reason)"), acted)
                case .finished(let raw):
                    audit("sandbox.done", "finished (acted=\(acted)): \(raw.prefix(90))")
                    return (.finished(raw), acted)
                }
            }
            if !step.text.isEmpty { audit("sandbox.turn", String(step.text.prefix(90))) }
            // Streamed actions already ran via the sink; this handles any non-streamed
            // leftovers (zoom/screenshot are no-ops here, harness/skill resolve inline).
            for action in step.actions {
                if pendingSteer != nil || stopped { break }
                await apply(action)
                if let pt = sandbox.consumeActionPoint() { onCursor?(pt) }
                acted = true
                if Self.isStateChanging(action) { turnStateChanges += 1 }
            }

            // Did this turn change anything (clicks/fills/nav), or only read/talk?
            let turnActed = turnStateChanges > 0
            turnStateChanges = 0
            var nudge: String?
            // Stall guard: turns that only read or narrate without changing the page.
            // Tolerate one, nudge the second, stop the third — never spin to the cap.
            if turnActed {
                idleTurns = 0
            } else if !step.done {
                idleTurns += 1
                if idleTurns >= 3 {
                    audit("sandbox.stalled", String(step.text.prefix(80)))
                    return (.failed("I kept looking without making progress, so I stopped."), acted)
                }
                if idleTurns == 2 {
                    nudge = "You've spent two turns without changing anything. Use click_text / fill_field / open_url to actually do the work NOW, or if it's already done or impossible, say so and stop."
                }
            }

            try? await Task.sleep(for: .milliseconds(300))
            shot = await sandbox.snapshotPNG() ?? shot

            // No-effect: an acting turn that left the page identical (same URL +
            // text) did nothing — don't let it repeat the dead action. The DOM tools
            // already report "no element found"; this catches the subtler case of a
            // click that "succeeded" but changed nothing.
            if turnActed {
                let signature = await pageSignature()
                if signature == lastSignature {
                    noEffectTurns += 1
                    if noEffectTurns >= 3 {
                        audit("sandbox.noeffect", "3rd no-effect — stopping")
                        return (.failed("My actions stopped changing the page, so I stopped."), acted)
                    }
                    audit("sandbox.noeffect", "page unchanged after acting")
                    let extra = "Your last action did NOT change the page — it had no effect. Do NOT repeat it; try a different element or route (list_interactives shows what's actually clickable)."
                    nudge = nudge.map { $0 + " " + extra } ?? extra
                } else {
                    noEffectTurns = 0
                }
                lastSignature = signature
            }
            // Deliver any message the user typed into the box this turn. It is
            // AUTHORITATIVE. Crucially it may EXTEND the job ("after that, make a notion
            // page") — so we QUEUE it as the next subtask (carrying the findings so far),
            // not just inject a note. The original plan's later parts are dropped (the
            // steer supersedes them); a queued part means a follow-up actually runs
            // instead of the agent finishing after the current task.
            var steerNote: String?
            if let steer = pendingSteer {
                pendingSteer = nil
                steerNote = """
                ⚠️ The user just sent you this, and it's the priority now: \(steer)
                If it's a FOLLOW-UP ("after that", "also", "then"), finish your current \
                task first — a queued step will carry this out next with your findings. \
                If it REPLACES your current task, wrap up now so that step takes over. \
                Either way, do NOT ignore it.
                """
                // Supersede the stale auto-planned remainder ONCE; after that, each steer
                // ADDS to the queue (so "do A" then "also do B" both run, in order)
                // instead of the newer steer dropping the one already queued.
                if !droppedOriginalPlanForSteer {
                    plan = Array(plan.prefix(index + 1))
                    droppedOriginalPlanForSteer = true
                }
                plan.append(AgentSubtask(task: steer, web: true))
            }
            // A user steer is authoritative; a stall/no-effect nudge rides alongside it.
            let note = [steerNote, nudge].compactMap { $0 }.joined(separator: "\n\n")
            step = await agent.proceed(screenshot: shot, note: note.isEmpty ? nil : note)
            count += 1
        }
        return (stopped ? .stopped : .stepLimit, acted)
    }

    /// Cheap "did the page change" signature for no-effect detection — URL + a
    /// prefix of the readable text. A dead DOM action leaves it unchanged;
    /// navigation/content changes move it. Web-native (no pixel churn from
    /// cursors/ads), the structural analog of the on-screen frame diff.
    private func pageSignature() async -> String {
        let text = await sandbox.readPageText()
        return sandbox.currentURL + "\u{1}" + String(text.prefix(4000))
    }

    /// Whether a built-in action changes page state (so it counts toward acting),
    /// vs an observation that doesn't (screenshot/wait/zoom/highlight).
    nonisolated static func isStateChanging(_ action: CUAction) -> Bool {
        switch action {
        case .screenshot, .wait, .zoom, .highlight: return false
        default: return true
        }
    }

    static let sandboxNote = """
    You are inside a single web view in a sandboxed browser — there are NO tabs, \
    NO "+" button and NO address bar, and there are no other apps (the open_app \
    tool does nothing here). Do not look for them and never try to open a new \
    tab. There is only this one view. To go to a different site or known URL, \
    use the open_url tool — it loads instantly in this same view. Links that \
    would normally open in a new tab automatically open right here, so just \
    click them and continue working in place.

    Actually CARRY OUT the task on the real website(s) for it. Do NOT search for \
    tutorials, articles, or "how to" guides about the task, and do NOT go to \
    ChatGPT/OpenAI to ask how — just do the task itself directly.

    You have instant DOM tools — PREFER them over clicking pixel coordinates or \
    relying on the screenshot: read_page (read the page's text/title/URL), \
    list_interactives (see the clickable + fillable elements), click_text (click a \
    link/button by its visible label), and fill_field (type into an input by its \
    label). They are exact and fast; fall back to coordinate clicks only when no tool \
    fits.

    If the page is a sign-in / login / "log in to continue" wall and you do not \
    have credentials, do NOT guess or type anything. Stop immediately and reply \
    with exactly: NEEDS_LOGIN <site name>.

    Before you say you are DONE, VERIFY the outcome actually exists — call \
    read_page and confirm it is really there (the page shows the text you typed, \
    the form submitted, the result is present). Taking actions is NOT the same as \
    finishing: a click can do nothing, a field can silently reject input. Check, \
    do not assume.

    If you genuinely CANNOT complete the task — a control won't take your input, \
    the page won't cooperate, the thing doesn't exist — do NOT pretend you \
    succeeded. Reply starting with exactly: INCOMPLETE: <one line on what blocked \
    you>. A false "done" is worse than an honest "incomplete", and the user is \
    watching, so they can take over.

    When the task is TRULY finished and verified, reply with ONE short line \
    stating the concrete outcome and the key facts you found or produced — names, \
    prices, dates, links, confirmation numbers — because later parts of the job \
    rely on that line.
    """

    /// Maps a Computer Use action onto the web sandbox. The agent works in bottom-left
    /// AppKit coordinates; the page wants top-left, so y is flipped.
    private func apply(_ action: CUAction) async {
        func topLeftY(_ y: Double) -> CGFloat { WebSandbox.height - CGFloat(y) }
        switch action {
        case .click(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y), .tripleClick(let x, let y):
            audit("sandbox.act", "click (\(Int(x)),\(Int(topLeftY(y))))")
            await sandbox.click(xTopLeft: CGFloat(x), yTopLeft: topLeftY(y))
        case .drag(_, _, let toX, let toY):
            // No real drag in the JS bridge — landing on the destination is the
            // closest meaningful approximation.
            await sandbox.click(xTopLeft: CGFloat(toX), yTopLeft: topLeftY(toY))
        case .move(let x, let y):
            await sandbox.moveCursor(toTopLeftX: CGFloat(x), y: topLeftY(y))
        case .type(let text):
            audit("sandbox.act", "type \"\(text.prefix(40))\"")
            await sandbox.typeText(text)
        case .key(let combo):
            audit("sandbox.act", "key \(combo)")
            await sandbox.pressKey(combo)
        case .scroll(_, _, let direction, let amount):
            let magnitude = CGFloat(max(1, amount)) * 120
            await sandbox.scroll(dy: direction.lowercased() == "up" ? -magnitude : magnitude)
        case .wait:
            try? await Task.sleep(for: .milliseconds(600))
        case .screenshot, .zoom:
            break  // the loop re-snapshots; the sandbox view is small enough to read
        case .highlight:
            break  // the marching-ants overlay is a real-screen affordance
        case .openApp:
            break  // no apps inside the web sandbox
        case .openURL(let urlString):
            audit("sandbox.act", "open \(urlString.prefix(60))")
            await sandbox.navigate(to: urlString)
            try? await Task.sleep(for: .milliseconds(800))  // let the page start rendering
        }
    }

    /// A short readable summary of a tool's input for the audit trail.
    private static func argSummary(_ input: [String: Any]) -> String {
        for key in ["text", "field", "url", "query"] {
            if let v = input[key] as? String, !v.isEmpty {
                let value = (input["value"] as? String).map { " = \"\($0.prefix(30))\"" } ?? ""
                return "\"\(v.prefix(40))\"\(value)"
            }
        }
        return ""
    }

    /// What a finished model turn means, BEFORE page-verification. Kept pure (no I/O)
    /// so the invariant the audit log proved we need — a turn that never reached the
    /// model is NEVER a completion — is unit-tested.
    enum DoneKind: Equatable {
        /// The request failed to send / the model was unreachable. `done` is an
        /// artifact of the failure, not a real finish — must count as a failure.
        case transportFailure
        /// A sign-in wall: the agent asked the user to log in (NEEDS_LOGIN).
        case needsLogin(String)
        /// The agent honestly reported it couldn't finish (INCOMPLETE).
        case incomplete(String)
        /// A genuine completion, carrying the agent's final one-line result.
        case finished(String)
    }

    /// Classifies a `done` turn. A failed turn (`CUStep.failed`) is a transport failure
    /// no matter what text it carries — so an unreachable round trip can never be read
    /// as "finished", which is what let a mid-task run get counted as completed.
    nonisolated static func classifyDone(rawText: String, failed: Bool) -> DoneKind {
        if failed { return .transportFailure }
        let raw = rawText.isEmpty ? "Done." : rawText
        if let site = loginSite(in: raw) { return .needsLogin(site) }
        if let reason = incompleteReason(in: raw) { return .incomplete(reason) }
        return .finished(raw)
    }

    /// Detects the agent's NEEDS_LOGIN signal and returns the site name.
    nonisolated private static func loginSite(in text: String) -> String? {
        let upper = text.uppercased()
        guard upper.contains("NEEDS_LOGIN") else { return nil }
        if let range = text.range(of: "NEEDS_LOGIN", options: .caseInsensitive) {
            let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
            if !rest.isEmpty { return rest }
        }
        return "this site"
    }

    /// Detects the agent's honest INCOMPLETE signal — but ONLY as a leading marker (the
    /// protocol is "reply starting with INCOMPLETE:"), never mid-sentence, so a genuine
    /// success that merely mentions the word ("some dates had incomplete pricing") is
    /// not mistaken for a failure.
    nonisolated private static func incompleteReason(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("INCOMPLETE") else { return nil }
        let rest = trimmed.dropFirst("INCOMPLETE".count)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
        return rest.isEmpty ? "I couldn't finish this one." : rest
    }
}
