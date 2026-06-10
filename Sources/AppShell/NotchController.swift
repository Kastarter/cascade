import AppKit
import CascadeDesignSystem
import ComputerUseKit
import SwiftUI

/// A Dynamic-Island-style HUD that hangs from the top-center of the screen and
/// carries Cascade's live status (recording + voice) plus quick controls (settings,
/// theme), so the indicators live in the "notch" instead of inside the app window.
///
/// It's a borderless, non-activating floating panel at the shielding window level
/// that joins every Space — the same window recipe the companion cursor uses — so it
/// stays pinned over the menu bar and over any app's full-screen Space without ever
/// stealing focus. Collapsed it's a slim black tab; hovering expands it into the
/// full control cluster.
@MainActor
public final class NotchController: ObservableObject {
    private var panel: NotchPanel?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Bounding panel size — fits the expanded drop-down; the collapsed tab is
    /// centered inside, leaving transparent (non-interactive) margins.
    private let panelWidth: CGFloat = 740
    private let panelHeight: CGFloat = 104

    public init() {}

    /// Builds the notch HUD bound to the live app model and shows it. Idempotent.
    public func attach(model: CascadeAppModel) {
        guard panel == nil else { reposition(); panel?.orderFrontRegardless(); return }
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        let host = NSHostingView(
            rootView: NotchView(
                model: model,
                panelWidth: panelWidth,
                panelHeight: panelHeight,
                baseNotch: Self.hardwareNotchSize()
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        // The notch is always a dark HUD, so resolve the adaptive design tokens to
        // their dark values regardless of the system / app appearance.
        host.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()
        observeEnvironment()
    }

    /// Removes the notch HUD.
    public func detach() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// The real hardware notch (camera housing) size, so the collapsed tab reads
    /// as an extension of it: height from the safe-area inset, width from what the
    /// auxiliary top areas leave uncovered. Falls back to a believable tab on
    /// displays without a notch.
    static func hardwareNotchSize() -> CGSize {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 200, height: 32)
        }
        return CGSize(
            width: screen.frame.width - left.width - right.width,
            height: screen.safeAreaInsets.top
        )
    }

    /// Centers the panel against the top edge of the menu-bar (notched) screen.
    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - panelWidth / 2, y: frame.maxY - panelHeight)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)), display: true)
    }

    /// Re-assert ordering when the active Space changes (entering another app's
    /// full-screen Space) and re-center when displays are reconfigured — the same
    /// guardrails the companion cursor uses to never get left behind.
    private func observeEnvironment() {
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.orderFrontRegardless() }
            }
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reposition()
                    self?.panel?.orderFrontRegardless()
                }
            }
        }
    }
}

/// Non-activating floating panel that draws above the menu bar and other apps'
/// full-screen Spaces. Unlike the companion cursor's overlay it accepts mouse events
/// (so the notch controls are clickable) but still never becomes key/main, so it
/// never steals focus from whatever the user is working in.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Notch shape

/// A tab with square top corners (flush with the screen edge) and rounded bottom
/// corners — the hardware-notch silhouette.
struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Notch view

struct NotchView: View {
    @ObservedObject var model: CascadeAppModel
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    /// Size of the real hardware notch — the collapsed tab matches it exactly so
    /// it reads as part of the housing rather than a floating pill.
    let baseNotch: CGSize
    @State private var expanded = false

    /// Three sizes: a tiny idle tab, a wider "live activity" tab that surfaces the
    /// voice state (Listening / Thinking) without a hover, and the full hover panel.
    private enum Mode { case idle, activity, expanded }

    /// A voice request is in flight, so show its state on the outside even collapsed.
    private var voiceActive: Bool { voiceState != .idle }
    private var mode: Mode { expanded ? .expanded : (voiceActive ? .activity : .idle) }

    private var size: CGSize {
        switch mode {
        // Tall enough that the control row sits fully below the housing line.
        case .expanded: CGSize(width: panelWidth - 8, height: baseNotch.height + 46)
        // Activity grows sideways for the "Listening / Thinking" text but keeps
        // the hardware height, so the housing only ever widens, never thickens.
        // The wings (±130) are where the text and dot live — the centre is the
        // physical camera housing, which has no pixels.
        case .activity: CGSize(width: baseNotch.width + 260, height: baseNotch.height)
        case .idle: baseNotch
        }
    }
    private var radius: CGFloat { expanded ? 20 : 10 }

    /// One spring for every notch state change (frame, radius, shadow, content),
    /// so the tab morphs as a single piece instead of layering competing animations.
    private static let morph = Animation.spring(response: 0.36, dampingFraction: 0.86)

    private var recording: Bool { model.recorder.status.running }
    private var voiceState: RealtimeVoice.VoiceState { model.voice.state }

    var body: some View {
        // Pin the tab to the very top edge; the rest of the panel is transparent.
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .top)
    }

    private var notch: some View {
        ZStack {
            switch mode {
            case .expanded: expandedContent
            case .activity: activityContent
            case .idle: collapsedContent
            }
        }
        .frame(width: size.width, height: size.height)
        .background(NotchShape(bottomRadius: radius).fill(Color.black))
        .overlay(NotchShape(bottomRadius: radius).stroke(Color.cascadeBorderHi.opacity(0.45), lineWidth: 1))
        .contentShape(NotchShape(bottomRadius: radius))
        .shadow(color: .black.opacity(0.55), radius: expanded ? 22 : 7, y: expanded ? 11 : 4)
        .onHover { hovering in expanded = hovering }
        .animation(Self.morph, value: mode)
    }

    // Idle: just the live indicator dots, hugging the top edge.
    private var collapsedContent: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSImage(named: "cascadeTemplate") ?? NSImage())
                .resizable().renderingMode(.template)
                .frame(width: 13, height: 13)
                .foregroundStyle(Color.cascadeAgent)
            NotchStatusDot(color: recording ? Color.cascadeRecDot : Color.cascadeText4, pulsing: recording)
            NotchStatusDot(color: voiceDotColor, pulsing: false)
        }
        .padding(.horizontal, 14)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        .onTapGesture { expandFromTap() }
    }

    // Live activity: surfaces "Listening" / "Thinking" on the outside while a voice
    // request is in flight — the whole point of the notch when a request comes in.
    private var activityContent: some View {
        HStack(spacing: 8) {
            Image(systemName: voiceState == .listening ? "waveform" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(voiceDotColor)
                .symbolEffect(.variableColor.iterative, isActive: voiceState == .listening)
            Text(voiceLabel)
                .font(.cascadeMono(11, .semibold))
                .foregroundStyle(Color.cascadeText)
                .lineLimit(1)
            Spacer(minLength: 0)
            NotchStatusDot(color: recording ? Color.cascadeRecDot : Color.cascadeText4, pulsing: recording)
        }
        .padding(.horizontal, 14)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        .onTapGesture { expandFromTap() }
    }

    /// Fallback for environments where hover doesn't fire (e.g. another app is
    /// frontmost): tapping the tab opens the full controls.
    private func expandFromTap() {
        expanded = true
    }

    // Expanded: the full status + controls cluster that used to live in the app bar.
    private var expandedContent: some View {
        HStack(spacing: CascadeMetrics.s3) {
            HStack(spacing: 7) {
                Image(nsImage: NSImage(named: "cascadeTemplate") ?? NSImage())
                    .resizable().renderingMode(.template)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(Color.cascadeAgent)
                Text("Cascade").font(.cascadeSerif(17)).foregroundStyle(Color.cascadeText)
            }

            Spacer(minLength: CascadeMetrics.s2)

            Text(Date.now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.cascadeMono(11, .medium))
                .foregroundStyle(Color.cascadeText3)

            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.cascadeText2)
            .help("Settings — access & Claude key")

            Button {
                recording ? model.pauseRecording() : model.startRecording()
            } label: {
                CascadeRecordingPill(label: recording ? "REC · LOCAL" : "PAUSED · LOCAL", active: recording)
            }
            .buttonStyle(.plain)
            .help("Everything stays on this Mac")

            HStack(spacing: 6) {
                Circle().fill(voiceDotColor).frame(width: 7, height: 7)
                Text(voiceLabel)
                    .font(.cascadeMono(11, .medium))
                    .foregroundStyle(voiceState == .idle ? Color.cascadeText3 : Color.cascadeText)
            }
            .padding(.horizontal, CascadeMetrics.s2 + 2)
            .padding(.vertical, CascadeMetrics.s1 + 1)
            .background(Color.cascadePanel2, in: Capsule())
            .overlay(Capsule().stroke(Color.cascadeBorder, lineWidth: 1))
            .help("Hold the right Command (⌘) key to talk to Cascade")

            cursorThemePicker

            Button { model.toggleTheme() } label: {
                Image(systemName: model.prefersDark ? "sun.max" : "moon").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.cascadeText2)
            .help("Toggle light / dark")
        }
        .padding(.horizontal, CascadeMetrics.s5)
        // Keep the controls below the housing line — the hardware notch has no
        // pixels, so anything level with it would be physically invisible.
        .padding(.top, baseNotch.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
    }

    /// The four companion cursors. Each swatch is a tiny version of the cursor
    /// (arrow on its colored halo); the chosen one wears a ring.
    private var cursorThemePicker: some View {
        HStack(spacing: 7) {
            ForEach(CursorTheme.allCases) { theme in
                CursorThemeSwatch(theme: theme, selected: model.cursorTheme == theme) {
                    model.cursorTheme = theme
                }
            }
        }
        .padding(.horizontal, CascadeMetrics.s2 + 2)
        .padding(.vertical, CascadeMetrics.s1 + 1)
        .background(Color.cascadePanel2, in: Capsule())
        .overlay(Capsule().stroke(Color.cascadeBorder, lineWidth: 1))
    }

    private var voiceDotColor: Color {
        switch voiceState {
        case .listening: Color.cascadeAgent
        case .working: Color.cascadeWarn
        case .idle: Color.cascadeText4
        }
    }

    private var voiceLabel: String {
        switch voiceState {
        case .listening: "Listening"
        case .working: "Thinking"
        case .idle: "Hold ⌘"
        }
    }
}

/// One cursor-theme swatch in the notch picker.
private struct CursorThemeSwatch: View {
    let theme: CursorTheme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            ZStack {
                Circle().fill(theme.core.opacity(0.30))
                Image(systemName: "cursorarrow")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.core)
            }
            .frame(width: 18, height: 18)
            .overlay(
                Circle().stroke(
                    selected ? theme.core : Color.cascadeBorder,
                    lineWidth: selected ? 1.6 : 1
                )
            )
        }
        .buttonStyle(.plain)
        .help("\(theme.displayName) — \(theme.blurb)")
    }
}

/// A small status dot that gently pulses while its state is live.
private struct NotchStatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing && pulse ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}
