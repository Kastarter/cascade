import AppKit
import CascadeMemory
import ComputerUseKit
import Foundation
import MacContextKit
import ProviderKit

/// Pure translation between the model's window-local coordinates/actions and the
/// global-CG `ComputerUseAction`s a `PidEventActuator` posts. Kept pure so the
/// coordinate flip — a wrong one clicks the wrong row — is unit-tested.
enum NativeWindowMapping {
    /// `ComputerUseAgent` scales model pixels → window-local AppKit (bottom-left)
    /// when the window size is passed as the display size. Convert to global CG
    /// (top-left), the space `SCWindow.frame` and the actuator use.
    static func globalCG(windowLocalAppKit p: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + p.x, y: windowFrame.minY + (windowFrame.height - p.y))
    }

    /// Splits a "cmd+shift+a" combo into (key, modifiers).
    static func parseKey(_ combo: String) -> (key: String, modifiers: [String]) {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let key = parts.last else { return (combo, []) }
        return (key, Array(parts.dropLast()))
    }

    /// Scroll direction + amount → CG wheel deltas (tunable; ~40px per unit).
    static func scrollDelta(direction: String, amount: Int) -> (dx: Double, dy: Double) {
        let step = Double(amount) * 40
        switch direction.lowercased() {
        case "up": return (0, step)
        case "down": return (0, -step)
        case "left": return (step, 0)
        case "right": return (-step, 0)
        default: return (0, -step)
        }
    }

    /// Maps one model action to a global-CG `ComputerUseAction`, or nil for actions
    /// the episode loop handles itself (wait/screenshot/zoom/highlight/openApp).
    static func translate(_ action: CUAction, windowFrame: CGRect) -> ComputerUseAction? {
        func g(_ x: Double, _ y: Double) -> CGPoint {
            globalCG(windowLocalAppKit: CGPoint(x: x, y: y), windowFrame: windowFrame)
        }
        switch action {
        case .move(let x, let y): let p = g(x, y); return .move(x: p.x, y: p.y)
        case .click(let x, let y): let p = g(x, y); return .click(x: p.x, y: p.y)
        case .doubleClick(let x, let y): let p = g(x, y); return .doubleClick(x: p.x, y: p.y)
        case .tripleClick(let x, let y): let p = g(x, y); return .tripleClick(x: p.x, y: p.y)
        case .rightClick(let x, let y): let p = g(x, y); return .rightClick(x: p.x, y: p.y)
        case .drag(let fx, let fy, let tx, let ty):
            let a = g(fx, fy); let b = g(tx, ty)
            return .drag(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y)
        case .type(let text): return .typeText(text)
        case .key(let combo): let (k, m) = parseKey(combo); return .key(k, modifiers: m)
        case .scroll(_, _, let dir, let amount):
            let d = scrollDelta(direction: dir, amount: amount); return .scroll(deltaX: d.dx, deltaY: d.dy)
        case .openURL(let url): return .openURL(url)
        case .wait, .screenshot, .zoom, .highlight, .openApp: return nil
        }
    }

    /// The global-CG point a click action targets (for the companion cursor), or nil.
    static func targetPoint(_ action: CUAction, windowFrame: CGRect) -> CGPoint? {
        switch action {
        case .click(let x, let y), .doubleClick(let x, let y), .tripleClick(let x, let y),
             .rightClick(let x, let y), .move(let x, let y):
            return globalCG(windowLocalAppKit: CGPoint(x: x, y: y), windowFrame: windowFrame)
        case .drag(_, _, let tx, let ty):
            return globalCG(windowLocalAppKit: CGPoint(x: tx, y: ty), windowFrame: windowFrame)
        default: return nil
        }
    }

    /// Global CG (top-left) → global AppKit (bottom-left), for the companion cursor.
    static func appKit(fromGlobalCG p: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }
}

extension CascadeAppModel {
    /// Launches one background-native agent: it drives `appName`'s window via
    /// pid-posted events (no real cursor, no focus steal) while the user keeps
    /// working, shown by a translucent companion cursor. Several can run at once.
    /// RUNTIME-UNVERIFIED (pid-posted mouse) — see docs/PARALLEL_AGENTS_PLAN.md.
    public func launchBackgroundNativeAgent(goal: String, appName: String) {
        Task { await self.runBackgroundNativeAgent(goal: goal, appName: appName) }
    }

    private func runBackgroundNativeAgent(goal: String, appName: String) async {
        guard hasAnthropicKey else {
            dock.show(title: "Need a Claude key", detail: "Add it in Settings to run background agents.")
            return
        }
        // Resolve the app → launch/find it → pid. We do NOT activate it (the user
        // keeps their focus); openApp brings it to existence if not running.
        let installed = appSkills.appNamed(inGoal: appName) ?? appName
        _ = await Self.openApp(named: installed)
        try? await Task.sleep(for: .milliseconds(1200))
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(installed) == true
                || installed.localizedCaseInsensitiveContains($0.localizedName ?? "\u{1}")
        }), let _ = Optional(app.processIdentifier) else {
            dock.show(title: "Couldn't find \(appName)", detail: "Open it first, then try again.")
            return
        }
        let pid = app.processIdentifier
        guard let windowFrame = await ScreenCaptureUtility.mainWindowFrame(forPid: pid) else {
            dock.show(title: "No window for \(appName)", detail: "It has no visible window to work in.")
            return
        }

        let runState = AgentRunState()
        let cursorID = "native-\(pid)"
        let theme: CursorTheme = Self.companionThemes[backgroundNativeRuns.count % Self.companionThemes.count]
        backgroundNativeRuns[cursorID] = runState
        let actuator = PidEventActuator(pid: pid, runState: runState)
        let res = AgentResolution.best(forWidth: Int(windowFrame.width), height: Int(windowFrame.height))
        let mainHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? windowFrame.maxY

        guidanceOverlay.addCompanion(id: cursorID, theme: theme, atGlobalPoint:
            NativeWindowMapping.appKit(fromGlobalCG: CGPoint(x: windowFrame.midX, y: windowFrame.midY), mainDisplayHeight: mainHeight))
        guidanceOverlay.labelCompanion(id: cursorID, "\(appName) · starting")
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "native.bg.start", detail: "\(appName) pid=\(pid) — \(String(goal.prefix(80)))"))

        // Skills-only agent (the computer tool + app skills are enough to drive a
        // native app). Deliberately NOT the on-screen harness/recall — those gate
        // on the on-screen assistGeneration and would die when the user starts
        // another task; a background agent must outlive that.
        let agent = ComputerUseAgent(
            model: AnthropicModel.opus,
            effort: cuEffort,
            skillProvider: { [appSkills, store] name in
                guard let skill = appSkills.skill(named: name) else { return nil }
                if skill.explicitAskOnly && !AppSkill.goalAsksForScript(goal) {
                    return "Skill \(skill.name) is a scripting playbook and the user didn't ask for a script — do the work in the app's own UI instead."
                }
                Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.skill", detail: name)) }
                return skill.promptBlock
            }
        )
        defer {
            backgroundNativeRuns[cursorID] = nil
            guidanceOverlay.removeCompanion(id: cursorID)
        }

        func capture() async -> ScreenCaptureUtility.CapturedWindow? {
            await ScreenCaptureUtility.captureWindowJPEG(pid: pid, width: res.w, height: res.h)
        }
        guard let first = await capture() else {
            dock.show(title: "Can't see \(appName)", detail: "Couldn't capture its window.")
            return
        }
        var frame = first.frame
        var step = await agent.begin(
            goal: goal, screenshot: first.jpeg,
            displayWidthPoints: Int(frame.width), displayHeightPoints: Int(frame.height),
            note: "You are working in \(appName)'s window in the background; do the task there.",
            skillIndex: appSkills.indexText
        )

        var lastHashes = Self.gridHashes(ofJPEG: first.jpeg)
        var idleTurns = 0, noEffectTurns = 0, count = 0
        let maxSteps = 60
        while count < maxSteps {
            if runState.isStopRequested { break }
            if step.done {
                guidanceOverlay.labelCompanion(id: cursorID, "\(appName) · done")
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "native.bg.done", detail: String(step.text.prefix(90))))
                try? await Task.sleep(for: .milliseconds(900))
                break
            }
            if !step.text.isEmpty { guidanceOverlay.labelCompanion(id: cursorID, String(step.text.prefix(48))) }

            var actedThisTurn = false
            for action in step.actions {
                if runState.isStopRequested { break }
                if let target = NativeWindowMapping.targetPoint(action, windowFrame: frame) {
                    guidanceOverlay.flyCompanion(id: cursorID, toGlobalPoint:
                        NativeWindowMapping.appKit(fromGlobalCG: target, mainDisplayHeight: mainHeight))
                }
                guard let mapped = NativeWindowMapping.translate(action, windowFrame: frame) else { continue }
                do {
                    try await actuator.perform(mapped)
                    actedThisTurn = true
                    if case .click = mapped { guidanceOverlay.pressCompanion(id: cursorID) }
                    if case .doubleClick = mapped { guidanceOverlay.pressCompanion(id: cursorID) }
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "native.bg.act", detail: "[\(cursorID)] \(Self.describe(mapped))"))
                } catch { break }
                try? await Task.sleep(for: .milliseconds(120))
            }

            // Stall guard.
            if actedThisTurn { idleTurns = 0 } else if !step.done {
                idleTurns += 1
                if idleTurns >= 3 {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "native.bg.stalled", detail: cursorID))
                    break
                }
            }

            if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
            guard let next = await capture() else { break }
            frame = next.frame
            // No-effect guard (same engine as on-screen): an acting turn that left
            // the window unchanged did nothing.
            var nudge: String?
            if actedThisTurn, let last = lastHashes, let now = Self.gridHashes(ofJPEG: next.jpeg),
               PerceptualHash.isDuplicateGrid(now, of: last, threshold: Self.noEffectThreshold) {
                noEffectTurns += 1
                if noEffectTurns >= 3 {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "native.bg.noeffect", detail: "\(cursorID) — stopping"))
                    break
                }
                nudge = "Your last action did NOT change the window — it had no effect. Do NOT repeat it; try a different control or approach."
            } else if actedThisTurn {
                noEffectTurns = 0
            }
            lastHashes = Self.gridHashes(ofJPEG: next.jpeg) ?? lastHashes
            step = await agent.proceed(screenshot: next.jpeg, note: nudge)
            count += 1
        }
    }

    /// Launches one cursor agent per order — each runs in parallel with its own
    /// companion cursor. An order naming a native app drives that app via
    /// pid-posted events; anything else (research, a website) runs in the web
    /// sandbox. This is the "give orders to several agents at once" entry; it is
    /// NOT hardcoded to any app — each order picks its own surface.
    public func launchAgents(orders: [String]) {
        for raw in orders {
            let order = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !order.isEmpty else { continue }
            routeAgentOrder(order)
        }
    }

    /// Routes one order to the right surface: a native app → background-native
    /// agent; web/research → the web sandbox. Shared by the single-order voice
    /// path and the multi-order launcher.
    func routeAgentOrder(_ order: String) {
        if let app = appSkills.appNamed(inGoal: order), !Self.runsInBackground(apps: [app]) {
            launchBackgroundNativeAgent(goal: order, appName: app)
        } else {
            createSandboxAgent(task: order)
        }
    }

    /// Stops every running background-native agent.
    public func stopBackgroundNativeAgents() {
        for (_, runState) in backgroundNativeRuns { runState.requestStop() }
    }

    private static let companionThemes: [CursorTheme] = [.pink, .peach, .purple, .green]

    private static func describe(_ action: ComputerUseAction) -> String {
        switch action {
        case .click(let x, let y): return "click \(Int(x)),\(Int(y))"
        case .doubleClick(let x, let y): return "double \(Int(x)),\(Int(y))"
        case .rightClick(let x, let y): return "right \(Int(x)),\(Int(y))"
        case .tripleClick(let x, let y): return "triple \(Int(x)),\(Int(y))"
        case .drag: return "drag"
        case .move(let x, let y): return "move \(Int(x)),\(Int(y))"
        case .typeText(let t): return "type chars=\(t.count)"
        case .key(let k, let m): return "key \(m.joined(separator: "+"))+\(k)"
        case .scroll: return "scroll"
        case .openURL: return "openURL"
        }
    }
}
