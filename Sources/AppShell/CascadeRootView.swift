import AppKit
import CascadeDesignSystem
import CascadeMemory
import MacContextKit
import SuggestionEngine
import SwiftUI

// MARK: - App visuals (real app icons + stable per-app colors)

@MainActor
enum AppVisuals {
    static let palette: [Color] = [
        .cascadeAccent, .cascadeAgent, Color(red: 0.55, green: 0.78, blue: 0.55),
        Color(red: 0.78, green: 0.55, blue: 0.86), Color(red: 0.93, green: 0.74, blue: 0.40),
        Color(red: 0.40, green: 0.74, blue: 0.86), Color(red: 0.90, green: 0.52, blue: 0.55),
        Color(red: 0.58, green: 0.62, blue: 0.70), .cascadeAccentWarm,
    ]

    /// Crisp brand colors for common apps whose icon-average reads muddy (most
    /// multi-color icons do). Matched by a lowercased substring of the app name;
    /// order specific → generic so e.g. "Xcode" doesn't match "code".
    private static let brandColors: [(match: String, color: Color)] = [
        ("cascade", .cascadeAccentWarm),
        ("google chrome", Color(red: 0.26, green: 0.52, blue: 0.96)),
        ("chrome", Color(red: 0.26, green: 0.52, blue: 0.96)),
        ("safari", Color(red: 0.11, green: 0.56, blue: 0.96)),
        ("arc", Color(red: 0.95, green: 0.44, blue: 0.50)),
        ("firefox", Color(red: 0.96, green: 0.55, blue: 0.16)),
        ("xcode", Color(red: 0.13, green: 0.50, blue: 0.97)),
        ("visual studio code", Color(red: 0.14, green: 0.53, blue: 0.86)),
        ("code", Color(red: 0.14, green: 0.53, blue: 0.86)),
        ("cursor", Color(red: 0.49, green: 0.53, blue: 0.96)),
        ("iterm", Color(red: 0.20, green: 0.80, blue: 0.46)),
        ("terminal", Color(red: 0.24, green: 0.78, blue: 0.56)),
        ("warp", Color(red: 0.40, green: 0.52, blue: 0.98)),
        ("slack", Color(red: 0.55, green: 0.32, blue: 0.56)),
        ("discord", Color(red: 0.35, green: 0.40, blue: 0.95)),
        ("figma", Color(red: 0.64, green: 0.36, blue: 0.95)),
        ("notion", Color(red: 0.62, green: 0.62, blue: 0.58)),
        ("finder", Color(red: 0.16, green: 0.61, blue: 0.94)),
        ("mail", Color(red: 0.22, green: 0.55, blue: 0.96)),
        ("messages", Color(red: 0.27, green: 0.78, blue: 0.36)),
        ("spotify", Color(red: 0.11, green: 0.73, blue: 0.33)),
        ("zoom", Color(red: 0.16, green: 0.53, blue: 0.97)),
        ("notes", Color(red: 0.97, green: 0.78, blue: 0.32)),
        ("preview", Color(red: 0.36, green: 0.66, blue: 0.96)),
    ]

    private static var colorCache: [String: Color] = [:]

    /// Resolves an app to its real brand/icon color: curated brand map first, then
    /// the dominant color extracted from the actual app icon, then a stable hash
    /// fallback. Cached by bundle id (or name) so the timeline doesn't recompute.
    static func color(for app: String, bundleIdentifier: String? = nil) -> Color {
        let key = bundleIdentifier ?? app
        if let cached = colorCache[key] { return cached }
        let resolved = resolve(app: app, bundleIdentifier: bundleIdentifier)
        colorCache[key] = resolved
        return resolved
    }

    private static func resolve(app: String, bundleIdentifier: String?) -> Color {
        let lower = app.lowercased()
        if let brand = brandColors.first(where: { lower.contains($0.match) }) {
            return brand.color
        }
        if let dominant = dominantIconColor(app: app, bundleIdentifier: bundleIdentifier) {
            return dominant
        }
        return hashColor(app)
    }

    private static func hashColor(_ app: String) -> Color {
        var hash = 5381
        for byte in app.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    /// Pulls a representative color from the app's real icon: average the saturated,
    /// non-transparent, non-gray pixels (so white/black backgrounds don't wash it
    /// out), then lift saturation/brightness so it reads on the dark timeline.
    private static func dominantIconColor(app: String, bundleIdentifier: String?) -> Color? {
        guard let icon = icon(forBundle: bundleIdentifier) ?? icon(forAppNamed: app),
              let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let side = 24
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &buffer,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rAcc = 0.0, gAcc = 0.0, bAcc = 0.0, weight = 0.0
        for pixel in stride(from: 0, to: buffer.count, by: 4) {
            let a = Double(buffer[pixel + 3]) / 255.0
            guard a > 0.25 else { continue }
            // Un-premultiply to recover the straight color.
            let r = min(1, Double(buffer[pixel]) / 255.0 / a)
            let g = min(1, Double(buffer[pixel + 1]) / 255.0 / a)
            let b = min(1, Double(buffer[pixel + 2]) / 255.0 / a)
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            guard saturation > 0.12, maxC > 0.12, maxC < 0.98 else { continue }
            let w = saturation * a
            rAcc += r * w; gAcc += g * w; bAcc += b * w; weight += w
        }
        guard weight > 0 else { return nil }
        let base = NSColor(srgbRed: rAcc / weight, green: gAcc / weight, blue: bAcc / weight, alpha: 1)
        guard let srgb = base.usingColorSpace(.sRGB) else { return Color(nsColor: base) }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let lifted = NSColor(
            hue: h,
            saturation: min(max(s, 0.45), 0.9),
            brightness: min(max(v, 0.62), 0.92),
            alpha: 1
        )
        return Color(nsColor: lifted)
    }

    static func icon(forBundle id: String?) -> NSImage? {
        guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Best-effort icon for an app we only know by name — matches a running app by
    /// its localized name. Lets the timeline tint by the app's *real* icon even when
    /// a recorded moment didn't capture a bundle id, so one app keeps one color.
    static func icon(forAppNamed name: String) -> NSImage? {
        guard let url = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == name })?.bundleURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Root

public struct CascadeRootView: View {
    @ObservedObject private var model: CascadeAppModel

    public init(model: CascadeAppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.cascadeBG.ignoresSafeArea()
            VStack(spacing: 0) {
                CascadeTopBar(model: model)
                if model.showSettings {
                    SettingsScreen(model: model)
                } else {
                    switch model.selectedTab {
                    case .reel: ReelScreen(model: model)
                    case .cascades: CascadesScreen(model: model)
                    case .manager: ManagerScreen(model: model)
                    }
                }
            }
            if model.dock.visible {
                ControlDockView(model: model)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.showOnboarding {
                OnboardingScreen(model: model)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Color.cascadeText)
        .frame(minWidth: 1040, minHeight: 720)
        .preferredColorScheme(model.prefersDark ? .dark : .light)
        .animation(.easeOut(duration: 0.18), value: model.dock.visible)
        .animation(.easeOut(duration: 0.22), value: model.showOnboarding)
    }
}

// MARK: - First-run onboarding (permissions + keys, the first five minutes)

private struct OnboardingScreen: View {
    @ObservedObject var model: CascadeAppModel
    @State private var claudeKey = ""

    private var permissions: CapturePermissionStatus { model.recorder.status.permissions }
    private var canRecord: Bool { permissions.screenRecording }
    private var canAct: Bool { permissions.accessibility && permissions.inputMonitoring }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CascadeMetrics.s5) {
                    header
                    step(number: 1, title: "Record", done: canRecord,
                         detail: "Screen Recording lets Cascade keep your local, rewindable record. Frames never leave this Mac.") {
                        HStack {
                            PermissionRow(name: "Screen Recording", granted: permissions.screenRecording)
                            Spacer()
                            Button("Grant") { model.requestScreenRecording() }.buttonStyle(CascadeAccentButtonStyle())
                        }
                    }
                    step(number: 2, title: "Act", done: canAct,
                         detail: "Accessibility + Input Monitoring let agents click and type for you — with the visible companion cursor, Esc to stop, and a full audit trail.") {
                        VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                            HStack {
                                PermissionRow(name: "Accessibility", granted: permissions.accessibility)
                                Spacer()
                                Button("Grant") { model.requestAccessibility() }.buttonStyle(CascadeQuietButtonStyle())
                            }
                            HStack {
                                PermissionRow(name: "Input Monitoring", granted: permissions.inputMonitoring)
                                Spacer()
                                Button("Grant") { model.requestInputMonitoring() }.buttonStyle(CascadeQuietButtonStyle())
                            }
                        }
                    }
                    step(number: 3, title: "Think", done: model.hasAnthropicKey,
                         detail: "A Claude key powers grounded answers, where-is-X pointing, and the agents. Stored in the macOS Keychain.") {
                        HStack(spacing: CascadeMetrics.s2) {
                            SecureField("sk-ant-…", text: $claudeKey)
                                .textFieldStyle(.plain)
                                .font(.cascadeMono(12))
                                .padding(.horizontal, CascadeMetrics.s3)
                                .padding(.vertical, CascadeMetrics.s2)
                                .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Button("Save") {
                                model.saveAnthropicKey(claudeKey)
                                claudeKey = ""
                            }
                            .buttonStyle(CascadeAccentButtonStyle())
                            .disabled(claudeKey.isEmpty)
                        }
                    }
                    footer
                }
                .padding(CascadeMetrics.s6)
                .frame(maxWidth: 620)
                .background(Color.cascadePanel, in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous)
                        .stroke(Color.cascadeBorderHi, lineWidth: 1)
                )
                .cascadeWindowShadow()
                .padding(CascadeMetrics.s6)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.refreshPermissionState() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
            CascadeTag("Welcome to Cascade", tone: .cascadeAgent)
            Text("Three steps and it just works").font(.cascadeSerif(28))
            Text("Cascade records your work locally, answers from the record, and turns the tasks you repeat into agents you supervise. Everything below stays on this Mac.")
                .font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
        }
    }

    private func step(number: Int, title: String, done: Bool, detail: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            HStack(spacing: CascadeMetrics.s2) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(done ? Color.cascadeGood : Color.cascadeAgent)
                Text(title).font(.cascadeSans(15, .semibold))
            }
            Text(detail).font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            content()
        }
        .padding(CascadeMetrics.s4)
        .background(Color.cascadePanel2.opacity(0.5), in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }

    private var footer: some View {
        HStack {
            Button("Refresh status") { model.refreshPermissionState() }.buttonStyle(CascadeQuietButtonStyle())
            Text("Voice (optional) and everything else live in Settings.")
                .font(.cascadeSans(11)).foregroundStyle(Color.cascadeText4)
            Spacer()
            Button(canRecord ? "Start using Cascade  →" : "Skip for now") { model.finishOnboarding() }
                .buttonStyle(CascadeAccentButtonStyle())
        }
    }
}

// MARK: - Top bar

private struct CascadeTopBar: View {
    @ObservedObject var model: CascadeAppModel
    @State private var isFullScreen = false

    var body: some View {
        // Status pills (REC · LOCAL, Listening) live in the floating notch HUD at the
        // top-center of the screen; the in-app bar keeps the brand on the left, the
        // tab switcher dead-center, and the quick controls on the right.
        HStack(spacing: CascadeMetrics.s4) {
            HStack(spacing: CascadeMetrics.s2) {
                Image(nsImage: NSImage(named: "cascadeTemplate") ?? NSImage())
                    .resizable().renderingMode(.template)
                    .frame(width: 17, height: 17)
                    .foregroundStyle(Color.cascadeAgent)
                Text("Cascade").font(.cascadeSerif(20))
            }

            Spacer()

            HStack(spacing: CascadeMetrics.s2) {
                quickControl(
                    icon: "arrow.up.left.and.arrow.down.right",
                    help: "Toggle fullscreen (⌃⌘F)"
                ) { toggleFullScreen() }
                quickControl(
                    icon: model.prefersDark ? "sun.max" : "moon",
                    help: "Toggle light / dark"
                ) { model.toggleTheme() }
                quickControl(
                    icon: "gearshape",
                    help: "Settings — hotkeys, access & model keys",
                    active: model.showSettings
                ) { model.showSettings.toggle() }
            }
        }
        .overlay(tabSwitcher)
        .padding(.horizontal, CascadeMetrics.s5)
        .padding(.vertical, CascadeMetrics.s3)
        // In fullscreen the menu bar hides and the notch HUD hangs over the top
        // edge of the window — right where the centered tabs sit. Drop the bar
        // below it so the HUD gets its own strip instead of covering the tabs.
        .padding(.top, isFullScreen ? 30 : 0)
        .overlay(Rectangle().fill(Color.cascadeBorder).frame(height: 1), alignment: .bottom)
        .onAppear {
            isFullScreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    /// Centered between the brand and the quick controls, independent of either side's width.
    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(CascadeAppModel.Tab.allCases) { tab in
                let active = model.selectedTab == tab && !model.showSettings
                Button {
                    model.selectedTab = tab
                    model.showSettings = false
                } label: {
                    Text(tab.rawValue)
                        .font(.cascadeSans(13, active ? .semibold : .medium))
                        .foregroundStyle(active ? Color.cascadeText : Color.cascadeText2)
                        .padding(.horizontal, CascadeMetrics.s3 + 2)
                        .padding(.vertical, CascadeMetrics.s2 - 1)
                        .background(active ? Color.cascadePanel3 : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }

    private func toggleFullScreen() {
        NSApp.windows.first(where: { $0.canBecomeMain })?.toggleFullScreen(nil)
    }

    private func quickControl(icon: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.cascadeText : Color.cascadeText2)
                .frame(width: 30, height: 30)
                .background(active ? Color.cascadePanel3 : Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? Color.cascadeBorderHi : Color.cascadeBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Reel screen (real captured moments)

private struct ReelScreen: View {
    @ObservedObject var model: CascadeAppModel
    @State private var index = 0
    @State private var draft = ""
    @State private var isPlaying = false
    @State private var speed: Double = 1
    @State private var playbackAccumulator = 0.0

    /// Drives reel playback. Fires often; advances a moment only once enough time
    /// has accumulated for the current speed.
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    /// Search results when a query is active, otherwise the recent timeline.
    private var moments: [RecordedContext] {
        model.searchQuery.isEmpty ? model.contexts : model.searchResults
    }
    private var selected: RecordedContext? {
        guard !moments.isEmpty else { return nil }
        return moments[min(max(index, 0), moments.count - 1)]
    }
    /// True when scrubbed to the newest moment ("now").
    private var isLive: Bool { index == 0 }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                main
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, CascadeMetrics.s5)
                    .padding(.vertical, CascadeMetrics.s4)
                // The chat panel earns more room as the window grows (~27% of the
                // width in fullscreen) instead of staying a fixed sliver. It floats
                // as a card in the same design language as the scene card.
                AskPanel(model: model, selected: selected, draft: $draft)
                    .frame(width: max(340, min(440, geo.size.width * 0.27)))
                    .padding(.trailing, CascadeMetrics.s5)
                    .padding(.vertical, CascadeMetrics.s4)
            }
        }
        .background(alignment: .top) { reelGlow }
        .onReceive(ticker) { _ in advancePlaybackIfNeeded() }
        .onChange(of: moments.count) { _, newCount in
            index = min(index, max(newCount - 1, 0))
        }
    }

    /// Soft warm vignette at the top of the reel, echoing the captured-moment glow.
    private var reelGlow: some View {
        RadialGradient(
            colors: [Color.cascadeAccent.opacity(0.12), Color.clear],
            center: .top,
            startRadius: 0,
            endRadius: 480
        )
        .frame(height: 360)
        .frame(maxWidth: .infinity)
        .blur(radius: 30)
        .allowsHitTesting(false)
    }

    /// Advances playback from older → newer moments, scaled by the chosen speed,
    /// stopping when it reaches the live edge.
    private func advancePlaybackIfNeeded() {
        guard isPlaying else { return }
        playbackAccumulator += 0.1
        guard playbackAccumulator >= max(0.1, 0.7 / speed) else { return }
        playbackAccumulator = 0
        if index > 0 {
            index -= 1
        } else {
            isPlaying = false
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s4) {
            // The headline leads — no search bar or moment/time rows above it; the
            // transport readout already tells the time, and the chat panel names
            // the app. A small tinted dot next to the title keeps the app cue.
            HStack(spacing: CascadeMetrics.s3) {
                if let selected {
                    Circle()
                        .fill(AppVisuals.color(for: selected.appName, bundleIdentifier: selected.bundleIdentifier))
                        .frame(width: 9, height: 9)
                }
                Text(headline)
                    .font(.cascadeSerif(34))
                    .italic()
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, CascadeMetrics.s4)
            .padding(.top, CascadeMetrics.s2)
            SceneCard(context: selected)
            TransportBar(
                isPlaying: $isPlaying,
                speed: $speed,
                isLive: isLive,
                hasMoments: !moments.isEmpty,
                current: selected?.capturedAt,
                latest: moments.first?.capturedAt,
                onOlder: {
                    if index < moments.count - 1 { index += 1 }
                    isPlaying = false
                },
                onNewer: {
                    if index > 0 { index -= 1 }
                    isPlaying = false
                }
            )
            ActivityTimeline(
                contexts: moments,
                currentIndex: index,
                onScrub: { newIndex in
                    index = newIndex
                    isPlaying = false
                }
            )
        }
    }

    private var headline: String {
        guard let selected else { return "Idle — no capture at this time." }
        if let title = selected.windowTitle, !title.isEmpty { return Self.cleanTitle(title) }
        if let ocr = selected.ocrText, let first = ocr.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(first.prefix(90))
        }
        return "A local moment in \(selected.appName)"
    }

    /// Window titles often lead with decorative bullets ("· Redesign…", "✳ Build…")
    /// that look like typos in the big serif headline — drop them, nothing else.
    private static func cleanTitle(_ title: String) -> String {
        var t = Substring(title)
        while let first = t.first, "·•✳✱✻*∙⁂ ".contains(first) { t = t.dropFirst() }
        return t.isEmpty ? title : String(t)
    }

    /// Clock with seconds for the transport readout, e.g. "11:58:53pm".
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ssa"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: date).lowercased()
    }
}

private struct SceneCard: View {
    let context: RecordedContext?

    @ViewBuilder var body: some View {
        if let context, let path = context.imagePath, let image = NSImage(contentsOfFile: path) {
            screenshotCard(image)
        } else {
            panelCard
        }
    }

    /// Full-width card, flush with the transport bar below, and the capture fills
    /// it edge-to-edge like fullscreen video — cropping a sliver of the frame when
    /// the aspect ratios differ rather than ever showing a letterbox.
    private func screenshotCard(_ image: NSImage) -> some View {
        ZStack(alignment: .topTrailing) {
            // Color.clear sized by the card + overlay/clipped keeps scaledToFill's
            // natural-size overflow from inflating the layout.
            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
            capturedBadge
                .padding(CascadeMetrics.s4)
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous)
                .stroke(Color.cascadeBorderHi.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
    }

    /// Fallback card (OCR text or idle) — full-width cinematic panel.
    private var panelCard: some View {
        ZStack {
            // Warm cinematic backdrop fading to black, like the target reel.
            LinearGradient(
                colors: [Color.cascadeAccent.opacity(0.10), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            content
            VStack {
                HStack {
                    Spacer()
                    capturedBadge
                }
                Spacer()
            }
            .padding(CascadeMetrics.s4)
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous)
                .stroke(Color.cascadeBorderHi.opacity(0.55), lineWidth: 1)
        )
    }

    @ViewBuilder private var content: some View {
        if let context {
            VStack(spacing: CascadeMetrics.s3) {
                if let icon = AppVisuals.icon(forBundle: context.bundleIdentifier) {
                    Image(nsImage: icon).resizable().frame(width: 54, height: 54)
                }
                if let ocr = context.ocrText, !ocr.isEmpty {
                    ScrollView {
                        Text(ocr)
                            .font(.cascadeMono(11))
                            .foregroundStyle(Color.cascadeText2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(.horizontal, CascadeMetrics.s6)
                } else {
                    Text("A local moment in \(context.appName)")
                        .font(.cascadeSans(12))
                        .foregroundStyle(Color.cascadeText3)
                }
            }
            .padding(CascadeMetrics.s5)
        } else {
            idlePlaceholder
        }
    }

    private var idlePlaceholder: some View {
        VStack(spacing: CascadeMetrics.s3) {
            Text("Idle · No capture at this time")
                .font(.cascadeMono(12, .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.cascadeText3)
            Text("Drag the timeline to a moment Cascade recorded.")
                .font(.cascadeSans(13))
                .foregroundStyle(Color.cascadeText3)
        }
    }

    private var capturedBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.cascadeRecDot).frame(width: 6, height: 6)
            Text("Captured · Local")
                .font(.cascadeMono(10, .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(Color.cascadeRecText)
        }
        .padding(.horizontal, CascadeMetrics.s3)
        .padding(.vertical, 7)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(Color.cascadeRecText.opacity(0.35), lineWidth: 1))
    }
}

private struct TransportBar: View {
    @Binding var isPlaying: Bool
    @Binding var speed: Double
    let isLive: Bool
    let hasMoments: Bool
    let current: Date?
    let latest: Date?
    let onOlder: () -> Void
    let onNewer: () -> Void

    private let speeds: [Double] = [0.5, 1, 2, 8]

    var body: some View {
        HStack(spacing: CascadeMetrics.s4) {
            HStack(spacing: CascadeMetrics.s2) {
                ghostButton("chevron.left", action: onOlder, enabled: hasMoments)
                playButton
                ghostButton("chevron.right", action: onNewer, enabled: hasMoments)
            }
            Rectangle().fill(Color.cascadeBorder).frame(width: 1, height: 26)
            // Live: one clock + the LIVE pill (current == latest, no point showing
            // both). Scrubbed: "current / latest". Everything here is fixed-size so
            // a narrow window can never squeeze the text into a vertical wrap.
            HStack(alignment: .firstTextBaseline, spacing: CascadeMetrics.s2) {
                Text(current.map(ReelScreen.clock) ?? "—")
                    .font(.cascadeMono(20, .medium))
                    .lineLimit(1)
                    .fixedSize()
                if isLive {
                    livePill
                } else {
                    Text("/ \(latest.map(ReelScreen.clock) ?? "—")")
                        .font(.cascadeMono(12))
                        .foregroundStyle(Color.cascadeText3)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: CascadeMetrics.s2)
            speedControls
        }
        .padding(CascadeMetrics.s3)
        .background(Color.cascadePanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }

    private var playButton: some View {
        Button { isPlaying.toggle() } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 44, height: 34)
                .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorderHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasMoments ? Color.cascadeText : Color.cascadeText4)
        .disabled(!hasMoments)
    }

    private func ghostButton(_ icon: String, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.cascadeText2 : Color.cascadeText4)
        .disabled(!enabled)
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.cascadeGood).frame(width: 6, height: 6)
            Text("LIVE")
                .font(.cascadeMono(10, .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.cascadeAccent)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, CascadeMetrics.s2)
        .padding(.vertical, 4)
        .background(Color.cascadeAccent.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.cascadeAccent.opacity(0.40), lineWidth: 1))
    }

    private var speedControls: some View {
        HStack(spacing: CascadeMetrics.s1) {
            ForEach(speeds, id: \.self) { value in
                Button { speed = value } label: {
                    Text(speedLabel(value))
                        .font(.cascadeMono(12, speed == value ? .semibold : .regular))
                        .foregroundStyle(speed == value ? Color.cascadeText : Color.cascadeText3)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, CascadeMetrics.s2)
                        .padding(.vertical, 5)
                        .background(
                            speed == value ? Color.cascadePanel2 : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(speed == value ? Color.cascadeBorderHi : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(value)×"
    }
}

private struct ActivityTimeline: View {
    let contexts: [RecordedContext]
    /// Current scrubber position as an index into `contexts` (0 = newest / live).
    let currentIndex: Int
    /// Called when the user clicks or drags the bar to a different moment.
    let onScrub: (Int) -> Void

    private struct Run: Identifiable { let id = UUID(); let app: String; let bundle: String?; let count: Int }
    private struct LegendItem: Identifiable { let id: String; let app: String; let bundle: String? }

    private var runs: [Run] {
        var result: [Run] = []
        for context in contexts.reversed() {
            if let last = result.last, last.app == context.appName {
                result[result.count - 1] = Run(app: last.app, bundle: last.bundle, count: last.count + 1)
            } else {
                result.append(Run(app: context.appName, bundle: context.bundleIdentifier, count: 1))
            }
        }
        return result
    }

    private var legend: [LegendItem] {
        var seen = Set<String>()
        var items: [LegendItem] = []
        for context in contexts where !seen.contains(context.appName) {
            seen.insert(context.appName)
            items.append(LegendItem(id: context.appName, app: context.appName, bundle: context.bundleIdentifier))
        }
        return items.sorted { $0.app < $1.app }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
            label
            track
            axis
        }
    }

    @ViewBuilder private var label: some View {
        if runs.isEmpty {
            Text("NO ACTIVITY RECORDED YET")
                .font(.cascadeMono(11, .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.cascadeText3)
        } else {
            HStack(spacing: CascadeMetrics.s3) {
                ForEach(legend) { item in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AppVisuals.color(for: item.app, bundleIdentifier: item.bundle))
                            .frame(width: 9, height: 9)
                        Text(item.app).font(.cascadeMono(10)).foregroundStyle(Color.cascadeText2)
                    }
                }
            }
        }
    }

    @ViewBuilder private var track: some View {
        if runs.isEmpty {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cascadePanel2)
                .frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
        } else {
            // Canvas paints each run at its exact fractional position, so the bar
            // always fits its frame. (An HStack of min-6pt segments overflowed the
            // track in narrow windows once many short runs were squeezed together —
            // the bar bled past the playhead and the rounded border.)
            let total = CGFloat(max(contexts.count, 1))
            let segments = runs.map {
                (color: AppVisuals.color(for: $0.app, bundleIdentifier: $0.bundle), count: CGFloat($0.count))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        var x: CGFloat = 0
                        for segment in segments {
                            let w = size.width * segment.count / total
                            // Hairline gaps separate runs, but only when a run is
                            // wide enough to survive one.
                            let gap: CGFloat = w > 5 ? 1.5 : 0
                            let rect = CGRect(x: x + gap / 2, y: 0, width: max(w - gap, 0.5), height: size.height)
                            context.fill(Path(rect), with: .color(segment.color))
                            x += w
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    playhead(width: geo.size.width, height: geo.size.height)
                }
                .contentShape(Rectangle())
                // minimumDistance 0 so a single click jumps to that moment, and a
                // drag scrubs continuously.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrub(toX: $0.location.x, width: geo.size.width) }
                )
            }
            .frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
            .help("Click or drag to scrub through your timeline")
        }
    }

    /// White handle marking the current moment. The bar runs oldest → newest
    /// (left → right), so the newest moment (index 0) sits at the right edge.
    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.cascadeText)
            .frame(width: 3, height: height + 8)
            .shadow(color: .black.opacity(0.55), radius: 2)
            .position(x: playheadX(width), y: height / 2)
            .allowsHitTesting(false)
    }

    /// The playhead sits at the *trailing edge* of the current moment's slot — a
    /// moment spans from its capture until the next one — so at the live edge the
    /// handle is flush with the end of the bar instead of half a slot short of it.
    private func playheadX(_ width: CGFloat) -> CGFloat {
        let count = max(contexts.count, 1)
        let ordinal = count - min(max(currentIndex, 0), count - 1)  // count = newest (right edge)
        let fraction = Double(ordinal) / Double(count)
        return min(CGFloat(fraction) * width, width - 2)
    }

    /// Maps a tap/drag X into the matching moment index and reports it (only when it
    /// actually changes, so dragging within one moment doesn't thrash state).
    private func scrub(toX x: CGFloat, width: CGFloat) {
        guard !contexts.isEmpty, width > 0 else { return }
        let count = contexts.count
        let fraction = min(max(Double(x / width), 0), 1)
        let ordinal = min(Int(fraction * Double(count)), count - 1)  // 0 = oldest
        let newIndex = count - 1 - ordinal
        if newIndex != currentIndex { onScrub(newIndex) }
    }

    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(Array(axisLabels.enumerated()), id: \.offset) { offset, label in
                Text(label).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                if offset < axisLabels.count - 1 { Spacer(minLength: 0) }
            }
        }
    }

    /// Four evenly spaced hour ticks across the captured span (min 3h window),
    /// oldest → newest, matching the track's left → right direction.
    private var axisLabels: [String] {
        let end = contexts.first?.capturedAt ?? Date()
        let start = contexts.last?.capturedAt ?? end.addingTimeInterval(-3 * 3600)
        let span = max(end.timeIntervalSince(start), 3 * 3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return (0..<4).map { i in
            formatter.string(from: start.addingTimeInterval(span * Double(i) / 3)).lowercased()
        }
    }
}

private struct AskPanel: View {
    @ObservedObject var model: CascadeAppModel
    let selected: RecordedContext?
    @Binding var draft: String

    private var suggestedQuestions: [String] {
        var qs = ["What did I do today?", "What was I working on?"]
        if let app = selected?.appName { qs.append("What was I doing in \(app)?") }
        return qs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                CascadeTag("Ask about this moment", tone: .cascadeAgent)
                Text(headerLine)
                    .font(.cascadeSans(13, .medium))
                    .foregroundStyle(Color.cascadeText2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CascadeMetrics.s5)
            .padding(.vertical, CascadeMetrics.s4)
            .background(Color.cascadePanel.opacity(0.7))

            Divider().overlay(Color.cascadeBorder)

            // The conversation pins to its newest message: new turns and streamed
            // answer chunks keep the bottom anchored in view.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: CascadeMetrics.s4) {
                        if model.conversation.isEmpty && !model.thinking {
                            emptyState
                        }
                        ForEach(model.conversation) { turn in
                            ChatBubble(text: turn.question, mine: true)
                            ChatBubble(text: turn.answer, mine: false)
                        }
                        if model.thinking {
                            if model.answer.isEmpty {
                                TypingIndicator()
                            } else {
                                ChatBubble(text: model.answer, mine: false)
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.chatEnd)
                    }
                    .padding(CascadeMetrics.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.conversation.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: model.thinking) { _, _ in scrollToEnd(proxy) }
                .onChange(of: model.answer) { _, _ in scrollToEnd(proxy) }
            }

            VStack(alignment: .leading, spacing: CascadeMetrics.s2 + 2) {
                if model.conversation.isEmpty && !model.thinking {
                    FlowChips(items: suggestedQuestions) { q in model.ask(q) }
                }
                // Capsule composer with the send button living inside the field.
                HStack(spacing: CascadeMetrics.s2) {
                    TextField("Ask the rewind, or “where do I find X”…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.cascadeSans(13))
                        .onSubmit { send() }
                    Button { send() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? Color.cascadeOnAccent : Color.cascadeText4)
                            .frame(width: 28, height: 28)
                            .background(canSend ? Color.cascadeAgent : Color.cascadePanel3, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(.leading, CascadeMetrics.s4)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(Color.cascadePanel2, in: Capsule())
                .overlay(Capsule().stroke(Color.cascadeBorder, lineWidth: 1))
                statusLine
            }
            .padding(CascadeMetrics.s4)
        }
        .background(Color.cascadePanel.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous)
                .stroke(Color.cascadeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private static let chatEnd = "chat-end"

    /// "WhatsApp · chat title", deduped when the window title is just the app name.
    private var headerLine: String {
        guard let selected else { return "Local record" }
        if let title = selected.windowTitle, !title.isEmpty, title != selected.appName {
            return "\(selected.appName) · \(title)"
        }
        return selected.appName
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.chatEnd, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: CascadeMetrics.s3) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.cascadeAgent)
            Text("Ask anything about your recorded local context.")
                .font(.cascadeSans(13, .medium))
                .foregroundStyle(Color.cascadeText2)
            Text("Answers are grounded only in what was captured. Hold right ⌘ to talk, or ask “where do I find X” and Cascade points at it on your screen.")
                .font(.cascadeSans(12))
                .foregroundStyle(Color.cascadeText3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, CascadeMetrics.s8)
        .padding(.horizontal, CascadeMetrics.s2)
    }

    /// One quiet line under the composer: the live voice state while a request is
    /// in flight, else the latest pointer answer — never a stack of stale status.
    @ViewBuilder private var statusLine: some View {
        if model.voice.state != .idle {
            HStack(spacing: CascadeMetrics.s2) {
                Image(systemName: model.voice.state == .listening ? "waveform" : "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cascadeAgent)
                Text(model.voice.hint)
                    .font(.cascadeSans(11))
                    .foregroundStyle(Color.cascadeText3)
                    .lineLimit(1)
            }
        } else if !model.teachMessage.isEmpty {
            Text(model.teachMessage)
                .font(.cascadeSans(11))
                .foregroundStyle(Color.cascadeText3)
                .lineLimit(2)
        }
    }

    private func send() {
        guard canSend else { return }
        let q = draft
        draft = ""
        model.ask(q)
    }
}

/// Three softly pulsing dots while Claude is thinking — a live signal instead of
/// an empty bubble.
private struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { dot in
                Circle()
                    .fill(Color.cascadeText3)
                    .frame(width: 6, height: 6)
                    .opacity(phase ? 0.25 : 1)
                    .animation(
                        .easeInOut(duration: 0.55).repeatForever().delay(Double(dot) * 0.18),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, CascadeMetrics.s3)
        .padding(.vertical, CascadeMetrics.s2 + 3)
        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
        .onAppear { phase = true }
    }
}

private struct ChatBubble: View {
    let text: String
    let mine: Bool

    /// Message-app corner language: the corner nearest the sender is pinched.
    private var corners: RectangleCornerRadii {
        mine
            ? RectangleCornerRadii(topLeading: 16, bottomLeading: 16, bottomTrailing: 5, topTrailing: 16)
            : RectangleCornerRadii(topLeading: 16, bottomLeading: 5, bottomTrailing: 16, topTrailing: 16)
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .font(.cascadeSans(13))
                .textSelection(.enabled)
                .foregroundStyle(mine ? Color.cascadeOnAccent : Color.cascadeText)
                .padding(.horizontal, CascadeMetrics.s3 + 1)
                .padding(.vertical, CascadeMetrics.s2 + 2)
                .background(
                    mine
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [Color.cascadeAgent, Color.cascadeAgent.opacity(0.8)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(Color.cascadePanel2),
                    in: UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
                )
                .overlay(
                    mine
                        ? nil
                        : UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
                            .stroke(Color.cascadeBorder, lineWidth: 1)
                )
            if !mine { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Cascades screen (employee inbox: manager + detected cascades, real audit)

private struct CascadesScreen: View {
    @ObservedObject var model: CascadeAppModel

    private var agentActivity: [AuditEvent] {
        model.audit.filter { $0.action.hasPrefix("step.") || $0.action.hasPrefix("agent.") || $0.action == "computer.act" || $0.action == "cascade.declined" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CascadeMetrics.s6) {
                VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                    CascadeTag("Cascades", tone: .cascadeAgent)
                    Text("Everything you can run").font(.cascadeSerif(30))
                    Text("Workflows Cascade detected in your real work, agents already approved, and cascades from your manager — review, deploy, and watch them run. The Manager tab shows the numbers.")
                        .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
                }
                detectedSection
                agentsSection
                managerInboxSection
                suggestionsSection
                activitySection
            }
            .padding(.horizontal, CascadeMetrics.s6)
            .padding(.vertical, CascadeMetrics.s6)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Repeated work Cascade detected, awaiting review — approve to build an
    /// agent from the recorded actions, decline to never see it again.
    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "DETECTED WORKFLOWS — REVIEW & APPROVE", trailing: "\(model.pendingDetectedWaste.count) pending")
            if model.pendingDetectedWaste.isEmpty {
                CascadePanel { EmptyState(title: "Nothing to review", detail: "When you repeat a task, Cascade surfaces it here — apps, frequency, time saved — and one approve turns it into an agent built from your real actions.") }
            } else {
                ForEach(model.pendingDetectedWaste) { waste in
                    WasteCard(
                        waste: waste,
                        evidenceImagePath: evidenceImagePath(for: waste),
                        onApprove: { model.approveWaste(waste) },
                        onDecline: { model.declineWaste(waste) }
                    )
                }
            }
        }
    }

    /// The rewind frame nearest to when the workflow was last observed, from the
    /// same app — real visual evidence for the card.
    private func evidenceImagePath(for waste: DetectedWaste) -> String? {
        model.contexts
            .filter { $0.imagePath != nil && (waste.apps.contains($0.appName) || waste.apps.isEmpty) }
            .min { abs($0.capturedAt.timeIntervalSince(waste.lastSeenAt)) < abs($1.capturedAt.timeIntervalSince(waste.lastSeenAt)) }?
            .imagePath
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "YOUR AGENTS", trailing: "\(model.agents.count) approved")
            if model.agents.isEmpty {
                CascadePanel { EmptyState(title: "No agents yet", detail: "Approve a detected workflow above and the agent shows up here — built from your real actions, ready to deploy.") }
            } else {
                ForEach(model.agents) { agent in
                    AgentCard(
                        agent: agent,
                        onDeploy: { model.deployAgent(agent) },
                        onToggle: { model.setAgentEnabled(agent, enabled: $0) },
                        onDelete: { model.deleteAgent(agent) }
                    )
                }
            }
        }
    }

    /// The persisted manager → employee inbox: pending cascades to review.
    private var managerInboxSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "CASCADES FROM YOUR MANAGER", trailing: "\(model.visibleManagerCascades.count) pending")
            if model.visibleManagerCascades.isEmpty {
                CascadePanel { EmptyState(title: "Nothing here yet", detail: "When your manager cascades an agent from the Manager dashboard, it lands here to review and deploy.") }
            } else {
                ForEach(model.visibleManagerCascades) { cascade in
                    ManagerCascadeCard(
                        eyebrow: "CASCADED FROM YOUR MANAGER",
                        title: cascade.title,
                        summary: cascade.summary,
                        evidence: nil,
                        fromManager: true,
                        onDeploy: { model.deployCascade(cascade) },
                        onDecline: { model.declineCascade(cascade) }
                    )
                }
            }
        }
    }

    /// What Cascade itself noticed in the local record — evidence-backed, one
    /// click to run through the agent.
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "SUGGESTED BY CASCADE", trailing: "\(model.visibleSuggestions.count) from your record")
            if model.visibleSuggestions.isEmpty {
                CascadePanel { EmptyState(title: "No suggestions yet", detail: "As Cascade records your work, repeated patterns surface here as ready-to-run suggestions.") }
            } else {
                ForEach(model.visibleSuggestions) { suggestion in
                    ManagerCascadeCard(
                        eyebrow: "DETECTED · \(suggestion.kind.rawValue.uppercased()) · \(Int(suggestion.confidence * 100))% CONFIDENCE",
                        title: suggestion.title,
                        summary: suggestion.summary,
                        evidence: suggestion.evidence.first,
                        fromManager: false,
                        deployLabel: "RUN  →",
                        onDeploy: { model.deploySuggestion(suggestion) },
                        onDecline: { model.declineSuggestion(suggestion) }
                    )
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "RECENT AGENT ACTIVITY", trailing: "from the local audit log")
            if agentActivity.isEmpty {
                CascadePanel { EmptyState(title: "No agent runs yet", detail: "Deploy a cascade or plan a step — every proposed and approved action is audited here.") }
            } else {
                ForEach(agentActivity.prefix(8)) { event in
                    AgentActivityRow(event: event)
                }
            }
        }
    }
}

/// One-line summary of a recipe's steps, for the cards — uses the recorded AX
/// anchors and shortcut symbols so it reads like the workflow, not a token list.
private func recipeSummary(_ recipe: AgentRecipe) -> String {
    recipe.humanSteps.prefix(8).joined(separator: " → ")
}

private struct AppChips: View {
    let apps: [String]
    var body: some View {
        HStack(spacing: CascadeMetrics.s2) {
            ForEach(apps, id: \.self) { app in
                HStack(spacing: 4) {
                    Circle().fill(AppVisuals.color(for: app)).frame(width: 7, height: 7)
                    Text(app).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText2)
                }
            }
        }
    }
}

/// Review card for a detected workflow (Cascades tab): a rewind frame as
/// visual evidence, and the numbered "when deployed" steps built from the
/// recorded AX anchors — informed consent, not a leap of faith. Privacy-safe:
/// step *shape* and anchors only, never raw typed text or coordinates.
private struct WasteCard: View {
    let waste: DetectedWaste
    let evidenceImagePath: String?
    let onApprove: () -> Void
    let onDecline: () -> Void

    private static let previewSteps = 5

    var body: some View {
        CascadePanel {
            HStack(alignment: .top, spacing: CascadeMetrics.s4) {
                thumbnail
                VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                    HStack(alignment: .top) {
                        Text(waste.title).font(.cascadeSans(15, .semibold))
                        Spacer()
                        Text("\(waste.occurrences)× · ~\(max(1, waste.estimatedTotalSeconds / 60))m saved")
                            .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                            .fixedSize()
                    }
                    AppChips(apps: waste.apps)
                    deployPreview
                    HStack(spacing: CascadeMetrics.s2) {
                        Text("last seen \(waste.lastSeenAt.formatted(date: .omitted, time: .shortened))")
                            .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText4)
                        Spacer()
                        Button(action: onDecline) { Text("Decline") }
                            .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                        Button(action: onApprove) { Text("Approve agent") }
                            .buttonStyle(CascadeAccentButtonStyle())
                    }
                }
            }
        }
    }

    /// A real frame from the rewind, captured around the time the workflow last
    /// ran — what this actually looked like on screen.
    @ViewBuilder private var thumbnail: some View {
        if let path = evidenceImagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 116, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorderHi, lineWidth: 1))
        }
    }

    /// Exactly what approving + deploying will do, step by step.
    private var deployPreview: some View {
        let steps = waste.recipe.humanSteps
        return VStack(alignment: .leading, spacing: 3) {
            Text("WHEN DEPLOYED, CASCADE WILL")
                .font(.cascadeMono(9, .semibold)).tracking(0.7).foregroundStyle(Color.cascadeText4)
            ForEach(Array(steps.prefix(Self.previewSteps).enumerated()), id: \.offset) { index, step in
                Text("\(index + 1).  \(step)")
                    .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText2).lineLimit(1)
            }
            if steps.count > Self.previewSteps {
                Text("…and \(steps.count - Self.previewSteps) more steps")
                    .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText4)
            }
            if CascadeAppModel.runsInBackground(apps: waste.apps) {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 10)).foregroundStyle(Color.cascadeAgent)
                    Text("Runs in the background sandbox — your screen stays yours.")
                        .font(.cascadeSans(11)).foregroundStyle(Color.cascadeText3)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct AgentCard: View {
    let agent: CascadeAgent
    let onDeploy: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack {
                    Circle().fill(AppVisuals.color(for: agent.apps.first ?? agent.name)).frame(width: 8, height: 8)
                    Text(agent.name).font(.cascadeSans(15, .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { agent.enabled },
                        set: { enabled in onToggle(enabled) }
                    ))
                        .labelsHidden().toggleStyle(.switch)
                }
                if !agent.apps.isEmpty { AppChips(apps: agent.apps) }
                Text(recipeSummary(agent.recipe))
                    .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText2).lineLimit(2)
                HStack {
                    Text(meta).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                    Spacer()
                    Button("Delete", action: onDelete)
                        .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                    Button("Deploy", action: onDeploy)
                        .buttonStyle(CascadeAccentButtonStyle())
                        .disabled(!agent.enabled)
                }
            }
        }
    }

    private var meta: String {
        var summary = "\(agent.recipe.steps.count) steps"
        summary += agent.runCount == 1 ? " · 1 run" : " · \(agent.runCount) runs"
        if agent.runCount > 0, agent.estimatedSecondsPerRun > 0 {
            summary += " · ~\(max(1, agent.estimatedSecondsPerRun * agent.runCount / 60))m reclaimed"
        }
        if let last = agent.lastRunAt {
            summary += " · last \(last.formatted(date: .omitted, time: .shortened))"
        }
        if CascadeAppModel.runsInBackground(apps: agent.apps) {
            summary += " · runs in background"
        }
        return summary
    }
}

// MARK: - Manager screen (aggregate-only ANALYTICS; review/deploy live in Cascades)

private struct ManagerScreen: View {
    @ObservedObject var model: CascadeAppModel

    private var appsObserved: Int { Set(model.contexts.map(\.appName)).count }

    /// Minutes ACTUALLY given back: seconds one run saves × completed runs.
    /// Approval alone counts for nothing here — only deploys that finished.
    private var minutesReclaimed: Int {
        model.agents.map { $0.estimatedSecondsPerRun * $0.runCount }.reduce(0, +) / 60
    }

    /// Minutes still sitting on the table: unreviewed detected workflows plus
    /// approved agents that have never actually been deployed.
    private var minutesOnTheTable: Int {
        let pending = model.pendingDetectedWaste.map(\.estimatedTotalSeconds).reduce(0, +)
        let approvedNeverRun = model.agents.filter { $0.runCount == 0 }.map(\.estimatedSeconds).reduce(0, +)
        return (pending + approvedNeverRun) / 60
    }

    private var totalRuns: Int {
        model.agents.map(\.runCount).reduce(0, +)
    }

    /// Sample counts per app, biggest first — where the recorded time actually went.
    private var appUsage: [(app: String, bundle: String?, count: Int)] {
        var counts: [String: (bundle: String?, count: Int)] = [:]
        for context in model.contexts {
            counts[context.appName, default: (context.bundleIdentifier, 0)].count += 1
        }
        return counts.map { (app: $0.key, bundle: $0.value.bundle, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.app < $1.app }
    }

    /// Detected workflows worth the most time, approved or not — insight, not actions.
    private var topWorkflows: [DetectedWaste] {
        Array(model.detectedWaste.prefix(5))
    }

    private var managerChips: [String] {
        var result = Array(Set(model.contexts.map(\.appName))).prefix(2).map { "Auto-summarize \($0) sessions" }
        if let detected = model.visibleSuggestions.first?.title { result.append(detected) }
        if result.isEmpty { result = ["Batch newsletters until 4pm", "Mute Slack during deep work"] }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CascadeMetrics.s6) {
                VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                    CascadeTag("Manager", tone: .cascadeAgent)
                    Text("Analytics from privacy-safe signals").font(.cascadeSerif(30))
                    Text("Aggregate-only: time reclaimed, where the hours go, and the workflows worth automating. Reviewing and deploying happens in Cascades — never raw OCR, screenshots, or keystrokes here.")
                        .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
                }
                HStack(spacing: CascadeMetrics.s3) {
                    MetricCard(value: "~\(minutesReclaimed)m", label: "Reclaimed (\(totalRuns) runs)")
                    MetricCard(value: "~\(minutesOnTheTable)m", label: "On the table")
                    MetricCard(value: "\(appsObserved)", label: "Apps observed")
                    MetricCard(value: "\(model.agents.count)", label: "Agents approved")
                    MetricCard(value: "0", label: "Raw screenshots")
                }
                workflowsSection
                whereTimeGoesSection
                ComposeBox(
                    eyebrow: "Cascade an agent to this employee",
                    placeholder: "Describe an automation to cascade. Plain English.",
                    hint: "lands in the employee's Cascades inbox",
                    chips: managerChips,
                    submit: { model.cascadeFromManager($0) }
                )
                VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                    SectionLabel(title: "CASCADES YOU'VE SENT", trailing: "\(model.managerCascades.count) total")
                    if model.managerCascades.isEmpty {
                        CascadePanel { EmptyState(title: "No cascades sent", detail: "Compose an automation above to cascade it to this employee's Cascades inbox.") }
                    } else {
                        ForEach(model.managerCascades) { cascade in
                            AgentActivityRow(event: AuditEvent(
                                createdAt: cascade.createdAt,
                                actor: "manager",
                                action: "cascade.\(cascade.status.rawValue)",
                                detail: cascade.title
                            ))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CascadeMetrics.s6)
            .padding(.vertical, CascadeMetrics.s6)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Read-only insight rows — the deploy buttons live in Cascades, and the
    /// jump link takes you there.
    private var workflowsSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            HStack {
                SectionLabel(title: "TOP REPEATED WORKFLOWS", trailing: "")
                Button {
                    model.selectedTab = .cascades
                } label: {
                    Text("Review in Cascades →").font(.cascadeMono(11)).foregroundStyle(Color.cascadeAgent)
                }
                .buttonStyle(.plain)
            }
            if topWorkflows.isEmpty {
                CascadePanel { EmptyState(title: "No repeated workflows yet", detail: "As Cascade records work, the most-repeated (and most automatable) tasks surface here with honest time-saved math.") }
            } else {
                CascadePanel {
                    VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                        ForEach(topWorkflows) { waste in
                            HStack(spacing: CascadeMetrics.s3) {
                                Circle().fill(AppVisuals.color(for: waste.apps.first ?? waste.title)).frame(width: 7, height: 7)
                                Text(waste.title).font(.cascadeSans(13, .medium)).lineLimit(1)
                                AppChips(apps: waste.apps)
                                Spacer()
                                Text("\(waste.occurrences)× · ~\(max(1, waste.estimatedTotalSeconds / 60))m")
                                    .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Sample share per app — a quiet bar per row, computed from the real record.
    private var whereTimeGoesSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "WHERE THE TIME GOES", trailing: "\(model.contexts.count) recent samples")
            if appUsage.isEmpty {
                CascadePanel { EmptyState(title: "Nothing recorded yet", detail: "Once recording is on, the apps where work actually happens show up here, ranked by observed time.") }
            } else {
                CascadePanel {
                    VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                        let top = Array(appUsage.prefix(6))
                        let maxCount = max(top.first?.count ?? 1, 1)
                        ForEach(top, id: \.app) { usage in
                            HStack(spacing: CascadeMetrics.s3) {
                                Circle().fill(AppVisuals.color(for: usage.app, bundleIdentifier: usage.bundle)).frame(width: 7, height: 7)
                                Text(usage.app).font(.cascadeSans(13, .medium))
                                    .frame(width: 170, alignment: .leading).lineLimit(1)
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(AppVisuals.color(for: usage.app, bundleIdentifier: usage.bundle).opacity(0.65))
                                        .frame(width: max(6, geo.size.width * CGFloat(usage.count) / CGFloat(maxCount)), height: 8)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 16)
                                Text("\(usage.count)")
                                    .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let trailing: String

    var body: some View {
        HStack {
            Text(title).font(.cascadeMono(11, .semibold)).tracking(0.8).foregroundStyle(Color.cascadeText3)
            Spacer()
            Text(trailing).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText4)
        }
    }
}

private struct MetricCard: View {
    let value: String
    let label: String

    var body: some View {
        CascadePanel(padding: CascadeMetrics.s4) {
            VStack(alignment: .leading, spacing: CascadeMetrics.s1) {
                Text(value).font(.cascadeSerif(32))
                Text(label.uppercased()).font(.cascadeMono(10, .medium)).tracking(0.5).foregroundStyle(Color.cascadeText3)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Reusable compose box for both the employee (plan a step) and the manager
/// (cascade an agent). The action and copy are injected — no hardcoded content.
private struct ComposeBox: View {
    let eyebrow: String
    let placeholder: String
    let hint: String
    let chips: [String]
    let submit: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            HStack {
                CascadeTag(eyebrow, tone: .cascadeAgent)
                Spacer()
                Text(hint).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText4)
            }
            HStack(spacing: CascadeMetrics.s3) {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.cascadeAgent)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.cascadeSans(16))
                    .onSubmit { fire() }
                Button("CASCADE  →") { fire() }
                    .buttonStyle(AgentButtonStyle())
            }
            .padding(CascadeMetrics.s4)
            .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            if !chips.isEmpty {
                FlowChips(items: chips) { chip in text = chip; fire() }
            }
        }
        .padding(CascadeMetrics.s5)
        .background(Color.cascadePanel.opacity(0.6), in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous).stroke(Color.cascadeAgent.opacity(0.55), lineWidth: 1.5))
        .shadow(color: Color.cascadeAgent.opacity(0.18), radius: 18, y: 4)
    }

    private func fire() {
        let value = text
        text = ""
        submit(value)
    }
}

private struct ManagerCascadeCard: View {
    let eyebrow: String
    let title: String
    let summary: String
    let evidence: String?
    var fromManager: Bool = false
    var deployLabel: String = "DEPLOY  →"
    let onDeploy: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: CascadeMetrics.s4) {
            RoundedRectangle(cornerRadius: 3).fill(Color.cascadeAgent).frame(width: 3)
            Image(systemName: fromManager ? "person.badge.shield.checkmark" : "wand.and.stars")
                .font(.system(size: 18)).foregroundStyle(Color.cascadeAgent).frame(width: 28)
            VStack(alignment: .leading, spacing: CascadeMetrics.s1 + 2) {
                Text(eyebrow)
                    .font(.cascadeMono(10, .semibold)).foregroundStyle(Color.cascadeAgent)
                Text(title).font(.cascadeSans(15, .semibold))
                Text(summary).font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2).lineLimit(2)
                if let evidence {
                    Text("↳ \(evidence)").font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                }
            }
            Spacer()
            VStack(spacing: CascadeMetrics.s2) {
                Button(deployLabel) { onDeploy() }.buttonStyle(AgentButtonStyle())
                Button("DECLINE") { onDecline() }.buttonStyle(CascadeQuietButtonStyle())
            }
        }
        .padding(CascadeMetrics.s4)
        .background(Color.cascadePanel, in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous).stroke(Color.cascadeAgent.opacity(0.35), lineWidth: 1))
    }
}

private struct AgentActivityRow: View {
    let event: AuditEvent

    var body: some View {
        HStack(spacing: CascadeMetrics.s3) {
            Circle().fill(Color.cascadeAgent).frame(width: 7, height: 7)
            Text(event.action.replacingOccurrences(of: ".", with: " ").uppercased())
                .font(.cascadeMono(10, .semibold)).foregroundStyle(Color.cascadeText3)
                .frame(width: 130, alignment: .leading)
            Text(event.detail).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText).lineLimit(1)
            Spacer()
            Text(event.createdAt, style: .time).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
        }
        .padding(.horizontal, CascadeMetrics.s4)
        .padding(.vertical, CascadeMetrics.s3)
        .background(Color.cascadePanel, in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }
}

// MARK: - Control dock

private struct ControlDockView: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        HStack(spacing: CascadeMetrics.s4) {
            Image(systemName: "cursorarrow.rays").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.cascadeAgent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.dock.title).font(.cascadeSans(13, .semibold))
                Text(model.dock.detail).font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2)
            }
            .frame(maxWidth: 380, alignment: .leading)
            Button("STOP") { model.dock.stop() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(CascadeQuietButtonStyle())
        }
        .padding(CascadeMetrics.s3 + 2)
        .background(Color.cascadePanel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.cascadeAgent.opacity(0.5), lineWidth: 1))
        .cascadeWindowShadow()
    }
}

// MARK: - Settings page

private struct SettingsScreen: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CascadeMetrics.s6) {
                header
                section("KEYBOARD SHORTCUTS", trailing: "work app-wide") {
                    HotkeysCard()
                }
                section("PERMISSIONS", trailing: "local capture & control") {
                    permissionsCard
                }
                section("AGENT HARNESS", trailing: "direct-Mac tools, fully audited") {
                    HarnessCard(model: model)
                }
                section("APP IDENTITY", trailing: "for granting permissions") {
                    DiagnosticsCard(diagnostics: model.permissionDiagnostics)
                }
                section("MODEL KEYS", trailing: "stored in macOS Keychain") {
                    ClaudeKeyCard(model: model)
                    OpenAIKeyCard(model: model)
                }
            }
            .padding(.horizontal, CascadeMetrics.s6)
            .padding(.vertical, CascadeMetrics.s6)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: CascadeMetrics.s1) {
                CascadeTag("Settings", tone: .cascadeAccentWarm)
                Text("Local trust controls").font(.cascadeSerif(30))
                Text("Hotkeys, permissions, and the keys Cascade uses. Everything stays on this Mac.")
                    .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
            }
            Spacer()
            Button("Setup guide") { model.showOnboarding = true }
                .buttonStyle(CascadeQuietButtonStyle())
            Button {
                model.showSettings = false
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Back")
                }
            }
            .buttonStyle(CascadeQuietButtonStyle())
        }
    }

    private func section(_ title: String, trailing: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: title, trailing: trailing)
            content()
        }
    }

    private var permissionsCard: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                PermissionRow(name: "Screen Recording", granted: model.recorder.status.permissions.screenRecording)
                PermissionRow(name: "Accessibility", granted: model.recorder.status.permissions.accessibility)
                PermissionRow(name: "Input Monitoring", granted: model.recorder.status.permissions.inputMonitoring)
                PermissionRow(name: "Use-device hotkey", granted: model.hotkey.running, detail: model.hotkey.label)
                Divider().overlay(Color.cascadeBorder)
                HStack {
                    Button("Refresh") { model.refreshPermissionState() }.buttonStyle(CascadeQuietButtonStyle())
                    Button("Request Screen") { model.requestScreenRecording() }.buttonStyle(CascadeQuietButtonStyle())
                    Button("Request AX") { model.requestAccessibility() }.buttonStyle(CascadeQuietButtonStyle())
                    Button("Request Input") { model.requestInputMonitoring() }.buttonStyle(CascadeQuietButtonStyle())
                    Button("Open Settings") { model.openSystemSettings() }.buttonStyle(CascadeAccentButtonStyle())
                }
            }
        }
    }
}

/// The assist agent's direct-Mac tools: the always-on read-only tier, and the
/// opt-in Power harness that lets it run commands, scripts, and file writes.
private struct HarnessCard: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find & read files").font(.cascadeSans(15, .semibold))
                        Text("search_files · list_folder · read_file — Spotlight search and bounded text reads. Read-only, privacy-gated by your exclusion list.")
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    CascadeTag("Always on", tone: .cascadeGood)
                }
                Divider().overlay(Color.cascadeBorder)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Power harness").font(.cascadeSans(15, .semibold))
                        Text("run_command · run_applescript · write_file — the agent can run shell commands and drive scriptable apps (bulk-edit a spreadsheet in one script instead of hundreds of clicks). Every call lands verbatim in the audit log, destructive commands (sudo, rm -rf /, …) are refused, and Esc stops it mid-run.")
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    Toggle("", isOn: $model.powerHarnessEnabled)
                        .labelsHidden().toggleStyle(.switch)
                }
                if model.powerHarnessEnabled {
                    HStack(spacing: CascadeMetrics.s2) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(Color.cascadeText3)
                        Text("AppleScript drives other apps via Automation: macOS asks once per app the first time a script touches it (System Settings → Privacy & Security → Automation).")
                            .font(.cascadeSans(11)).foregroundStyle(Color.cascadeText3)
                    }
                }
            }
        }
    }
}

/// Every way to summon Cascade from the keyboard, in one place.
private struct HotkeysCard: View {
    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HotkeyRow(
                    keys: ["hold right ⌘"],
                    name: "Talk to Cascade",
                    detail: "Push-to-talk: hold, speak, release. Ask the rewind or point Cascade at something on screen."
                )
                HotkeyRow(
                    keys: ["⇧", "⌘", "R"],
                    name: "Capture this moment",
                    detail: "Snapshots the current screen straight into the Reel."
                )
                HotkeyRow(
                    keys: ["⇧", "⌘", "L"],
                    name: "Start / pause recording",
                    detail: "Toggles the always-on local capture."
                )
                HotkeyRow(
                    keys: ["⌃", "⌘", "F"],
                    name: "Toggle fullscreen",
                    detail: "Expands Cascade to take over the screen; same key brings it back."
                )
                HotkeyRow(
                    keys: ["Esc"],
                    name: "Stop the running agent",
                    detail: "Immediately halts a deployed cascade mid-run."
                )
            }
        }
    }
}

private struct HotkeyRow: View {
    let keys: [String]
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CascadeMetrics.s4) {
            HStack(spacing: CascadeMetrics.s1) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.cascadeMono(12, .semibold))
                        .padding(.horizontal, CascadeMetrics.s2)
                        .padding(.vertical, CascadeMetrics.s1)
                        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.cascadeBorderHi, lineWidth: 1))
                }
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.cascadeSans(13, .semibold))
                Text(detail).font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            }
            Spacer()
        }
    }
}

// MARK: - Shared pieces

private struct AgentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cascadeMono(12, .semibold))
            .foregroundStyle(Color.cascadeOnAccent)
            .padding(.horizontal, CascadeMetrics.s4)
            .padding(.vertical, CascadeMetrics.s2 + 1)
            .background(Color.cascadeAgent)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        ChipFlowLayout(spacing: CascadeMetrics.s2) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(item)
                        .font(.cascadeSans(12))
                        .foregroundStyle(Color.cascadeText2)
                        .lineLimit(1)
                        .padding(.horizontal, CascadeMetrics.s3)
                        .padding(.vertical, CascadeMetrics.s2 - 1)
                        .background(Color.cascadePanel2, in: Capsule())
                        .overlay(Capsule().stroke(Color.cascadeBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Left-aligned wrapping row: chips keep their natural size and flow onto new
/// lines instead of truncating into "What was I doi…" when the column is narrow.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct PermissionRow: View {
    let name: String
    let granted: Bool
    var detail: String? = nil

    var body: some View {
        HStack(spacing: CascadeMetrics.s2) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.cascadeGood : Color.cascadeWarn)
            Text(name).font(.cascadeSans(13, .medium))
            if let detail {
                Text(detail).font(.cascadeMono(12)).foregroundStyle(Color.cascadeText3)
            }
            Spacer()
            Text(granted ? "Granted" : "Needed").font(.cascadeSans(13)).foregroundStyle(granted ? Color.cascadeGood : Color.cascadeText2)
        }
    }
}

private struct DiagnosticsCard: View {
    let diagnostics: PermissionDiagnostics

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                HStack {
                    Text("App identity").font(.cascadeSans(16, .semibold))
                    Spacer()
                    CascadeTag(diagnostics.bundleIdentifier, tone: .cascadeAccentWarm)
                }
                DiagnosticRow(label: "Bundle", value: diagnostics.bundleIdentifier)
                DiagnosticRow(label: "App", value: diagnostics.bundlePath)
                DiagnosticRow(label: "Executable", value: diagnostics.executablePath)
            }
        }
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: CascadeMetrics.s3) {
            Text(label).frame(width: 82, alignment: .leading).foregroundStyle(Color.cascadeText3)
            Text(value).font(.cascadeMono(12)).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer()
        }
        .font(.cascadeSans(12))
    }
}

private struct ClaudeKeyCard: View {
    @ObservedObject var model: CascadeAppModel
    @State private var key = ""

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude key").font(.cascadeSans(16, .semibold))
                        Text(model.keyMessage).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    CascadeTag(model.hasAnthropicKey ? "Connected" : "BYOK", tone: model.hasAnthropicKey ? .cascadeGood : .cascadeWarn)
                }
                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.cascadeMono(12))
                    .padding(.horizontal, CascadeMetrics.s3)
                    .padding(.vertical, CascadeMetrics.s2 + 1)
                    .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                HStack {
                    Button("Save key") { model.saveAnthropicKey(key); key = "" }.buttonStyle(CascadeAccentButtonStyle())
                    Button("Clear") { model.clearAnthropicKey(); key = "" }.buttonStyle(CascadeQuietButtonStyle())
                }
                Text("Stored in macOS Keychain. Used only for Claude-backed Q&A, suggestions, and reviewed agents.")
                    .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            }
        }
    }
}

private struct OpenAIKeyCard: View {
    @ObservedObject var model: CascadeAppModel
    @State private var key = ""

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI key · GPT-Realtime voice").font(.cascadeSans(16, .semibold))
                        Text(model.openAIKeyMessage).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    CascadeTag(model.hasOpenAIKey ? "Connected" : "Voice off", tone: model.hasOpenAIKey ? .cascadeGood : .cascadeWarn)
                }
                SecureField("sk-…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.cascadeMono(12))
                    .padding(.horizontal, CascadeMetrics.s3)
                    .padding(.vertical, CascadeMetrics.s2 + 1)
                    .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                HStack {
                    Button("Save key") { model.saveOpenAIKey(key); key = "" }.buttonStyle(CascadeAccentButtonStyle())
                    Button("Clear") { model.clearOpenAIKey(); key = "" }.buttonStyle(CascadeQuietButtonStyle())
                }
                Text("Stored in macOS Keychain. Powers talk-to-Cascade and spoken replies via OpenAI GPT-Realtime-2. Claude still does the thinking.")
                    .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            }
        }
    }
}

private struct EmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.cascadeSans(14, .semibold))
            Text(detail).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, CascadeMetrics.s2)
    }
}
