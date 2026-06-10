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
        }
        .foregroundStyle(Color.cascadeText)
        .frame(minWidth: 1040, minHeight: 720)
        .preferredColorScheme(model.prefersDark ? .dark : .light)
        .animation(.easeOut(duration: 0.18), value: model.dock.visible)
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
    @State private var searchText = ""
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
        HStack(alignment: .top, spacing: 0) {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, CascadeMetrics.s5)
                .padding(.vertical, CascadeMetrics.s4)
            AskPanel(model: model, selected: selected, draft: $draft)
                .frame(width: 360)
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
            searchField
            metaRow
            Text(headline)
                .font(.cascadeSerif(34))
                .italic()
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CascadeMetrics.s4)
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

    /// Full-text search across everything captured (OCR text, window title, app).
    /// Resets the scrubber to the top result whenever the query changes.
    private var searchField: some View {
        HStack(spacing: CascadeMetrics.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.cascadeText3)
            TextField("Search everything you’ve seen…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.cascadeSans(14))
                .onSubmit { model.search(searchText) }
                .onChange(of: searchText) { _, newValue in
                    index = 0
                    model.search(newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    index = 0
                    model.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.cascadeText3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, CascadeMetrics.s3)
        .padding(.vertical, CascadeMetrics.s2)
        .background(Color.cascadePanel2)
        .clipShape(RoundedRectangle(cornerRadius: CascadeMetrics.s2))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.s2).stroke(Color.cascadeBorder, lineWidth: 1))
    }

    private var metaRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: CascadeMetrics.s1) {
                CascadeTag("The Moment", tone: .cascadeText3)
                Text(timeRange).font(.cascadeMono(15, .medium))
            }
            Spacer()
            HStack(spacing: CascadeMetrics.s2) {
                Text("· IN").font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                if let selected {
                    HStack(spacing: CascadeMetrics.s1 + 2) {
                        Circle()
                            .fill(AppVisuals.color(for: selected.appName, bundleIdentifier: selected.bundleIdentifier))
                            .frame(width: 7, height: 7)
                        Text(selected.appName).font(.cascadeSans(13, .medium))
                    }
                } else {
                    Text("—").font(.cascadeMono(13)).foregroundStyle(Color.cascadeText3)
                }
            }
        }
    }

    private var headline: String {
        guard let selected else { return "Idle — no capture at this time." }
        if let title = selected.windowTitle, !title.isEmpty { return title }
        if let ocr = selected.ocrText, let first = ocr.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(first.prefix(90))
        }
        return "A local moment in \(selected.appName)"
    }

    private var timeRange: String {
        guard let selected else { return "— → now" }
        let start = selected.capturedAt
        let newer = index > 0 ? moments[index - 1].capturedAt : Date()
        return "\(Self.time(start)) → \(Self.time(newer))"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
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

    var body: some View {
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
        if let context, let path = context.imagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let context {
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(runs) { run in
                            AppVisuals.color(for: run.app, bundleIdentifier: run.bundle)
                                .frame(width: max(6, geo.size.width * CGFloat(run.count) / CGFloat(max(contexts.count, 1)) - 2))
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

    private func playheadX(_ width: CGFloat) -> CGFloat {
        let count = max(contexts.count, 1)
        let ordinal = count - 1 - min(max(currentIndex, 0), count - 1)  // 0 = oldest (left)
        let fraction = (Double(ordinal) + 0.5) / Double(count)
        return CGFloat(fraction) * width
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
                Text(selected.map { "\($0.appName)\($0.windowTitle.map { " · \($0)" } ?? "")" } ?? "Local record")
                    .font(.cascadeSans(13, .medium))
                    .foregroundStyle(Color.cascadeText2)
                    .lineLimit(1)
            }
            .padding(CascadeMetrics.s5)

            Divider().overlay(Color.cascadeBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: CascadeMetrics.s4) {
                    if model.conversation.isEmpty && !model.thinking {
                        Text("Ask anything about your recorded local context. Answers are grounded only in what was captured.")
                            .font(.cascadeSans(13))
                            .foregroundStyle(Color.cascadeText3)
                    }
                    ForEach(model.conversation) { turn in
                        ChatBubble(text: turn.question, mine: true)
                        ChatBubble(text: turn.answer, mine: false)
                    }
                    if model.thinking {
                        ChatBubble(text: model.answer, mine: false)
                    }
                }
                .padding(CascadeMetrics.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                FlowChips(items: suggestedQuestions) { q in model.ask(q) }
                HStack(spacing: CascadeMetrics.s2) {
                    TextField("Ask the rewind, or “where do I find X”…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.cascadeSans(13))
                        .padding(.horizontal, CascadeMetrics.s3)
                        .padding(.vertical, CascadeMetrics.s2 + 1)
                        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                        .onSubmit { send() }
                    Button { send() } label: {
                        Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.cascadeOnAccent)
                            .frame(width: 34, height: 32)
                            .background(Color.cascadeAgent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: CascadeMetrics.s2) {
                    Image(systemName: model.voice.state == .listening ? "waveform" : (model.voice.state == .working ? "ellipsis.circle" : "mic"))
                        .font(.system(size: 11))
                        .foregroundStyle(model.voice.state == .idle ? Color.cascadeText3 : Color.cascadeAgent)
                    Text(model.voice.hint)
                        .font(.cascadeSans(11))
                        .foregroundStyle(Color.cascadeText3)
                        .lineLimit(1)
                }
                Text(model.teachMessage)
                    .font(.cascadeSans(11))
                    .foregroundStyle(Color.cascadeText2)
            }
            .padding(CascadeMetrics.s5)
        }
        .background(Color.cascadePanel.opacity(0.5))
        .overlay(Rectangle().fill(Color.cascadeBorder).frame(width: 1), alignment: .leading)
    }

    private func send() {
        let q = draft
        draft = ""
        model.ask(q)
    }
}

private struct ChatBubble: View {
    let text: String
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 32) }
            Text(text)
                .font(.cascadeSans(13))
                .foregroundStyle(mine ? Color.cascadeOnAccent : Color.cascadeText)
                .padding(.horizontal, CascadeMetrics.s3)
                .padding(.vertical, CascadeMetrics.s2 + 1)
                .background(mine ? Color.cascadeAccent : Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(mine ? nil : RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
            if !mine { Spacer(minLength: 32) }
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
                    CascadeTag("Agents", tone: .cascadeAgent)
                    Text("Approved by your manager").font(.cascadeSerif(30))
                    Text("Cascade detects the tasks you repeat and sends them to your manager. The ones they approve land here — built from your real actions, ready to deploy.")
                        .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
                }
                agentsSection
                cascadeSection(
                    title: "CASCADES FROM YOUR MANAGER",
                    trailing: "\(model.visibleManagerCascades.count) pending",
                    suggestions: model.visibleManagerCascades,
                    fromManager: true,
                    empty: "When your manager cascades an agent from the Manager dashboard, it lands here to review and deploy."
                )
                activitySection
            }
            .padding(.horizontal, CascadeMetrics.s6)
            .padding(.vertical, CascadeMetrics.s6)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "YOUR AGENTS", trailing: "\(model.agents.count) approved")
            if model.agents.isEmpty {
                CascadePanel { EmptyState(title: "No agents yet", detail: "When your manager approves a workflow Cascade detected, the agent shows up here, ready to deploy.") }
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

    private func cascadeSection(title: String, trailing: String, suggestions: [AgentSuggestion], fromManager: Bool, empty: String) -> some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: title, trailing: trailing)
            if suggestions.isEmpty {
                CascadePanel { EmptyState(title: "Nothing here yet", detail: empty) }
            } else {
                ForEach(suggestions) { suggestion in
                    ManagerCascadeCard(
                        suggestion: suggestion,
                        fromManager: fromManager,
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

/// One-line summary of a recipe's steps, for the cards.
private func recipeSummary(_ recipe: AgentRecipe) -> String {
    let parts = recipe.steps.sorted { $0.order < $1.order }.prefix(10).map { step -> String in
        switch step.kind {
        case .activateApp: return step.appName
        case .click: return "click"
        case .doubleClick: return "2×click"
        case .rightClick: return "right-click"
        case .type: return "type"
        case .key: return (step.modifiers + [step.key ?? ""]).joined(separator: "+")
        case .scroll: return "scroll"
        }
    }
    return parts.joined(separator: " · ")
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

/// Manager-facing review card for a detected workflow. Shows the privacy-safe
/// summary (task, apps, frequency, time saved, step *shape*) — never the raw typed
/// text or coordinates — with approve/decline.
private struct WasteCard: View {
    let waste: DetectedWaste
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(alignment: .top) {
                    Text(waste.title).font(.cascadeSans(15, .semibold))
                    Spacer()
                    Text("\(waste.occurrences)× · ~\(max(1, waste.estimatedTotalSeconds / 60))m saved")
                        .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                }
                AppChips(apps: waste.apps)
                Text(recipeSummary(waste.recipe))
                    .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText2).lineLimit(2)
                HStack(spacing: CascadeMetrics.s2) {
                    Spacer()
                    Button(action: onDecline) { Text("Decline") }
                        .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                    Button(action: onApprove) { Text("Approve & send") }
                        .buttonStyle(CascadeAccentButtonStyle())
                }
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
        if let last = agent.lastRunAt {
            summary += " · last run \(last.formatted(date: .omitted, time: .shortened))"
        }
        return summary
    }
}

// MARK: - Manager screen (aggregate-only dashboard; cascades agents to the employee)

private struct ManagerScreen: View {
    @ObservedObject var model: CascadeAppModel

    private var appsObserved: Int { Set(model.contexts.map(\.appName)).count }

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
                    Text("Suggestions from privacy-safe signals").font(.cascadeSerif(30))
                    Text("Aggregate-only. You review the tasks Cascade detects the employee repeating — task, apps, frequency, time saved — and approve the agents worth running. Never raw OCR, screenshots, or keystrokes.")
                        .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
                }
                HStack(spacing: CascadeMetrics.s3) {
                    MetricCard(value: "\(model.contexts.count)", label: "Local samples")
                    MetricCard(value: "\(appsObserved)", label: "Apps observed")
                    MetricCard(value: "\(model.pendingDetectedWaste.count)", label: "To review")
                    MetricCard(value: "\(model.agents.count)", label: "Approved")
                    MetricCard(value: "0", label: "Raw screenshots")
                }
                VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                    SectionLabel(title: "DETECTED WORKFLOWS — REVIEW & APPROVE", trailing: "\(model.pendingDetectedWaste.count) pending")
                    if model.pendingDetectedWaste.isEmpty {
                        CascadePanel { EmptyState(title: "Nothing to review", detail: "When the employee repeats a task, Cascade surfaces it here — task, apps, frequency, time saved — for you to approve or decline. Approved agents are sent to their Cascades tab.") }
                    } else {
                        ForEach(model.pendingDetectedWaste) { waste in
                            WasteCard(
                                waste: waste,
                                onApprove: { model.approveWaste(waste) },
                                onDecline: { model.declineWaste(waste) }
                            )
                        }
                    }
                }
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
                            AgentActivityRow(event: AuditEvent(actor: "manager", action: "cascade.sent", detail: cascade.title))
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
    let suggestion: AgentSuggestion
    var fromManager: Bool = false
    let onDeploy: () -> Void
    let onDecline: () -> Void

    private var eyebrow: String {
        fromManager
            ? "CASCADED FROM YOUR MANAGER"
            : "DETECTED · \(suggestion.kind.rawValue.uppercased()) · \(Int(suggestion.confidence * 100))% CONFIDENCE"
    }

    var body: some View {
        HStack(alignment: .top, spacing: CascadeMetrics.s4) {
            RoundedRectangle(cornerRadius: 3).fill(Color.cascadeAgent).frame(width: 3)
            Image(systemName: fromManager ? "person.badge.shield.checkmark" : "wand.and.stars")
                .font(.system(size: 18)).foregroundStyle(Color.cascadeAgent).frame(width: 28)
            VStack(alignment: .leading, spacing: CascadeMetrics.s1 + 2) {
                Text(eyebrow)
                    .font(.cascadeMono(10, .semibold)).foregroundStyle(Color.cascadeAgent)
                Text(suggestion.title).font(.cascadeSans(15, .semibold))
                Text(suggestion.summary).font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2).lineLimit(2)
                if let evidence = suggestion.evidence.first {
                    Text("↳ \(evidence)").font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                }
            }
            Spacer()
            VStack(spacing: CascadeMetrics.s2) {
                Button("DEPLOY  →") { onDeploy() }.buttonStyle(AgentButtonStyle())
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
        HStack(spacing: CascadeMetrics.s2) {
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
