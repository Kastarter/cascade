import AppKit
import SwiftUI

// Transparent, click-through, always-on-top companion cursor. The follow-the-user-
// cursor behaviour + blue-cursor idea are adapted from `jasonkneen/openclicky`
// (`OverlayWindow.swift` / `BlueCursorView`, MIT) — re-implemented as a small
// Cascade-owned companion that sits next to the user's cursor and flies to the
// element they ask about. See docs/THIRD_PARTY_NOTICES.md.

@MainActor
public final class GuidanceOverlayController {
    private var window: GuidanceOverlayWindow?
    private let state = GuidanceState()
    private var followTimer: Timer?
    private var returnTask: Task<Void, Never>?

    /// Where the companion sits relative to the real cursor tip (points; +x right, +y down).
    private let followOffset = CGSize(width: 18, height: 14)

    public init() {}

    /// Shows the companion cursor and has it continuously follow the user's cursor.
    /// Idempotent.
    public func startFollowing() {
        ensureWindow()
        state.visible = true
        state.pointing = false
        window?.orderFrontRegardless()
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    /// Flies the companion from beside the cursor to a global screen point and shows
    /// a label, then eases back and resumes following.
    public func present(atGlobalPoint point: CGPoint, label: String, seconds: TimeInterval = 6) {
        startFollowing()
        state.label = label
        state.pointing = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            state.cursorPoint = toLocalTopLeft(point)
        }
        returnTask?.cancel()
        returnTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            let mouse = NSEvent.mouseLocation
            let back = self.toLocalTopLeft(CGPoint(x: mouse.x + self.followOffset.width, y: mouse.y - self.followOffset.height))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { self.state.cursorPoint = back }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self.state.pointing = false
            self.state.label = ""
        }
    }

    /// Flies the companion to a global point for an *action* and keeps it parked
    /// there (no auto-return) so it can press. Call `hide()` when the task ends to
    /// resume following the user's cursor.
    public func navigate(toGlobalPoint point: CGPoint) {
        startFollowing()
        returnTask?.cancel()
        returnTask = nil
        state.label = ""
        state.pointing = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) {
            state.cursorPoint = toLocalTopLeft(point)
        }
    }

    /// Plays a quick press/tap animation at the companion's current position.
    public func press() {
        state.pressTrigger &+= 1
    }

    /// Returns the companion to following the cursor (clears any pointing/label) but
    /// keeps it visible. Used when a question matched no element.
    public func hide() {
        returnTask?.cancel()
        returnTask = nil
        state.pointing = false
        state.label = ""
    }

    /// Fully removes the companion (used if the assistant is turned off).
    public func stop() {
        followTimer?.invalidate()
        followTimer = nil
        returnTask?.cancel()
        returnTask = nil
        state.visible = false
        window?.orderOut(nil)
    }

    private func follow() {
        guard state.visible, !state.pointing else { return }
        let mouse = NSEvent.mouseLocation
        let target = toLocalTopLeft(CGPoint(x: mouse.x + followOffset.width, y: mouse.y - followOffset.height))
        if abs(target.x - state.cursorPoint.x) > 0.5 || abs(target.y - state.cursorPoint.y) > 0.5 {
            state.cursorPoint = target
        }
    }

    private var desktopFrame: CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// Global (AppKit, bottom-left) → overlay-window-local (top-left) coordinates.
    private func toLocalTopLeft(_ global: CGPoint) -> CGPoint {
        let frame = desktopFrame
        let x = global.x - frame.minX
        let yFromBottom = global.y - frame.minY
        return CGPoint(x: x, y: frame.height - yFromBottom)
    }

    private func ensureWindow() {
        let frame = desktopFrame
        if let window {
            if window.frame != frame { window.setFrame(frame, display: true) }
            return
        }
        let overlay = GuidanceOverlayWindow(frame: frame)
        overlay.contentView = NSHostingView(rootView: GuidanceOverlayView(state: state))
        window = overlay
    }
}

final class GuidanceState: ObservableObject {
    @Published var cursorPoint: CGPoint = .zero
    @Published var label: String = ""
    @Published var pointing = false
    @Published var visible = false
    /// Bumped on every press so the overlay can fire a one-shot tap ripple.
    @Published var pressTrigger = 0
}

final class GuidanceOverlayWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct GuidanceOverlayView: View {
    @ObservedObject var state: GuidanceState
    private let blue = Color(red: 0.20, green: 0.55, blue: 1.0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if state.visible {
                PressRipple(trigger: state.pressTrigger, color: blue)
                    .offset(x: state.cursorPoint.x - 17, y: state.cursorPoint.y - 17)
                GuideCursor(label: state.pointing ? state.label : "", pressTrigger: state.pressTrigger)
                    .offset(x: state.cursorPoint.x, y: state.cursorPoint.y)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// One-shot expanding ring centred on the cursor tip — the visible "click".
private struct PressRipple: View {
    let trigger: Int
    let color: Color
    @State private var scale: CGFloat = 0.2
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2.5)
            .frame(width: 34, height: 34)
            .scaleEffect(scale)
            .opacity(opacity)
            .onChange(of: trigger) { _, _ in
                scale = 0.25
                opacity = 0.85
                withAnimation(.easeOut(duration: 0.42)) {
                    scale = 1.3
                    opacity = 0
                }
            }
    }
}

/// Blue arrow cursor sized to match the system cursor (tip at the top-left origin),
/// with an optional label callout when pointing.
struct GuideCursor: View {
    let label: String
    var pressTrigger: Int = 0
    @State private var pressed = false
    private let blue = Color(red: 0.20, green: 0.55, blue: 1.0)

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            ArrowShape()
                .fill(blue)
                .overlay(ArrowShape().stroke(.white, lineWidth: 1.0))
                .frame(width: 12, height: 16)
                .scaleEffect(pressed ? 0.74 : 1.0, anchor: .topLeading)
                .shadow(color: blue.opacity(0.6), radius: 5)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .onChange(of: pressTrigger) { _, _ in
                    pressed = true
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { pressed = false }
                }

            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(blue, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                    .fixedSize()
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: label)
    }
}

/// Arrowhead with its tip at the top-left origin (0,0), like the macOS cursor.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w * 0.30, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.50, y: h * 1.04))
        path.addLine(to: CGPoint(x: w * 0.70, y: h * 0.94))
        path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.64))
        path.addLine(to: CGPoint(x: w, y: h * 0.5))
        path.closeSubpath()
        return path
    }
}
