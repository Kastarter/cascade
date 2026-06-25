import AppKit
import CascadeMemory
import ComputerUseKit
import Foundation
import MacContextKit
import ProviderKit

/// Pure translation between the model's window-local coordinates and the global-CG
/// points the AX actuator + companion cursor need. Kept pure so the coordinate flip
/// — a wrong one presses the wrong row — is unit-tested. (Recovered from the
/// 2026-06-22 multi-cursor revert; actuation now goes through `GhostActuator`, not
/// the reverted pid-mouse `PidEventActuator`.)
enum NativeWindowMapping {
    /// `ComputerUseAgent` scales model pixels → window-local AppKit (bottom-left)
    /// when the window size is passed as the display size. Convert to global CG
    /// (top-left), the space `SCWindow.frame` and `AXUIElementCopyElementAtPosition`
    /// use.
    static func globalCG(windowLocalAppKit p: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + p.x, y: windowFrame.minY + (windowFrame.height - p.y))
    }

    /// Global CG (top-left) → global AppKit (bottom-left), for the companion cursor.
    static func appKit(fromGlobalCG p: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    /// The global-CG point a click/move action targets (for the companion cursor and
    /// the AX press), or nil for non-positional actions.
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
}

extension CascadeAppModel {
    /// Whether background ghost mode is armed (work behind the user's window). OFF by
    /// default; opt in with `cascade.ghostBackground = true` (requires ghost mode).
    static func ghostBackgroundEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "cascade.ghostBackground")
    }

    /// Launches ONE background ghost agent: it captures `appName`'s window even when
    /// it's behind the user's active window, and presses/types through the
    /// Accessibility API by PID — no cursor, no focus steal — so the user keeps
    /// working on top. A translucent companion cursor shows the work. STOP via Esc.
    public func launchBackgroundGhostAgent(goal: String, appName: String, gen: Int) {
        Task { await self.runBackgroundGhostAgent(goal: goal, appName: appName, gen: gen) }
    }

    private func runBackgroundGhostAgent(goal: String, appName: String, gen: Int) async {
        guard hasAnthropicKey else {
            dock.show(title: "Need a Claude key", detail: "Add it in Settings to run a background agent.")
            return
        }
        // The target must be RUNNING (we never activate it — the user keeps focus).
        // If it isn't open we ask the user to open it rather than launch+position a
        // fresh window behind theirs (finicky and surprising).
        guard let app = runningApp(matching: appName) else {
            dock.show(title: "Open \(appName) first", detail: "Background mode works on an app that's already running behind your window.")
            return
        }
        let pid = app.processIdentifier
        guard let windowFrame0 = await ScreenCaptureUtility.mainWindowFrame(forPid: pid) else {
            dock.show(title: "No window for \(appName)", detail: "It has no visible window to work in.")
            return
        }

        let runState = AgentRunState()
        backgroundGhostRun = runState
        let res = AgentResolution.best(forWidth: Int(windowFrame0.width), height: Int(windowFrame0.height))
        let mainHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? windowFrame0.maxY

        guidanceOverlay.setTheme(cursorTheme)
        guidanceOverlay.setGhost(true)
        guidanceOverlay.navigate(toGlobalPoint:
            NativeWindowMapping.appKit(fromGlobalCG: CGPoint(x: windowFrame0.midX, y: windowFrame0.midY), mainDisplayHeight: mainHeight))
        dock.show(title: "Working in \(appName)", detail: "Behind your window — keep working; press Esc to stop.")
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.start", detail: "\(appName) pid=\(pid) — \(String(goal.prefix(80)))"))
        defer {
            backgroundGhostRun = nil
            guidanceOverlay.hide()
        }

        // Skills-only agent: the computer tool + app skills are enough to drive a
        // native app. NOT the on-screen harness/recall (those gate on the on-screen
        // assistGeneration and would die when the user starts another task).
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
            note: "You are working in \(appName)'s window IN THE BACKGROUND while the user works elsewhere. Do the task by clicking controls and typing into fields. Prefer clicking a button over pressing Return; avoid drag and scroll (they may not register in the background).",
            skillIndex: appSkills.indexText
        )

        var lastHashes = Self.gridHashes(ofJPEG: first.jpeg)
        var idleTurns = 0, noEffectTurns = 0, count = 0
        let maxSteps = 60
        while count < maxSteps {
            if runState.isStopRequested || assistGeneration != gen { break }
            if step.done {
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.done", detail: String(step.text.prefix(90))))
                dock.show(title: "\(appName) — done", detail: String(step.text.prefix(80)))
                try? await Task.sleep(for: .milliseconds(800))
                break
            }

            var actedThisTurn = false
            for action in step.actions {
                if runState.isStopRequested { break }
                if let target = NativeWindowMapping.targetPoint(action, windowFrame: frame) {
                    guidanceOverlay.navigate(toGlobalPoint:
                        NativeWindowMapping.appKit(fromGlobalCG: target, mainDisplayHeight: mainHeight))
                }
                if await actuateGhostBackground(action, pid: pid, windowFrame: frame) { actedThisTurn = true }
                try? await Task.sleep(for: .milliseconds(120))
            }
            // Honor STOP / supersession BEFORE the next model round-trip, so Esc
            // stands down promptly instead of paying a full proceed() call first.
            if runState.isStopRequested || assistGeneration != gen { break }

            // Stall guard (acting turns that change nothing / look-only turns).
            if actedThisTurn { idleTurns = 0 } else if !step.done {
                idleTurns += 1
                if idleTurns >= 3 {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.stalled", detail: appName))
                    break
                }
            }

            if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
            guard let next = await capture() else { break }
            frame = next.frame
            // No-effect guard (same engine as on-screen): an acting turn that left the
            // window unchanged did nothing.
            var nudge: String?
            if actedThisTurn, let last = lastHashes, let now = Self.gridHashes(ofJPEG: next.jpeg),
               PerceptualHash.isDuplicateGrid(now, of: last, threshold: Self.noEffectThreshold) {
                noEffectTurns += 1
                if noEffectTurns >= 3 {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.noeffect", detail: "\(appName) — stopping"))
                    break
                }
                nudge = "Your last action did NOT change the window. Do NOT repeat it — try a different control. Remember keys/drag may not land in the background; click a real control instead."
            } else if actedThisTurn {
                noEffectTurns = 0
            }
            lastHashes = Self.gridHashes(ofJPEG: next.jpeg) ?? lastHashes
            step = await agent.proceed(screenshot: next.jpeg, note: nudge)
            count += 1
        }
    }

    /// Actuates one model action against the background window via the Accessibility
    /// API. Returns whether it produced an effect (so the no-effect/stall guards
    /// account correctly). Press/type/key are supported; complex gestures are skipped
    /// (no cursor-free equivalent), and on an AX miss we DON'T fall back to a real
    /// click — that would disturb the user and hit the wrong window.
    private func actuateGhostBackground(_ action: CUAction, pid: pid_t, windowFrame: CGRect) async -> Bool {
        func gcg(_ x: Double, _ y: Double) -> CGPoint {
            NativeWindowMapping.globalCG(windowLocalAppKit: CGPoint(x: x, y: y), windowFrame: windowFrame)
        }
        switch action {
        case .click(let x, let y), .doubleClick(let x, let y), .tripleClick(let x, let y):
            let outcome = GhostActuator.press(atCG: gcg(x, y), pid: pid)
            guidanceOverlay.press()
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: outcome == .missed ? "ghost.bg.miss" : "ghost.bg.press", detail: "click"))
            return outcome != .missed
        case .rightClick(let x, let y):
            let outcome = GhostActuator.press(atCG: gcg(x, y), pid: pid, showMenu: true)
            guidanceOverlay.press()
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: outcome == .missed ? "ghost.bg.miss" : "ghost.bg.press", detail: "rightClick"))
            return outcome != .missed
        case .type(let text):
            let ok = GhostActuator.insertText(text, pid: pid)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: ok ? "ghost.bg.type" : "ghost.bg.miss", detail: "chars=\(text.count)"))
            return ok
        case .key(let combo):
            let ok = GhostActuator.postKey(combo, pid: pid)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.key", detail: combo))
            return ok
        case .move:
            return false  // companion already flew there; no real effect needed
        case .drag, .scroll:
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.skip", detail: "gesture"))
            return false
        case .wait:
            try? await Task.sleep(for: .milliseconds(600))
            return false
        case .openURL:
            // Opening a URL would foreground the browser and break the background
            // invariant — skip it; the agent should act inside the running app.
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "ghost.bg.skip", detail: "openURL"))
            return false
        case .screenshot, .zoom, .highlight, .openApp:
            return false
        }
    }

    /// A running, regular (Dock-visible) app matching `name`, never Cascade itself —
    /// the app the background agent will drive without bringing it forward.
    func runningApp(matching name: String) -> NSRunningApplication? {
        let target = appSkills.appNamed(inGoal: name) ?? name
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != "com.humain.cascade"
                && (($0.localizedName?.localizedCaseInsensitiveContains(target) == true)
                    || target.localizedCaseInsensitiveContains($0.localizedName ?? "\u{1}"))
        }
    }

    /// Stops a running background ghost agent (wired to Esc / STOP).
    public func stopBackgroundGhostAgent() {
        backgroundGhostRun?.requestStop()
    }

    /// One-click verification: drive a small task in `app` behind the user's window.
    /// The app must already be running. Used by the Settings "Try it" button so the
    /// feature can be tested without relying on voice transcription.
    public func runBackgroundGhostTest(app: String = "Notes") {
        launchBackgroundGhostAgent(
            goal: "Create a new note and type a short one-line hello.",
            appName: app, gen: assistGeneration
        )
    }
}
