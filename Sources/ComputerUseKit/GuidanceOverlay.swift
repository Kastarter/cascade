import AppKit
import SwiftUI

// Transparent, click-through, always-on-top companion cursor. The follow-the-user-
// cursor behaviour + blue-cursor idea are adapted from `jasonkneen/openclicky`
// (`OverlayWindow.swift` / `BlueCursorView`, MIT) — re-implemented as a small
// Cascade-owned companion that sits next to the user's cursor and flies to the
// element they ask about. See docs/THIRD_PARTY_NOTICES.md.

@MainActor
public final class GuidanceOverlayController {
    // One window PER SCREEN, each sized to its screen. A single window spanning the
    // union of displays will NOT promote into a per-display full-screen Space (the
    // cursor vanishes in fullscreen) — openclicky uses per-screen windows for exactly
    // this reason.
    private var windows: [GuidanceOverlayWindow] = []
    private let state = GuidanceState()
    private var followTimer: Timer?
    private var returnTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var reorderTick = 0

    /// Where the companion sits relative to the real cursor tip (points; +x right, +y down).
    private let followOffset = CGSize(width: 18, height: 14)

    public init() {}

    /// Shows the companion cursor and has it continuously follow the user's cursor.
    /// Idempotent.
    public func startFollowing() {
        ensureWindows()
        state.visible = true
        state.pointing = false
        orderFront()
        observeEnvironment()
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
        orderFront()
        state.label = label
        state.pointing = true
        moveCursor(to: point, response: 0.35)
        returnTask?.cancel()
        returnTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            let mouse = NSEvent.mouseLocation
            self.moveCursor(to: CGPoint(x: mouse.x + self.followOffset.width, y: mouse.y - self.followOffset.height), response: 0.4)
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
        orderFront()
        returnTask?.cancel()
        returnTask = nil
        state.label = ""
        state.pointing = true
        // Quick, snappy flight — the blue cursor should arrive fast, not amble.
        moveCursor(to: point, response: 0.18)
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

    /// Frames a region of the screen with the dashed golden marquee (for "where do I
    /// find/do X" answers), auto-clearing after `seconds`.
    public func highlight(globalRect: CGRect, seconds: TimeInterval = 6) {
        startFollowing()
        orderFront()
        state.highlightScreen = screenFrame(containing: CGPoint(x: globalRect.midX, y: globalRect.midY))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            state.highlightRect = globalRect
            state.highlightVisible = true
        }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.state.highlightVisible = false }
        }
    }

    public func clearHighlight() {
        highlightTask?.cancel()
        highlightTask = nil
        state.highlightVisible = false
    }

    /// Fully removes the companion (used if the assistant is turned off).
    public func stop() {
        followTimer?.invalidate()
        followTimer = nil
        returnTask?.cancel()
        returnTask = nil
        highlightTask?.cancel()
        highlightTask = nil
        state.highlightVisible = false
        state.visible = false
        windows.forEach { $0.orderOut(nil) }
    }

    /// Animates the companion to a global AppKit point, tracking which screen it's on.
    private func moveCursor(to global: CGPoint, response: Double) {
        state.activeScreen = screenFrame(containing: global)
        withAnimation(.spring(response: response, dampingFraction: 0.74)) {
            state.globalPoint = global
        }
    }

    private func follow() {
        // Re-assert the panel onto the active Space a few times a second. Entering an
        // app's full-screen Space doesn't reliably fire activeSpaceDidChange, so this
        // is what guarantees the cursor reappears over fullscreen.
        reorderTick &+= 1
        if reorderTick % 24 == 0, state.visible { orderFront() }

        guard state.visible, !state.pointing else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x + followOffset.width, y: mouse.y - followOffset.height)
        let screen = screenFrame(containing: point)
        if state.activeScreen != screen { state.activeScreen = screen }
        if abs(point.x - state.globalPoint.x) > 0.5 || abs(point.y - state.globalPoint.y) > 0.5 {
            state.globalPoint = point
        }
    }

    /// Frame of the screen containing `point`, or the nearest screen if it's off all of them.
    private func screenFrame(containing point: CGPoint) -> CGRect {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen.frame
        }
        let nearest = NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) }
        return (nearest ?? NSScreen.main)?.frame ?? .zero
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let cx = min(max(point.x, rect.minX), rect.maxX)
        let cy = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - cx, point.y - cy)
    }

    private func orderFront() { windows.forEach { $0.orderFrontRegardless() } }

    /// Creates/prunes one overlay window per current screen, each sized to that screen.
    private func ensureWindows() {
        let screens = NSScreen.screens
        windows.removeAll { window in
            if !screens.contains(where: { $0.frame == window.frame }) {
                window.orderOut(nil)
                return true
            }
            return false
        }
        for screen in screens where !windows.contains(where: { $0.frame == screen.frame }) {
            let overlay = GuidanceOverlayWindow(frame: screen.frame)
            overlay.contentView = NSHostingView(rootView: GuidanceOverlayView(state: state, screenFrame: screen.frame))
            windows.append(overlay)
        }
    }

    /// Re-assert ordering when the active Space changes (entering an app's full-screen
    /// Space) or when displays are reconfigured, so the cursor never gets left behind.
    private func observeEnvironment() {
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state.visible else { return }
                    self.orderFront()
                }
            }
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ensureWindows()
                    if self.state.visible { self.orderFront() }
                }
            }
        }
    }
}

final class GuidanceState: ObservableObject {
    /// Companion position in global AppKit coordinates (bottom-left origin). Each
    /// per-screen window maps this into its own local space.
    @Published var globalPoint: CGPoint = .zero
    /// Frame of the screen the companion is currently on; only that window draws it.
    @Published var activeScreen: CGRect = .zero
    @Published var label: String = ""
    @Published var pointing = false
    @Published var visible = false
    /// Bumped on every press so the overlay can fire a one-shot tap ripple.
    @Published var pressTrigger = 0
    /// Dashed marquee that frames a region for "where do I find/do X" answers.
    @Published var highlightRect: CGRect = .zero    // global AppKit (bottom-left)
    @Published var highlightScreen: CGRect = .zero
    @Published var highlightVisible = false
}

/// A non-activating floating panel — unlike a plain NSWindow, this reliably draws
/// over *another* app's native full-screen Space (where the blue cursor was
/// vanishing) without ever stealing focus.
final class GuidanceOverlayWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        // Above the menu bar and other apps' full-screen content.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
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
    let screenFrame: CGRect
    @State private var trail = CursorTrailStore()
    private let blue = Color(red: 0.20, green: 0.55, blue: 1.0)

    /// Global companion point mapped into this window's local (top-left) space, or
    /// nil when the companion is on a different screen.
    private var localPoint: CGPoint? {
        guard state.visible, state.activeScreen == screenFrame else { return nil }
        let x = state.globalPoint.x - screenFrame.minX
        let yFromBottom = state.globalPoint.y - screenFrame.minY
        return CGPoint(
            x: min(max(x, 0), screenFrame.width),
            y: min(max(screenFrame.height - yFromBottom, 0), screenFrame.height)
        )
    }

    /// Highlight rect mapped into this window's local (top-left) space.
    private var highlightLocalRect: CGRect? {
        guard state.highlightVisible, state.highlightScreen == screenFrame, state.highlightRect.width > 1 else { return nil }
        let r = state.highlightRect
        let yFromBottom = r.minY - screenFrame.minY
        return CGRect(
            x: r.minX - screenFrame.minX,
            y: screenFrame.height - (yFromBottom + r.height),
            width: r.width, height: r.height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let box = highlightLocalRect {
                MarchingAntsBox(rect: box)
            }
            // Glowing comet-streak behind the companion during a flight. Sits below
            // the cursor and fades on its own once the cursor stops moving.
            CursorTrailView(store: trail, color: blue)
            if let point = localPoint {
                PressRipple(trigger: state.pressTrigger, color: blue)
                    .offset(x: point.x - 17, y: point.y - 17)
                GuideCursor(label: state.pointing ? state.label : "", pointing: state.pointing, pressTrigger: state.pressTrigger)
                    .offset(x: point.x, y: point.y)
                    // Rides the same spring the offset uses, sampling each interpolated
                    // position into the trail buffer. Only records while pointing/flying.
                    .modifier(FlightSampler(point: point, store: trail, recording: state.pointing))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Animated golden "marching ants" rectangle that frames a region of the screen.
struct MarchingAntsBox: View {
    let rect: CGRect
    @State private var phase: CGFloat = 0
    private let gold = Color(red: 1.0, green: 0.86, blue: 0.25)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(gold.opacity(0.10))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(gold.opacity(0.30), lineWidth: 5)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(gold, style: StrokeStyle(lineWidth: 1.8, dash: [7, 4], dashPhase: phase))
        }
        .frame(width: rect.width, height: rect.height)
        .shadow(color: gold.opacity(0.35), radius: 10)
        .position(x: rect.midX, y: rect.midY)
        .transition(.scale(scale: 1.04).combined(with: .opacity))
        .onAppear {
            withAnimation(.linear(duration: 0.55).repeatForever(autoreverses: false)) { phase = -11 }
        }
    }
}

/// Plain (non-observable) ring buffer of recent companion positions, each stamped
/// with the time it was captured. Mutated from the flight sampler and read by the
/// trail renderer; kept off SwiftUI's state graph so neither side invalidates the
/// other — the renderer's TimelineView clock drives drawing instead.
final class CursorTrailStore {
    private var samples: [(point: CGPoint, t: TimeInterval)] = []
    /// How long a sample stays visible. Short enough to read as a wisp hugging the
    /// cursor, long enough to trace the arc of a quick flight.
    let maxAge: TimeInterval = 0.32
    private let maxCount = 24

    /// Records a position if it has moved enough to matter, then drops anything
    /// older than `maxAge` so a parked cursor's trail empties itself.
    func record(_ point: CGPoint, at now: TimeInterval) {
        if let last = samples.last, hypot(point.x - last.point.x, point.y - last.point.y) < 1.2 {
            return
        }
        samples.append((point, now))
        samples.removeAll { now - $0.t > maxAge }
        if samples.count > maxCount {
            samples.removeFirst(samples.count - maxCount)
        }
    }

    /// Currently-visible samples (oldest → newest) with a freshness weight in 0…1,
    /// where 1 is right behind the cursor and 0 is the dissolving tail.
    func visibleSamples(now: TimeInterval) -> [(point: CGPoint, freshness: Double)] {
        samples.compactMap { sample in
            let age = now - sample.t
            guard age >= 0, age <= maxAge else { return nil }
            return (sample.point, 1 - age / maxAge)
        }
    }
}

/// `Animatable` no-op modifier: its animatable data is the companion's position, so
/// when SwiftUI interpolates the cursor's offset along the controller's spring, the
/// setter fires once per frame with each in-between point. We pipe those into the
/// trail store. It never changes how the cursor moves — it only watches.
private struct FlightSampler: ViewModifier, @MainActor Animatable {
    var point: CGPoint
    let store: CursorTrailStore
    let recording: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(point.x, point.y) }
        set {
            point = CGPoint(x: newValue.first, y: newValue.second)
            if recording {
                store.record(point, at: Date().timeIntervalSinceReferenceDate)
            }
        }
    }

    func body(content: Content) -> some View { content }
}

/// Renders the trail as three stacked, blurred passes — a wide soft halo, a tighter
/// glow, and a crisp core — each segment tapering and fading toward the tail so the
/// streak reads like a highlighter dissolving into nothing behind the cursor.
private struct CursorTrailView: View {
    let store: CursorTrailStore
    let color: Color

    /// Number of bands the trail is sliced into for its fade. More bands = a
    /// smoother gradient; any residual stepping is hidden by the layers' blur.
    private let bandCount = 24

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let points = store.visibleSamples(now: now).map(\.point)
            let path = Self.smoothPath(through: points)
            ZStack {
                layer(path, lineWidth: 11, maxOpacity: 0.10, blur: 12)
                layer(path, lineWidth: 6, maxOpacity: 0.22, blur: 5)
                layer(path, lineWidth: 3, maxOpacity: 0.60, blur: 0)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Strokes the single smoothed path in `bandCount` slices. Each slice tapers
    /// thinner and fainter toward the tail (fraction 0), full at the head (1),
    /// so the streak reads as one continuous comet rather than stitched segments.
    private func layer(_ path: Path, lineWidth: CGFloat, maxOpacity: Double, blur: CGFloat) -> some View {
        Canvas { context, _ in
            guard !path.isEmpty else { return }
            for band in 0..<bandCount {
                let start = CGFloat(band) / CGFloat(bandCount)
                let end = CGFloat(band + 1) / CGFloat(bandCount)
                let fraction = Double((start + end) / 2)  // 0 = tail, 1 = head
                context.stroke(
                    path.trimmedPath(from: start, to: end),
                    with: .color(color.opacity(maxOpacity * pow(fraction, 1.5))),
                    style: StrokeStyle(
                        lineWidth: lineWidth * (0.35 + 0.65 * fraction),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .blur(radius: blur)
    }

    /// Catmull-Rom spline through the sample points, expressed as cubic Béziers,
    /// so the trail is one continuous smooth curve instead of straight chords.
    private static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        guard points.count > 2 else {
            path.move(to: points[0])
            path.addLine(to: points[1])
            return path
        }
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

/// One-shot click bloom centred on the cursor tip — a soft glow flash plus a
/// crisp expanding ring, so a press reads as a little burst of light.
private struct PressRipple: View {
    let trigger: Int
    let color: Color
    @State private var ringScale: CGFloat = 0.2
    @State private var ringOpacity: Double = 0
    @State private var flashScale: CGFloat = 0.1
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack {
            // Soft radial bloom — a quick puff of colour at the contact point.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.5), color.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 18
                    )
                )
                .frame(width: 36, height: 36)
                .scaleEffect(flashScale)
                .opacity(flashOpacity)
            // Expanding ring — the crisp "click" wavefront.
            Circle()
                .stroke(color, lineWidth: 2.5)
                .frame(width: 34, height: 34)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
        }
        .frame(width: 34, height: 34)
        .onChange(of: trigger) { _, _ in
            ringScale = 0.25; ringOpacity = 0.85
            flashScale = 0.1; flashOpacity = 0.6
            withAnimation(.easeOut(duration: 0.45)) {
                ringScale = 1.35
                ringOpacity = 0
            }
            withAnimation(.easeOut(duration: 0.3)) {
                flashScale = 1.0
                flashOpacity = 0
            }
        }
    }
}

/// Blue arrow cursor sized to match the system cursor (tip at the top-left origin).
/// Built from stacked layers — a soft halo, a tighter inner glow, a gradient core,
/// and a crisp white edge — so it reads as a luminous glyph rather than a flat
/// fill. It breathes gently while parked pointing at something and pulses on press.
struct GuideCursor: View {
    let label: String
    var pointing: Bool = false
    var pressTrigger: Int = 0
    @State private var pressed = false
    @State private var breathing = false

    private let core = Color(red: 0.20, green: 0.55, blue: 1.0)
    private let coreLight = Color(red: 0.58, green: 0.80, blue: 1.0)
    private let glow = Color(red: 0.26, green: 0.62, blue: 1.0)

    /// The layered glyph: halo → inner glow → gradient core → white edge.
    private var arrow: some View {
        ZStack {
            ArrowShape().fill(glow)
                .blur(radius: 10)
                .opacity(breathing ? 0.66 : 0.46)
            ArrowShape().fill(glow)
                .blur(radius: 3)
                .opacity(0.55)
            ArrowShape().fill(
                LinearGradient(colors: [coreLight, core], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            ArrowShape().stroke(.white, lineWidth: 1.1)
        }
        .frame(width: 12, height: 16)
        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            arrow
                .scaleEffect(pressed ? 0.74 : 1.0, anchor: .topLeading)
                .scaleEffect(breathing ? 1.045 : 1.0, anchor: .topLeading)
                .onChange(of: pressTrigger) { _, _ in
                    pressed = true
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { pressed = false }
                }
                .onChange(of: pointing) { _, isPointing in
                    if isPointing {
                        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                            breathing = true
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) { breathing = false }
                    }
                }

            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(colors: [Color(red: 0.30, green: 0.61, blue: 1.0), core],
                                       startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    .shadow(color: glow.opacity(0.5), radius: 9)
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
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
