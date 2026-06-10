import AppKit
import SwiftUI

// Transparent, click-through, always-on-top companion cursor. The follow-the-user-
// cursor behaviour + guide-cursor idea are adapted from `jasonkneen/openclicky`
// (`OverlayWindow.swift` / `BlueCursorView`, MIT); the pointer silhouette and the
// green mint-glow styling are adapted from `milind-soni/tiptour-macos`
// (`OverlayWindow.swift` / `CursorArrowShape`, MIT) — re-implemented as a small
// Cascade-owned companion that sits next to the user's cursor and flies to the
// element they ask about. See docs/THIRD_PARTY_NOTICES.md.

// MARK: - Cursor themes

/// The four companion cursors the user can pick from the notch, matching the
/// TipTour reference art. Each one is a full character — its own color AND its
/// own motion: green glides inside a soft halo, pink swoops in an S-curve
/// leaving a glowing ribbon, peach darts dead-straight with a comet streak, and
/// purple traces a dashed guide path that ends in a target ring. Every piece of
/// guidance chrome (cursor, trail, ripple, label pill, highlight marquee)
/// derives from the same theme so the overlay always reads as one system.
public enum CursorTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case green, pink, peach, purple

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .green: "Green"
        case .pink: "Pink"
        case .peach: "Peach"
        case .purple: "Purple"
        }
    }

    /// How the companion flies and what it leaves behind.
    public enum Motion: Sendable {
        /// Direct spring flight, big soft halo, no trail.
        case glide
        /// Curved S-flight through two offset waypoints, thick ribbon trail.
        case swoop
        /// Fast straight dart, narrow comet streak.
        case dart
        /// Calm steady flight, dashed breadcrumb path + target ring at rest.
        case trace
    }

    public var motion: Motion {
        switch self {
        case .green: .glide
        case .pink: .swoop
        case .peach: .dart
        case .purple: .trace
        }
    }

    /// One-line personality, for pickers and help text.
    public var blurb: String {
        switch self {
        case .green: "glides with a soft halo"
        case .pink: "swoops in, leaving a ribbon"
        case .peach: "darts straight with a comet streak"
        case .purple: "traces a dashed path to a target"
        }
    }

    /// Main color: the cursor's edge/glow, the trail, the ripple, the marquee.
    public var core: Color {
        switch self {
        case .green: Color(red: 0.31, green: 0.85, blue: 0.63)
        case .pink: Color(red: 0.94, green: 0.55, blue: 0.67)
        case .peach: Color(red: 1.0, green: 0.72, blue: 0.50)
        case .purple: Color(red: 0.62, green: 0.63, blue: 0.95)
        }
    }

    /// Lighter companion tint: the halo spotlight and the label-pill text.
    public var soft: Color {
        switch self {
        case .green: Color(red: 0.62, green: 0.93, blue: 0.80)
        case .pink: Color(red: 0.99, green: 0.76, blue: 0.84)
        case .peach: Color(red: 1.0, green: 0.86, blue: 0.70)
        case .purple: Color(red: 0.78, green: 0.79, blue: 0.99)
        }
    }
}

/// Per-theme trail recipe (rendering details stay internal to the overlay).
enum TrailKind { case none, comet, ribbon, dashed }

extension CursorTheme {
    var trailKind: TrailKind {
        switch motion {
        case .glide: .none
        case .swoop: .ribbon
        case .dart: .comet
        case .trace: .dashed
        }
    }

    /// How long a trail sample stays visible — the ribbon lingers, the comet is
    /// brief, the dashed guide path hangs around long enough to be followed.
    var trailMaxAge: TimeInterval {
        switch motion {
        case .glide: 0.32
        case .swoop: 0.6
        case .dart: 0.38
        case .trace: 1.3
        }
    }
}

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
    /// Drives multi-stage flights (the pink swoop); cancelled whenever a new
    /// destination arrives so stale waypoints never fight a fresh flight.
    private var flightTask: Task<Void, Never>?
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
    ///
    /// Returns the estimated flight time so the caller can wait for the cursor
    /// to actually ARRIVE before pressing — a fixed delay made long flights
    /// visibly "click" while the cursor was still mid-air.
    @discardableResult
    public func navigate(toGlobalPoint point: CGPoint) -> TimeInterval {
        startFollowing()
        orderFront()
        returnTask?.cancel()
        returnTask = nil
        state.label = ""
        state.pointing = true
        // Distance-scaled: short hops stay snappy, cross-screen flights sweep
        // smoothly instead of teleporting.
        let distance = hypot(point.x - state.globalPoint.x, point.y - state.globalPoint.y)
        let response = min(0.5, 0.16 + distance / 3200)
        moveCursor(to: point, response: response)
        switch state.theme.motion {
        case .dart: return max(0.14, response * 0.55) + 0.05
        case .swoop:
            let leg = max(0.10, response * 0.45)
            return distance > 90 ? leg * 1.7 + response * 0.8 : response + 0.05
        case .glide, .trace: return response + 0.05
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
        flightTask?.cancel()
        flightTask = nil
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

    /// Recolors the whole guidance overlay (cursor, trail, ripple, marquee).
    public func setTheme(_ theme: CursorTheme) {
        state.theme = theme
    }

    /// Fully removes the companion (used if the assistant is turned off).
    public func stop() {
        followTimer?.invalidate()
        followTimer = nil
        returnTask?.cancel()
        returnTask = nil
        flightTask?.cancel()
        flightTask = nil
        highlightTask?.cancel()
        highlightTask = nil
        state.highlightVisible = false
        state.visible = false
        windows.forEach { $0.orderOut(nil) }
    }

    /// Animates the companion to a global AppKit point, tracking which screen it's
    /// on. The flight itself is the theme's signature: green springs straight in,
    /// peach darts hard and fast, purple eases in calmly (its dashed breadcrumbs do
    /// the talking), and pink swoops through two offset waypoints so its ribbon
    /// trail draws an S-curve.
    private func moveCursor(to global: CGPoint, response: Double) {
        state.activeScreen = screenFrame(containing: global)
        flightTask?.cancel()
        flightTask = nil
        switch state.theme.motion {
        case .glide:
            withAnimation(.spring(response: response, dampingFraction: 0.74)) {
                state.globalPoint = global
            }
        case .dart:
            withAnimation(.easeOut(duration: max(0.14, response * 0.55))) {
                state.globalPoint = global
            }
        case .trace:
            withAnimation(.spring(response: response * 1.2, dampingFraction: 0.9)) {
                state.globalPoint = global
            }
        case .swoop:
            swoop(to: global, response: response)
        }
    }

    /// Pink's S-curve: two waypoints offset perpendicular to the straight line
    /// (one each side), each leg retargeting slightly before the previous lands so
    /// the motion reads as one continuous swoop. Short hops skip the theatrics.
    private func swoop(to global: CGPoint, response: Double) {
        let start = state.globalPoint
        let dx = global.x - start.x, dy = global.y - start.y
        let dist = hypot(dx, dy)
        guard dist > 90 else {
            withAnimation(.spring(response: response, dampingFraction: 0.74)) {
                state.globalPoint = global
            }
            return
        }
        let ux = -dy / dist, uy = dx / dist  // unit perpendicular
        let amp = min(110, dist * 0.22)
        let w1 = CGPoint(x: start.x + dx / 3 + ux * amp, y: start.y + dy / 3 + uy * amp)
        let w2 = CGPoint(x: start.x + dx * 2 / 3 - ux * amp, y: start.y + dy * 2 / 3 - uy * amp)
        let leg = max(0.10, response * 0.45)
        flightTask = Task { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: leg)) { self.state.globalPoint = w1 }
            try? await Task.sleep(for: .seconds(leg * 0.85))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: leg)) { self.state.globalPoint = w2 }
            try? await Task.sleep(for: .seconds(leg * 0.85))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: response * 0.8, dampingFraction: 0.7)) {
                self.state.globalPoint = global
            }
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
    /// Colorway for every piece of guidance chrome.
    @Published var theme: CursorTheme = .green
}

/// A non-activating floating panel — unlike a plain NSWindow, this reliably draws
/// over *another* app's native full-screen Space (where the guide cursor was
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
                MarchingAntsBox(rect: box, color: state.theme.core)
            }
            // The theme's motion trail behind the companion during a flight — pink's
            // ribbon, peach's comet streak, purple's dashed guide path. Green leaves
            // none; its halo is the identity.
            if state.theme.trailKind != .none {
                CursorTrailView(store: trail, theme: state.theme)
            }
            if let point = localPoint {
                // Purple plants a target ring at the destination the moment the
                // flight starts (the model point IS the target; only the rendered
                // offset animates) — the dashed path then leads the eye to it.
                if state.pointing, state.theme.motion == .trace {
                    TargetRing(core: state.theme.core, soft: state.theme.soft)
                        .offset(x: point.x - 28, y: point.y - 28)
                        .transaction { $0.animation = nil }
                }
                PressRipple(trigger: state.pressTrigger, color: state.theme.core)
                    .offset(x: point.x - 17, y: point.y - 17)
                GuideCursor(theme: state.theme, label: state.pointing ? state.label : "", pointing: state.pointing, pressTrigger: state.pressTrigger)
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

/// Animated "marching ants" rectangle that frames a region of the screen, drawn
/// in the cursor theme's color so the marquee always matches the companion.
struct MarchingAntsBox: View {
    let rect: CGRect
    let color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.10))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(color.opacity(0.30), lineWidth: 5)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.8, dash: [7, 4], dashPhase: phase))
        }
        .frame(width: rect.width, height: rect.height)
        .shadow(color: color.opacity(0.35), radius: 10)
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
    /// Hard ceiling on sample retention; each theme reads a shorter window via
    /// `visibleSamples(now:maxAge:)` (the dashed guide path lives longest).
    private let hardMaxAge: TimeInterval = 1.5
    private let maxCount = 64

    /// Records a position if it has moved enough to matter, then drops anything
    /// older than `hardMaxAge` so a parked cursor's trail empties itself.
    func record(_ point: CGPoint, at now: TimeInterval) {
        if let last = samples.last, hypot(point.x - last.point.x, point.y - last.point.y) < 1.2 {
            return
        }
        samples.append((point, now))
        samples.removeAll { now - $0.t > hardMaxAge }
        if samples.count > maxCount {
            samples.removeFirst(samples.count - maxCount)
        }
    }

    /// Currently-visible samples (oldest → newest) with a freshness weight in 0…1,
    /// where 1 is right behind the cursor and 0 is the dissolving tail.
    func visibleSamples(now: TimeInterval, maxAge: TimeInterval) -> [(point: CGPoint, freshness: Double)] {
        let window = min(maxAge, hardMaxAge)
        return samples.compactMap { sample in
            let age = now - sample.t
            guard age >= 0, age <= window else { return nil }
            return (sample.point, 1 - age / window)
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

/// Renders the theme's motion trail. Comet (peach) and ribbon (pink) are stacked,
/// blurred passes — a wide soft halo, a tighter glow, and a crisp core — each
/// segment tapering and fading toward the tail; the ribbon is simply a much fatter,
/// longer-lived comet, like the reference art's pink swoosh. Dashed (purple) is a
/// single dotted breadcrumb stroke with a faint glow, left for the eye to follow.
private struct CursorTrailView: View {
    let store: CursorTrailStore
    let theme: CursorTheme

    /// Number of bands the trail is sliced into for its fade. More bands = a
    /// smoother gradient; any residual stepping is hidden by the layers' blur.
    private let bandCount = 24

    private var color: Color { theme.core }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let points = store.visibleSamples(now: now, maxAge: theme.trailMaxAge).map(\.point)
            let path = Self.smoothPath(through: points)
            ZStack {
                switch theme.trailKind {
                case .none:
                    EmptyView()
                case .comet:
                    layer(path, lineWidth: 11, maxOpacity: 0.10, blur: 12)
                    layer(path, lineWidth: 6, maxOpacity: 0.22, blur: 5)
                    layer(path, lineWidth: 3, maxOpacity: 0.60, blur: 0)
                case .ribbon:
                    layer(path, lineWidth: 26, maxOpacity: 0.18, blur: 16)
                    layer(path, lineWidth: 15, maxOpacity: 0.38, blur: 6)
                    layer(path, lineWidth: 9, maxOpacity: 0.85, blur: 0)
                case .dashed:
                    dashedLayer(path, lineWidth: 7, opacity: 0.25, blur: 5)
                    dashedLayer(path, lineWidth: 3, opacity: 0.9, blur: 0)
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Dotted breadcrumb stroke — round dots with even gaps, no taper, so the
    /// path reads as a guide to follow rather than exhaust behind the cursor.
    private func dashedLayer(_ path: Path, lineWidth: CGFloat, opacity: Double, blur: CGFloat) -> some View {
        Canvas { context, _ in
            guard !path.isEmpty else { return }
            context.stroke(
                path,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [0.1, 11])
            )
        }
        .blur(radius: blur)
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

/// Purple's destination marker: a soft-filled double ring pinned at the flight
/// target (like the reference art's "Guide me" bullseye), gently pulsing while
/// the companion is parked on it.
private struct TargetRing: View {
    let core: Color
    let soft: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(soft.opacity(0.16))
            Circle().stroke(soft.opacity(0.6), lineWidth: 1.5).padding(4)
            Circle().stroke(core, lineWidth: 2).padding(14)
        }
        .frame(width: 56, height: 56)
        .scaleEffect(pulse ? 1.06 : 0.96)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
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

/// Guide cursor in TipTour's style: the Lucide "mouse-pointer-2" glyph drawn as a
/// white arrow with a colored edge, sitting inside a soft matching halo. Built
/// from stacked layers — wide halo → soft glow → white core → colored stroke — so
/// it reads as a luminous glyph rather than a flat fill. It breathes gently while
/// parked pointing at something and pulses on press. Colors come from the user's
/// chosen `CursorTheme`.
struct GuideCursor: View {
    var theme: CursorTheme = .green
    let label: String
    var pointing: Bool = false
    var pressTrigger: Int = 0
    @State private var pressed = false
    @State private var breathing = false

    private var green: Color { theme.core }
    private var mint: Color { theme.soft }
    private let glyphSize: CGFloat = 24
    /// The glyph's tip sits ~4.2/24 into its viewbox; pull it back so the tip lands
    /// on the companion's anchor point (this view's top-leading corner), matching
    /// where the press ripple centres and where flights aim.
    private var tipInset: CGFloat { glyphSize * 4.2 / 24 }

    /// The layered glyph: seafoam halo → soft green glow → white core → green edge.
    private var arrow: some View {
        ZStack {
            PointerShape().fill(green)
                .blur(radius: 9)
                .opacity(breathing ? 0.72 : 0.50)
            PointerShape().fill(green)
                .blur(radius: 3)
                .opacity(0.45)
            PointerShape().fill(.white)
            PointerShape().stroke(
                green,
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: glyphSize, height: glyphSize)
        .background {
            // The big spotlight is green's signature; the other cursors get their
            // identity from their trails (ribbon / comet / dashed path) instead.
            if theme.motion == .glide { halo }
        }
        .offset(x: -tipInset, y: -tipInset)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    /// The big soft spotlight behind the arrow — the README-glow look.
    /// A background, so it never affects layout or the tip's anchor.
    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [mint.opacity(breathing ? 0.40 : 0.28), mint.opacity(0)],
                    center: .center, startRadius: 0, endRadius: 46
                )
            )
            .frame(width: 92, height: 92)
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
                    .foregroundStyle(mint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(green.opacity(0.8), lineWidth: 1.2))
                    .shadow(color: green.opacity(0.4), radius: 9)
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .fixedSize()
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: label)
    }
}

/// Lucide "mouse-pointer-2" silhouette, ported from `milind-soni/tiptour-macos`
/// (`OverlayWindow.swift` / `CursorArrowShape`, MIT). Tip points up-left, at
/// roughly (4.2, 4.2) of its 24-point viewbox.
private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let viewBoxSize: CGFloat = 24
        let scale = min(rect.width, rect.height) / viewBoxSize
        let originX = rect.midX - (viewBoxSize * scale / 2)
        let originY = rect.midY - (viewBoxSize * scale / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        path.move(to: point(4.037, 4.688))
        path.addQuadCurve(to: point(4.688, 4.037), control: point(3.90, 3.90))
        path.addLine(to: point(20.688, 10.537))
        path.addQuadCurve(to: point(20.625, 11.484), control: point(21.42, 10.84))
        path.addLine(to: point(14.501, 13.064))
        path.addQuadCurve(to: point(13.063, 14.499), control: point(13.43, 13.34))
        path.addLine(to: point(11.484, 20.625))
        path.addQuadCurve(to: point(10.537, 20.688), control: point(11.17, 21.42))
        path.closeSubpath()
        return path
    }
}
