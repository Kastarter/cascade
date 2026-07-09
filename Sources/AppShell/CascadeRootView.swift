import AgentOrchestrator
import AppKit
import CascadeDesignSystem
import CascadeMemory
import MacContextKit
import ProviderKit
import WasteDetection
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
            if model.teachingMode || model.teachStatus != nil {
                TeachBanner(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.teachPreview != nil {
                TeachPreviewSheet(model: model)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Color.cascadeText)
        .frame(minWidth: 1040, minHeight: 720)
        .preferredColorScheme(model.prefersDark ? .dark : .light)
        .animation(.easeOut(duration: 0.18), value: model.dock.visible)
        .animation(.easeOut(duration: 0.22), value: model.showOnboarding)
        .animation(.easeOut(duration: 0.2), value: model.teachingMode)
        .animation(.easeOut(duration: 0.2), value: model.teachStatus)
        .animation(.easeOut(duration: 0.2), value: model.teachPreview?.id)
    }
}

// MARK: - Teach-once (banner + preview sheet)

/// The live demonstration banner: a floating pill at the top of the window while
/// the user is teaching (or showing the terminal result of the last demo).
private struct TeachBanner: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        HStack(spacing: CascadeMetrics.s3) {
            Image(systemName: model.teachingMode ? "record.circle.fill" : "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.teachingMode ? Color.cascadeRecText : Color.cascadeAgent)
            Text(model.teachStatus ?? "Teaching…")
                .font(.cascadeSans(13, .semibold))
                .foregroundStyle(Color.cascadeText)
                .fixedSize(horizontal: false, vertical: true)
            if model.teachingMode {
                Button("Finish  ⌥⌃T") { model.toggleTeaching() }
                    .buttonStyle(CascadeAccentButtonStyle())
            } else if model.teachStatus != nil {
                Button { model.dismissTeachStatus() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
            }
        }
        .padding(.leading, CascadeMetrics.s4)
        .padding(.trailing, CascadeMetrics.s3)
        .padding(.vertical, CascadeMetrics.s3)
        .background(Color.cascadePanel, in: Capsule())
        .overlay(Capsule().stroke(model.teachingMode ? Color.cascadeRecText.opacity(0.5) : Color.cascadeBorderHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
    }
}

/// After a demonstration, the curated agent to review before it's created — its
/// human name, the goal a deployed agent will run, where it will run, and a chip
/// back to the recording it was built from. The user picks "Add to my agents"
/// (self-serve into Cascades) or "Send to manager" (into the review queue).
private struct TeachPreviewSheet: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { model.teachPreview = nil }
            if let curated = model.teachPreview {
                card(curated)
                    .frame(maxWidth: 540)
                    .padding(CascadeMetrics.s6)
            }
        }
    }

    private func card(_ curated: CuratedAgent) -> some View {
        let goal = curated.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let background = CascadeAppModel.runsInBackground(apps: curated.apps)
        return CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s4) {
                HStack(spacing: CascadeMetrics.s2) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12)).foregroundStyle(Color.cascadeAgent)
                    Text("You taught Cascade a task").font(.cascadeSans(12, .semibold)).foregroundStyle(Color.cascadeText3)
                    Spacer()
                    CascadeTag(background ? "BACKGROUND" : "ON SCREEN", tone: background ? .cascadeAgent : .cascadeAccentWarm)
                }
                Text(curated.name).font(.cascadeSerif(24)).fixedSize(horizontal: false, vertical: true)
                if !curated.why.isEmpty {
                    Text(curated.why).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !curated.apps.isEmpty { AppChips(apps: curated.apps) }
                VStack(alignment: .leading, spacing: 5) {
                    Text("WHEN DEPLOYED, CASCADE WILL")
                        .font(.cascadeMono(9, .semibold)).tracking(0.7).foregroundStyle(Color.cascadeText4)
                    Text(goal.isEmpty ? curated.name : goal)
                        .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                provenance(curated)
                HStack(spacing: CascadeMetrics.s2) {
                    Button("Cancel") { model.teachPreview = nil }
                        .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                    Spacer()
                    Button("Send to manager") { model.sendTaughtAgentToManager(curated) }
                        .buttonStyle(.plain).foregroundStyle(Color.cascadeText)
                    Button("Add to my agents  →") { model.createTaughtAgent(curated) }
                        .buttonStyle(CascadeAccentButtonStyle())
                }
            }
        }
    }

    /// A chip back to the recording this was built from — the proof it's grounded in
    /// what the user actually did, not invented.
    private func provenance(_ curated: CuratedAgent) -> some View {
        Button {
            model.teachPreview = nil
            model.jumpToReel(at: curated.source.lastSeenAt)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "film").font(.system(size: 10))
                Text("Built from your recording · \(curated.source.lastSeenAt.formatted(date: .omitted, time: .shortened))")
                    .font(.cascadeMono(11))
            }
            .foregroundStyle(Color.cascadeAgent)
        }
        .buttonStyle(.plain)
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
                    step(number: 4, title: "Personalize", done: true,
                         detail: "Optional local defaults for when Cascade surfaces suggestions and whether browser agents should be favored.") {
                        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                            Picker("Suggestion timing", selection: $model.suggestionTimingPreference) {
                                Text("Early").tag(CascadeAppModel.SuggestionTimingPreference.early)
                                Text("Balanced").tag(CascadeAppModel.SuggestionTimingPreference.balanced)
                                Text("Strong evidence").tag(CascadeAppModel.SuggestionTimingPreference.strongEvidence)
                            }
                            .pickerStyle(.segmented)
                            Picker("Background agents", selection: $model.backgroundAgentPreference) {
                                Text("Prefer").tag(CascadeAppModel.BackgroundAgentPreference.prefer)
                                Text("Ask first").tag(CascadeAppModel.BackgroundAgentPreference.askFirst)
                                Text("Avoid").tag(CascadeAppModel.BackgroundAgentPreference.avoid)
                            }
                            .pickerStyle(.segmented)
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

    /// The moment the scrubber is parked on, tracked by ID so live captures
    /// prepending to the array can't silently shift the selection. `nil` = ride
    /// the live edge.
    @State private var anchorID: Int64?

    /// Search results when a query is active, otherwise the displayed day —
    /// a past day when a citation jumped there, today's timeline otherwise.
    private var moments: [RecordedContext] {
        guard model.searchQuery.isEmpty else { return model.searchResults }
        return model.reelWindow?.contexts ?? model.reelTimeline
    }
    /// Cheap change stamp for the timeline — comparing full ID arrays on every
    /// live update is an O(n) scan per publish; count + newest ID catches every
    /// prepend/replacement the Reel cares about.
    private struct TimelineStamp: Equatable {
        let count: Int
        let newestID: Int64?
    }
    private var timelineStamp: TimelineStamp {
        TimelineStamp(count: moments.count, newestID: moments.first?.id)
    }
    /// Local midnight of the day the timeline strip is showing.
    private var timelineDayStart: Date {
        model.reelWindow?.dayStart ?? Calendar.current.startOfDay(for: Date())
    }
    private var selected: RecordedContext? {
        guard !moments.isEmpty else { return nil }
        return moments[min(max(index, 0), moments.count - 1)]
    }
    /// True when riding the newest moment of *today* ("now").
    private var isLive: Bool { index == 0 && model.reelWindow == nil }

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
        .onChange(of: index) { _, _ in
            // Any scrub (user, playback, or jump) re-pins the anchor; parking on
            // today's live edge clears it so the view keeps riding "now".
            anchorID = isLive ? nil : selected?.id
        }
        .onChange(of: timelineStamp) { _, _ in
            // Live captures prepend to the array — without an ID anchor the same
            // index silently becomes a different (newer) moment every few seconds.
            if let anchorID, let pinned = moments.firstIndex(where: { $0.id == anchorID }) {
                index = pinned
            } else {
                index = min(index, max(moments.count - 1, 0))
            }
        }
        .onChange(of: model.reelJumpTarget) { _, target in
            // A citation chip was clicked — scrub to the moment it cites. The
            // model has already loaded the cited day into `reelWindow` if needed.
            guard let target, !moments.isEmpty else { return }
            isPlaying = false
            index = moments.indices.min(by: {
                abs(moments[$0].capturedAt.timeIntervalSince(target)) < abs(moments[$1].capturedAt.timeIntervalSince(target))
            }) ?? 0
            anchorID = selected?.id
            model.reelJumpTarget = nil
        }
    }

    /// GO LIVE: drop any past-day window and ride today's newest moment again.
    private func returnToLive() {
        model.returnReelToLive()
        isPlaying = false
        index = 0
        anchorID = nil
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
            SceneCard(
                context: selected,
                clickMarkers: selected.map { model.reelClickMarkersByContextID[$0.id] ?? [] } ?? []
            )
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
                },
                onLive: returnToLive
            )
            ActivityTimeline(
                contexts: moments,
                dayStart: timelineDayStart,
                currentIndex: index,
                onScrub: { newIndex in
                    index = newIndex
                    isPlaying = false
                }
            )
        }
        .onAppear { model.refreshClickMarkers(near: selected) }
        .onChange(of: selected?.id) { _, _ in model.refreshClickMarkers(near: selected) }
    }

    private var headline: String {
        guard let selected else { return "Idle — no capture at this time." }
        if let title = selected.windowTitle, !title.isEmpty { return Self.cleanTitle(title) }
        if let ocr = selected.ocrText, let first = ocr.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(first.prefix(90))
        }
        return "A local moment in \(CascadeAppModel.displayApp(appName: selected.appName, windowTitle: selected.windowTitle))"
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
    let clickMarkers: [ReelClickMarker]

    private struct DisplayMetadata: Decodable {
        let id: UInt32?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct SceneMetadata: Decodable {
        let w: Int?
        let h: Int?
        let display: DisplayMetadata?
    }

    @ViewBuilder var body: some View {
        if let context, let path = context.imagePath, let image = NSImage(contentsOfFile: path) {
            screenshotCard(image, context: context)
        } else {
            panelCard
        }
    }

    /// Full-width card, flush with the transport bar below, and the capture fills
    /// it edge-to-edge like fullscreen video — cropping a sliver of the frame when
    /// the aspect ratios differ rather than ever showing a letterbox.
    private func screenshotCard(_ image: NSImage, context: RecordedContext) -> some View {
        ZStack(alignment: .topTrailing) {
            // Color.clear sized by the card + overlay/clipped keeps scaledToFill's
            // natural-size overflow from inflating the layout.
            Color.clear
                .overlay {
                    // A short crossfade between moments makes scrubbing read as
                    // continuous footage instead of flipping screenshots.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: context.id)
                }
                .clipped()
            clickOverlay(context: context, image: image)
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

    private func clickOverlay(context: RecordedContext, image: NSImage) -> some View {
        GeometryReader { geo in
            ForEach(clickMarkers) { marker in
                if let point = markerPoint(marker, context: context, image: image, container: geo.size) {
                    ZStack {
                        Circle()
                            .stroke(Color.cascadeRecText, lineWidth: 2)
                            .frame(width: 22, height: 22)
                        Circle()
                            .fill(Color.cascadeRecDot)
                            .frame(width: 6, height: 6)
                    }
                    .shadow(color: .black.opacity(0.65), radius: 4)
                    .position(point)
                    .help(marker.label ?? marker.targetDescriptor ?? "Click")
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func markerPoint(
        _ marker: ReelClickMarker,
        context: RecordedContext,
        image: NSImage,
        container: CGSize
    ) -> CGPoint? {
        guard container.width > 0, container.height > 0,
              let metadata = metadata(for: context),
              let display = metadata.display,
              display.width > 0,
              display.height > 0 else { return nil }

        let normalizedX = (marker.x - display.x) / display.width
        let normalizedY = 1 - ((marker.y - display.y) / display.height)
        guard (0...1).contains(normalizedX), (0...1).contains(normalizedY) else { return nil }

        let imageWidth = CGFloat(metadata.w ?? Int(image.size.width))
        let imageHeight = CGFloat(metadata.h ?? Int(image.size.height))
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let imageAspect = imageWidth / imageHeight
        let containerAspect = container.width / container.height
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        if containerAspect > imageAspect {
            drawWidth = container.width
            drawHeight = container.width / imageAspect
            offsetX = 0
            offsetY = (container.height - drawHeight) / 2
        } else {
            drawHeight = container.height
            drawWidth = container.height * imageAspect
            offsetX = (container.width - drawWidth) / 2
            offsetY = 0
        }
        return CGPoint(
            x: offsetX + CGFloat(normalizedX) * drawWidth,
            y: offsetY + CGFloat(normalizedY) * drawHeight
        )
    }

    private func metadata(for context: RecordedContext) -> SceneMetadata? {
        guard let json = context.metadataJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SceneMetadata.self, from: data)
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
                    Text("A local moment in \(CascadeAppModel.displayApp(appName: context.appName, windowTitle: context.windowTitle))")
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
    let onLive: () -> Void

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
            // both). Scrubbed: "current / latest" plus a GO LIVE button back to
            // now. Everything here is fixed-size so a narrow window can never
            // squeeze the text into a vertical wrap.
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
                    goLiveButton
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

    /// Shown while scrubbed back (or parked on a past day) — one click back to now.
    private var goLiveButton: some View {
        Button(action: onLive) {
            HStack(spacing: 5) {
                Circle().fill(Color.cascadeText3).frame(width: 6, height: 6)
                Text("GO LIVE")
                    .font(.cascadeMono(10, .semibold))
                    .tracking(0.6)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, CascadeMetrics.s2)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(Color.cascadeBorderHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.cascadeText2)
        .help("Back to the newest moment")
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
    /// Local midnight of the day this strip shows. The axis is always the real
    /// 24-hour clock of that day — busy hours don't stretch, idle hours don't
    /// vanish; every moment sits at its true time of day.
    let dayStart: Date
    /// Current scrubber position as an index into `contexts` (0 = newest / live).
    let currentIndex: Int
    /// Called when the user clicks or drags the bar to a different moment.
    let onScrub: (Int) -> Void

    private struct Segment: Identifiable {
        let id = UUID()
        let app: String
        let bundle: String?
        let start: Date
        let end: Date
    }
    private struct LegendItem: Identifiable { let id: String; let app: String; let bundle: String? }

    /// A capture gap wider than this ends a segment, so idle time reads as an
    /// empty stretch of track instead of one app smearing across it.
    private static let gapBreak: TimeInterval = 180
    /// A lone moment still paints a visible sliver of activity.
    private static let minimumSpan: TimeInterval = 45

    /// The day in real time: length of the displayed calendar day (DST-aware).
    private var dayDuration: TimeInterval {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 3600)
        return max(end.timeIntervalSince(dayStart), 1)
    }

    /// 0…1 position of a date across the displayed day.
    private func dayFraction(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(dayStart) / dayDuration, 0), 1))
    }

    /// The strip paints at most ~1500 moments; beyond that, stride-sample. A
    /// full day at one capture per second is tens of thousands of rows —
    /// painting them all on every update costs main-thread milliseconds for
    /// sub-pixel detail no one can see. Scrubbing still uses the full list.
    private var paintSource: [RecordedContext] {
        let limit = 1500
        guard contexts.count > limit else { return contexts }
        let stride = contexts.count / limit + 1
        return contexts.enumerated().compactMap { index, element in
            index % stride == 0 ? element : nil
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for context in paintSource.reversed() {
            // Group by the web app inside the browser when there is one, so the lanes
            // read "Gmail" / "Google Docs" instead of one long "Google Chrome".
            let app = CascadeAppModel.displayApp(appName: context.appName, windowTitle: context.windowTitle)
            let bundle = app == context.appName ? context.bundleIdentifier : nil
            let at = context.capturedAt
            if let last = result.last, last.app == app, at.timeIntervalSince(last.end) <= Self.gapBreak {
                result[result.count - 1] = Segment(app: last.app, bundle: last.bundle, start: last.start, end: at)
            } else {
                result.append(Segment(app: app, bundle: bundle, start: at, end: at))
            }
        }
        return result
    }

    /// The day's apps by time spent, biggest first, capped so the legend can't
    /// overflow the strip on a many-app day.
    private var legend: [LegendItem] {
        var duration: [String: TimeInterval] = [:]
        var bundles: [String: String?] = [:]
        for segment in segments {
            duration[segment.app, default: 0] += max(segment.end.timeIntervalSince(segment.start), Self.minimumSpan)
            if bundles[segment.app] == nil { bundles[segment.app] = segment.bundle }
        }
        return duration.sorted { $0.value > $1.value }.prefix(6).map {
            LegendItem(id: $0.key, app: $0.key, bundle: bundles[$0.key] ?? nil)
        }
    }

    private var legendOverflowCount: Int {
        max(Set(segments.map(\.app)).count - 6, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
            label
            track
            axis
        }
    }

    @ViewBuilder private var label: some View {
        if segments.isEmpty {
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
                if legendOverflowCount > 0 {
                    Text("+\(legendOverflowCount) more").font(.cascadeMono(10)).foregroundStyle(Color.cascadeText3)
                }
            }
        }
    }

    @ViewBuilder private var track: some View {
        if segments.isEmpty {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cascadePanel2)
                .frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
        } else {
            // Canvas paints each segment at its true clock position across the
            // fixed 24h day, with hour gridlines so empty stretches stay legible.
            let painted = segments.map {
                (color: AppVisuals.color(for: $0.app, bundleIdentifier: $0.bundle), start: $0.start, end: $0.end)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        for hour in 1..<24 {
                            let x = size.width * CGFloat(hour) / 24
                            context.fill(
                                Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                with: .color(Color.cascadeBorder.opacity(hour % 6 == 0 ? 0.9 : 0.45))
                            )
                        }
                        for segment in painted {
                            let paintedEnd = max(segment.end, segment.start.addingTimeInterval(Self.minimumSpan))
                            let startX = dayFraction(segment.start) * size.width
                            let endX = max(dayFraction(paintedEnd) * size.width, startX + 1.5)
                            let rect = CGRect(x: startX, y: 0, width: endX - startX, height: size.height)
                            context.fill(Path(rect), with: .color(segment.color))
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
            .help("Click or drag to scrub through your day")
        }
    }

    /// White handle marking the current moment at its real time of day.
    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.cascadeText)
            .frame(width: 3, height: height + 8)
            .shadow(color: .black.opacity(0.55), radius: 2)
            .position(x: playheadX(width), y: height / 2)
            .allowsHitTesting(false)
    }

    private func playheadX(_ width: CGFloat) -> CGFloat {
        guard !contexts.isEmpty else { return 2 }
        let clamped = min(max(currentIndex, 0), contexts.count - 1)
        let x = dayFraction(contexts[clamped].capturedAt) * width
        return min(max(x, 2), width - 2)
    }

    /// Maps a tap/drag X to a clock time on the day, then to the nearest captured
    /// moment (only reporting real changes, so dragging inside one moment doesn't
    /// thrash state). Clicking an idle stretch lands on the closest evidence.
    private func scrub(toX x: CGFloat, width: CGFloat) {
        guard !contexts.isEmpty, width > 0 else { return }
        let fraction = min(max(Double(x / width), 0), 1)
        let target = dayStart.addingTimeInterval(fraction * dayDuration)
        let newIndex = contexts.indices.min(by: {
            abs(contexts[$0].capturedAt.timeIntervalSince(target)) < abs(contexts[$1].capturedAt.timeIntervalSince(target))
        }) ?? 0
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

    /// Real clock labels every 3 hours across the fixed 24h day, midnight →
    /// midnight, matching the track's true-time positions.
    private var axisLabels: [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return stride(from: 0, through: 24, by: 3).map { hour in
            formatter.string(from: dayStart.addingTimeInterval(Double(hour) * 3600)).lowercased()
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
                            if !turn.citations.isEmpty {
                                CitationChips(citations: turn.citations) { model.jumpToMoment($0) }
                            }
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
        let app = CascadeAppModel.displayApp(appName: selected.appName, windowTitle: selected.windowTitle)
        if let title = selected.windowTitle, !title.isEmpty, title != selected.appName, title != app {
            return "\(app) · \(title)"
        }
        return app
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
        model.audit.filter(Self.isAgentActivity)
    }

    private static func isAgentActivity(_ event: AuditEvent) -> Bool {
        let action = event.action
        if action.hasPrefix("step.") || action.hasPrefix("agent.") || action.hasPrefix("assist.")
            || action.hasPrefix("sandbox.") || action.hasPrefix("harness.") {
            return true
        }
        return action == "computer.act"
            || action == "computer.zoom"
            || action == "grounding.verifier"
            || action == "scout.ocr.marks"
    }

    /// Newly approved agent to flash + scroll to, so an approve never feels
    /// like the card just vanished.
    @State private var flashAgentID: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: CascadeMetrics.s6) {
                    VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                        CascadeTag("Cascades", tone: .cascadeAgent)
                        Text("Everything you can run").font(.cascadeSerif(30))
                        Text("Cascade catches what you repeat and your manager reviews it. Once approved, it lands here as an agent that runs the task for you — in the background for web work, on-screen for everything else.")
                            .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
                    }
                    teachPrompt
                    pipelineStrip
                    agentsSection.id(Self.agentsAnchor)
                    learnedSkillsSection
                    activitySection
                }
                .padding(.horizontal, CascadeMetrics.s6)
                .padding(.vertical, CascadeMetrics.s6)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.agents.count) { previous, current in
                // An approve just landed an agent — take the user to it.
                guard current > previous, let newest = model.agents.first else { return }
                flashAgentID = newest.id
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(Self.agentsAnchor, anchor: .top)
                }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.6)) { flashAgentID = nil }
                }
            }
        }
    }

    private static let agentsAnchor = "your-agents"

    /// The front door to Teach-once: do the task once by hand and Cascade builds the
    /// agent. Mirrors the ⌥⌃T hotkey so it's discoverable without knowing the chord.
    private var teachPrompt: some View {
        HStack(spacing: CascadeMetrics.s3) {
            Image(systemName: "hand.raised.fill").font(.system(size: 15)).foregroundStyle(Color.cascadeAgent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Teach Cascade a task").font(.cascadeSans(14, .semibold))
                Text("Do it once by hand — narrate if you like — and Cascade turns the recording into an agent.")
                    .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            }
            Spacer()
            Button(model.teachingMode ? "Finish  ⌥⌃T" : "Teach a task  ⌥⌃T") { model.toggleTeaching() }
                .buttonStyle(CascadeAccentButtonStyle())
        }
        .padding(CascadeMetrics.s4)
        .background(Color.cascadePanel2.opacity(0.5), in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }

    /// The page's mental model in one strip: manager-approved → ready → runs.
    private var pipelineStrip: some View {
        HStack(spacing: CascadeMetrics.s2) {
            PipelineStat(value: "\(model.agents.count)", label: "AGENTS READY", icon: "bolt.badge.checkmark")
            pipelineArrow
            PipelineStat(value: "\(model.agents.filter(\.enabled).count)", label: "ENABLED", icon: "power")
            pipelineArrow
            PipelineStat(value: "\(model.agents.map(\.runCount).reduce(0, +))", label: "RUNS DONE", icon: "checkmark.seal")
            Spacer()
        }
    }

    private var pipelineArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.cascadeText4)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            SectionLabel(title: "YOUR AGENTS — APPROVED BY YOUR MANAGER", trailing: "\(model.agents.count) ready")
            if model.agents.isEmpty {
                CascadePanel { EmptyState(title: "No agents yet", detail: "When your manager approves a workflow Cascade caught, it lands right here as an agent — ready to run the task for you in the background.") }
            } else {
                ForEach(model.agents) { agent in
                    AgentCard(
                        agent: agent,
                        flash: agent.id == flashAgentID,
                        onDeploy: { model.deployAgent(agent) },
                        onToggle: { model.setAgentEnabled(agent, enabled: $0) },
                        onDelete: { model.deleteAgent(agent) },
                        onSchedule: { model.setAgentSchedule(agent, schedule: $0) }
                    )
                }
            }
        }
    }

    /// Skills the agent drafted from its own successful runs — the library
    /// compounds with usage instead of with hand-written files. Hidden until
    /// there's something to review.
    @ViewBuilder private var learnedSkillsSection: some View {
        if !model.pendingLearnedSkills.isEmpty {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                SectionLabel(title: "LEARNED SKILLS — REVIEW", trailing: "\(model.pendingLearnedSkills.count) drafted")
                ForEach(model.pendingLearnedSkills) { skill in
                    let consolidationHint = model.learnedSkillConsolidationHint(for: skill)
                    CascadePanel {
                        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                            HStack(spacing: CascadeMetrics.s2) {
                                Image(systemName: "graduationcap.fill")
                                    .font(.system(size: 12)).foregroundStyle(Color.cascadeAgent)
                                Text("New skill for \(skill.appName)").font(.cascadeSans(15, .semibold))
                                Spacer()
                            }
	                            Text("Distilled from “\(skill.sourceTask)”. Approve and the agent pulls this playbook every time it works in \(skill.appName).")
	                                .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
	                            if !skill.sourceCaseIDs.isEmpty {
	                                Text("Source cases \(skill.sourceCaseIDs.map(String.init).joined(separator: ", ")) · evidence \(skill.evidenceIDs.count)")
	                                    .font(.cascadeMono(10))
	                                    .foregroundStyle(Color.cascadeText3)
	                            }
	                            if let consolidationHint {
	                                learnedSkillConsolidationRow(consolidationHint)
	                            }
                            Text(skill.markdown)
                                .font(.cascadeMono(10)).foregroundStyle(Color.cascadeText2)
                                .lineLimit(10)
                                .padding(CascadeMetrics.s3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.cascadePanel2.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            HStack {
                                Spacer()
                                Button("Discard") { model.discardLearnedSkill(skill) }
                                    .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                                Button("Add to skill library") { model.approveLearnedSkill(skill) }
                                    .buttonStyle(CascadeAccentButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }

    private func learnedSkillConsolidationRow(_ hint: CascadeAppModel.LearnedSkillConsolidationHint) -> some View {
        HStack(alignment: .top, spacing: CascadeMetrics.s2) {
            Image(systemName: learnedSkillConsolidationIcon(hint.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(learnedSkillConsolidationColor(hint.kind))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CascadeMetrics.s2) {
                    Text(hint.title)
                        .font(.cascadeSans(12, .semibold))
                        .foregroundStyle(Color.cascadeText)
                    if let score = hint.score {
                        Text("\(Int((score * 100).rounded()))% overlap")
                            .font(.cascadeSans(11))
                            .foregroundStyle(Color.cascadeText3)
                    }
                }
	                Text(hint.detail)
	                    .font(.cascadeSans(12))
	                    .foregroundStyle(Color.cascadeText3)
	                    .fixedSize(horizontal: false, vertical: true)
	                HStack(spacing: CascadeMetrics.s2) {
	                    Text("risk \(hint.predictedRisk.rawValue)")
	                    Text("\(hint.successCount) success")
	                    if hint.failureCount > 0 { Text("\(hint.failureCount) failure") }
	                    if !hint.sourceCaseIDs.isEmpty { Text("cases \(hint.sourceCaseIDs.map(String.init).joined(separator: ","))") }
	                }
	                .font(.cascadeMono(10))
	                .foregroundStyle(Color.cascadeText3)
	                if !hint.requiredEvidence.isEmpty {
	                    Text("Needs \(hint.requiredEvidence.joined(separator: ", "))")
	                        .font(.cascadeSans(11))
	                        .foregroundStyle(Color.cascadeText3)
	                }
	                if !hint.mergeReason.isEmpty {
	                    Text(hint.mergeReason)
	                        .font(.cascadeSans(11))
	                        .foregroundStyle(Color.cascadeText3)
	                }
	            }
	        }
        .padding(CascadeMetrics.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(learnedSkillConsolidationColor(hint.kind).opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(learnedSkillConsolidationColor(hint.kind).opacity(0.28), lineWidth: 1)
        )
    }

    private func learnedSkillConsolidationIcon(_ kind: CascadeAppModel.LearnedSkillConsolidationHint.Kind) -> String {
        switch kind {
        case .newSkill: "sparkles"
        case .reviseExisting: "pencil.and.outline"
        case .archiveCandidate: "archivebox"
        case .quarantine: "exclamationmark.triangle"
        }
    }

    private func learnedSkillConsolidationColor(_ kind: CascadeAppModel.LearnedSkillConsolidationHint.Kind) -> Color {
        switch kind {
        case .newSkill: Color.cascadeAgent
        case .reviseExisting: Color.cascadeAccent
        case .archiveCandidate: Color.cascadeText3
        case .quarantine: Color.cascadeRecText
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

/// Review card for a detected workflow (Manager review queue): a rewind frame as
/// visual evidence and the curator's plain-language description of what the agent
/// will do — formal and beautiful, never the raw click·scroll·click token soup.
/// The recorded recipe stays internal (it guides the deployed agent and lives in
/// the audit log); the card shows the intent, not the keystrokes.
private struct WasteCard: View {
    let curated: CuratedAgent
    let evidenceImagePath: String?
    let onApprove: () -> Void
    let onDecline: () -> Void

    /// The recorded workflow behind the curated proposal — recipe, apps, evidence.
    private var waste: DetectedWaste { curated.source }

    var body: some View {
        CascadePanel {
            HStack(alignment: .top, spacing: CascadeMetrics.s4) {
                thumbnail
                VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                    HStack(alignment: .top) {
                        Text(curated.name).font(.cascadeSans(15, .semibold))
                        Spacer()
                        Text("\(waste.occurrences)× · ~\(max(1, waste.estimatedTotalSeconds / 60))m saved")
                            .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                            .fixedSize()
                    }
                    if !curated.why.isEmpty {
                        Text(curated.why)
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AppChips(apps: waste.apps)
                    whatItDoes
                    HStack(spacing: CascadeMetrics.s2) {
                        Text("last seen \(waste.lastSeenAt.formatted(date: .omitted, time: .shortened))")
                            .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText4)
                        Spacer()
                        Button(action: onDecline) { Text("Dismiss") }
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

    /// What approving will do, in the curator's words — the intent, not the
    /// keystrokes. Falls back to the workflow's name if no goal was written.
    private var whatItDoes: some View {
        let goal = curated.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            Text("WHEN DEPLOYED, CASCADE WILL")
                .font(.cascadeMono(9, .semibold)).tracking(0.7).foregroundStyle(Color.cascadeText4)
            Text(goal.isEmpty ? curated.name : goal)
                .font(.cascadeSans(13)).foregroundStyle(Color.cascadeText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 10)).foregroundStyle(Color.cascadeAgent)
                Text("Runs in the background — the employee's screen stays theirs.")
                    .font(.cascadeSans(11)).foregroundStyle(Color.cascadeText3)
            }
            .padding(.top, 2)
        }
    }
}

private struct ContextWasteCard: View {
    let curated: CuratedContextWaste
    let evidenceImagePath: String?
    let onApprove: () -> Void
    let onDecline: () -> Void

    private var waste: ContextWasteCandidate { curated.source }

    var body: some View {
        CascadePanel {
            HStack(alignment: .top, spacing: CascadeMetrics.s4) {
                thumbnail
                VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                    HStack(alignment: .top) {
                        Text(curated.name).font(.cascadeSans(15, .semibold))
                        CascadeTag(feasibilityLabel, tone: curated.feasibility == .needsDemo ? .cascadeAccentWarm : .cascadeAgent)
                        Spacer()
                        Text("\(waste.occurrences)× · ~\(max(1, waste.estimatedTotalSeconds / 60))m observed")
                            .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                            .fixedSize()
                    }
                    if !curated.why.isEmpty {
                        Text(curated.why)
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AppChips(apps: waste.apps)
                    whatItDoes
                    safeEvidence
                    HStack(spacing: CascadeMetrics.s2) {
                        Text("last seen \(waste.lastSeenAt.formatted(date: .omitted, time: .shortened))")
                            .font(.cascadeMono(11)).foregroundStyle(Color.cascadeText4)
                        Spacer()
                        Button(action: onDecline) { Text("Dismiss") }
                            .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                        Button(action: onApprove) { Text(primaryActionTitle) }
                            .buttonStyle(CascadeAccentButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let path = evidenceImagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 116, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorderHi, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cascadePanel2)
                .frame(width: 116, height: 74)
                .overlay(Image(systemName: "text.viewfinder").foregroundStyle(Color.cascadeAgent))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorderHi, lineWidth: 1))
        }
    }

    private var whatItDoes: some View {
        let goal = curated.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            Text("WHEN DEPLOYED, CASCADE WILL")
                .font(.cascadeMono(9, .semibold)).tracking(0.7).foregroundStyle(Color.cascadeText4)
            Text(goal.isEmpty ? curated.name : goal)
                .font(.cascadeSans(13)).foregroundStyle(Color.cascadeText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Image(systemName: curated.feasibility == .needsDemo ? "record.circle" : (CascadeAppModel.runsInBackground(apps: waste.apps) ? "macwindow.badge.plus" : "cursorarrow.rays"))
                    .font(.system(size: 10)).foregroundStyle(Color.cascadeAgent)
                Text(executionSummary)
                    .font(.cascadeSans(11)).foregroundStyle(Color.cascadeText3)
            }
            .padding(.top, 2)
        }
    }

    private var safeEvidence: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("EVIDENCE")
                .font(.cascadeMono(9, .semibold)).tracking(0.7).foregroundStyle(Color.cascadeText4)
            Text(evidenceSummary)
                .font(.cascadeSans(12))
                .foregroundStyle(Color.cascadeText3)
                .fixedSize(horizontal: false, vertical: true)
            if !parameterSummary.isEmpty {
                Text(parameterSummary)
                    .font(.cascadeMono(10))
                    .foregroundStyle(Color.cascadeText4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var evidenceSummary: String {
        let anchors = "\(waste.evidenceContextIDs.count) Rewind anchors across \(waste.sessionIDs.count) task episodes"
        let terms = waste.processTerms.prefix(5).joined(separator: ", ")
        return terms.isEmpty ? anchors : "\(anchors) · process terms: \(terms)"
    }

    private var parameterSummary: String {
        waste.parameters.prefix(5).map { parameter in
            "\(parameter.role):\(parameter.count)"
        }.joined(separator: " · ")
    }

    private var feasibilityLabel: String {
        switch curated.feasibility {
        case .linkedRecipe: "LINKED"
        case .needsDemo: "TEACH"
        case .goalOnlyCandidate: "CONTEXT"
        }
    }

    private var primaryActionTitle: String {
        switch curated.feasibility {
        case .linkedRecipe: "Approve linked agent"
        case .needsDemo: "Teach once"
        case .goalOnlyCandidate: "Approve agent"
        }
    }

    private var executionSummary: String {
        switch curated.feasibility {
        case .needsDemo:
            return "Needs one taught example before it can run."
        case .linkedRecipe:
            return "Runs from context with linked recipe evidence."
        case .goalOnlyCandidate:
            return CascadeAppModel.runsInBackground(apps: waste.apps)
                ? "Runs from the recorded context in the background."
                : "Runs from the recorded context on screen."
        }
    }
}

private struct ProactiveNextActionCard: View {
    let offer: ProactiveOffer
    let onAccept: () -> Void
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CascadePanel {
            HStack(alignment: .top, spacing: CascadeMetrics.s3) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.cascadeAgent)
                    .frame(width: 34, height: 34)
                    .background(Color.cascadeAgent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(offer.title).font(.cascadeSans(15, .semibold))
                        CascadeTag(levelText, tone: .cascadeAgent)
                        Spacer()
                    }
                    Text(offer.detail)
                        .font(.cascadeSans(13))
                        .foregroundStyle(Color.cascadeText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(evidenceText)
                        .font(.cascadeSans(12))
                        .foregroundStyle(Color.cascadeText3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: CascadeMetrics.s2) {
                        Spacer()
                        if offer.level == .action, let actionTitle = offer.actionTitle {
                            Button(action: onAccept) {
                                Label(actionTitle, systemImage: "bolt.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.cascadeAgent)
                        }
                        Button(action: onSnooze) {
                            Label("Later", systemImage: "clock")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.cascadeText3)
                        Button(action: onDismiss) {
                            Label("Not this", systemImage: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.cascadeText3)
                    }
                }
            }
        }
    }

    private var levelText: String {
        switch offer.level {
        case .auditOnly: "AUDIT"
        case .ambient: "AMBIENT"
        case .passive: "PROACTIVE"
        case .action: "ACTION"
        }
    }

    private var evidenceText: String {
        let confidence = "\(Int((offer.confidence * 100).rounded()))%"
        let evidence = offer.evidence.prefix(3).joined(separator: " · ")
        return evidence.isEmpty ? "\(confidence) confidence." : "\(confidence) confidence · \(evidence)"
    }
}

private struct AgentCard: View {
    let agent: CascadeAgent
    var flash: Bool = false
    let onDeploy: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    var onSchedule: ((String?) -> Void)?

    /// Daily slots offered in the schedule menu. Background agents run for
    /// real on schedule; on-screen agents get a reminder (never auto-run).
    private static let scheduleSlots = ["09:05", "13:05", "17:05"]

    private var runsInBackground: Bool {
        CascadeAppModel.runsInBackground(apps: agent.apps)
    }

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(spacing: CascadeMetrics.s2) {
                    Circle().fill(AppVisuals.color(for: agent.apps.first ?? agent.name)).frame(width: 8, height: 8)
                    Text(agent.name).font(.cascadeSans(15, .semibold)).lineLimit(1)
                    CascadeTag(runsInBackground ? "BACKGROUND" : "ON SCREEN", tone: runsInBackground ? .cascadeAgent : .cascadeAccentWarm)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { agent.enabled },
                        set: { enabled in onToggle(enabled) }
                    ))
                        .labelsHidden().toggleStyle(.switch)
                }
                if !agent.apps.isEmpty { AppChips(apps: agent.apps) }
                stepsPreview
                HStack {
                    Text(meta).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
                    Spacer()
                    scheduleMenu
                    Button("Delete", action: onDelete)
                        .buttonStyle(.plain).foregroundStyle(Color.cascadeText3)
                    Button(runsInBackground ? "Deploy in background  →" : "Deploy  →", action: onDeploy)
                        .buttonStyle(CascadeAccentButtonStyle())
                        .disabled(!agent.enabled)
                }
            }
        }
        // The just-approved glow: when an approve lands the agent here, this
        // ring + the auto-scroll make "where did it go" impossible to ask.
        .overlay(
            RoundedRectangle(cornerRadius: CascadeMetrics.radiusPanel, style: .continuous)
                .stroke(Color.cascadeAgent, lineWidth: flash ? 2 : 0)
                .shadow(color: Color.cascadeAgent.opacity(flash ? 0.45 : 0), radius: 10)
        )
        .animation(.easeOut(duration: 0.5), value: flash)
    }

    /// Daily schedule picker. Background agents fire for real at the slot;
    /// on-screen agents get a "ready to deploy" reminder instead.
    @ViewBuilder private var scheduleMenu: some View {
        if let onSchedule {
            Menu {
                Button("Manual only") { onSchedule(nil) }
                ForEach(Self.scheduleSlots, id: \.self) { slot in
                    Button(runsInBackground ? "Run daily at \(slot)" : "Remind daily at \(slot)") {
                        onSchedule("daily@\(slot)")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: agent.schedule == nil ? "clock" : "clock.badge.checkmark")
                        .font(.system(size: 11))
                    if let schedule = agent.schedule?.split(separator: "@").last {
                        Text(String(schedule)).font(.cascadeMono(11))
                    }
                }
                .foregroundStyle(agent.schedule == nil ? Color.cascadeText3 : Color.cascadeAgent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(agent.schedule == nil ? "Schedule this agent" : "Scheduled \(agent.schedule ?? "")")
        }
    }

    /// What this agent does, in plain language — the curator's intent, not the
    /// recorded keystrokes (those stay internal, guiding the deployed agent).
    private var stepsPreview: some View {
        let goal = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 5) {
            Text("WHAT IT DOES")
                .font(.cascadeMono(9, .semibold)).tracking(0.7).foregroundStyle(Color.cascadeText4)
            Text(goal.isEmpty ? "Runs your recorded “\(agent.name)” workflow in the background." : goal)
                .font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meta: String {
        var summary = agent.runCount == 1 ? "1 run" : "\(agent.runCount) runs"
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

enum ContextWasteEvidenceImagePicker {
    static func safeImagePath(
        for waste: ContextWasteCandidate,
        contexts: [RecordedContext]
    ) -> String? {
        let evidenceIDs = Set(waste.evidenceContextIDs)
        return contexts
            .filter {
                evidenceIDs.contains($0.id)
                    && $0.imagePath != nil
                    && $0.safeToShow
                    && $0.safeToSummarize
                    && !PrivacyRules.isSensitive($0)
            }
            .min { abs($0.capturedAt.timeIntervalSince(waste.lastSeenAt)) < abs($1.capturedAt.timeIntervalSince(waste.lastSeenAt)) }?
            .imagePath
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

    /// Minutes still sitting on the table: the curated workflows awaiting review (the
    /// same actionable set the Cascades tab surfaces — NOT the raw detector list, which
    /// includes repetition the curator judged not worth automating) plus approved
    /// agents that have never actually been deployed.
    private var minutesOnTheTable: Int {
        let pending = model.pendingCuratedAgents.map(\.source.estimatedTotalSeconds).reduce(0, +)
        let pendingContext = model.pendingCuratedContextWaste.map(\.source.estimatedTotalSeconds).reduce(0, +)
        let approvedNeverRun = model.agents.filter { $0.runCount == 0 }.map(\.estimatedSeconds).reduce(0, +)
        return (pending + pendingContext + approvedNeverRun) / 60
    }

    private var totalRuns: Int {
        model.agents.map(\.runCount).reduce(0, +)
    }

    private var costPerRunText: String {
        String(format: "$%.2f", model.valueSummary.costPerCompletedRunUSD)
    }

    private var sloText: String {
        let rate = Int(((model.sloSnapshot?.successRate ?? 1.0) * 100).rounded())
        return "\(rate)%"
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CascadeMetrics.s6) {
                VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                    CascadeTag("Manager", tone: .cascadeAgent)
                    Text("Review what's worth automating").font(.cascadeSerif(30))
                    Text("Cascade surfaces the genuinely repeated, time-saving workflows here. Approve one and it lands in the employee's Cascades as a ready agent. Aggregate-only signals — never raw OCR, screenshots, or keystrokes.")
                        .font(.cascadeSans(14)).foregroundStyle(Color.cascadeText2)
                }
                HStack(spacing: CascadeMetrics.s3) {
                    MetricCard(value: "~\(minutesReclaimed)m", label: "Reclaimed (\(totalRuns) runs)")
                    MetricCard(value: "~\(minutesOnTheTable)m", label: "On the table")
                    MetricCard(value: "\(appsObserved)", label: "Apps observed")
                    MetricCard(value: "\(model.agents.count)", label: "Agents approved")
                    MetricCard(value: costPerRunText, label: "Cost / run")
                    MetricCard(value: sloText, label: "SLO pass rate")
                    MetricCard(value: "0", label: "Raw screenshots")
                }
	                learningOpportunitiesSection
	                reviewQueueSection
	                whereTimeGoesSection
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CascadeMetrics.s6)
            .padding(.vertical, CascadeMetrics.s6)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
	    }

    private var learningOpportunitiesSection: some View {
        VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
            if !model.learningOpportunities.isEmpty {
                SectionLabel(title: "LEARNING CURRICULUM", trailing: "\(model.learningOpportunities.count) suggested")
                ForEach(model.learningOpportunities) { opportunity in
                    CascadePanel {
                        HStack(alignment: .top, spacing: CascadeMetrics.s3) {
                            Image(systemName: learningOpportunityIcon(opportunity.kind))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.cascadeAgent)
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(opportunity.title)
                                    .font(.cascadeSans(13, .semibold))
                                    .foregroundStyle(Color.cascadeText)
                                Text(opportunity.detail)
                                    .font(.cascadeSans(12))
                                    .foregroundStyle(Color.cascadeText3)
                            }
                            Spacer(minLength: CascadeMetrics.s2)
                            Button(opportunity.actionTitle) { model.focusLearningOpportunity(opportunity) }
                                .buttonStyle(CascadeQuietButtonStyle())
                            Button("Dismiss") { model.dismissLearningOpportunity(opportunity) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.cascadeText3)
                        }
                    }
                }
            }
        }
    }

    private func learningOpportunityIcon(_ kind: CascadeAppModel.LearningOpportunity.Kind) -> String {
        switch kind {
        case .repeatedWorkflow: "repeat"
        case .contextWaste: "text.viewfinder"
        case .overlappingDrafts: "square.stack.3d.up"
        case .recurringFailure: "wrench.and.screwdriver"
        case .parameterizedRecipe: "tag"
        }
    }

		    /// The manager's review queue: the genuinely repeated, time-saving workflows
	    /// Cascade caught, each judged and named by the curator. Approve to land a ready
	    /// agent in the employee's Cascades; dismiss to never see it again.
	    private var reviewQueueSection: some View {
		        let hasProactiveOffer = model.proactiveOffer != nil
		        let pendingCount = model.pendingCuratedAgents.count + model.pendingCuratedContextWaste.count + (hasProactiveOffer ? 1 : 0)
		        return VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
	            SectionLabel(title: "REVIEW — WORKFLOWS WORTH AUTOMATING", trailing: "\(pendingCount) pending")
            if let note = model.managerReviewNote {
                HStack(spacing: CascadeMetrics.s2) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.cascadeAgent)
                    Text(note).font(.cascadeSans(12, .medium)).foregroundStyle(Color.cascadeText2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, CascadeMetrics.s3).padding(.vertical, CascadeMetrics.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cascadeAgent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
	            if let offer = model.proactiveOffer {
	                ProactiveNextActionCard(
	                    offer: offer,
	                    onAccept: { model.acceptProactiveOffer() },
	                    onSnooze: { model.snoozeProactiveOffer() },
	                    onDismiss: { model.dismissProactiveNextActionOffer() }
	                )
	            }
	            if model.pendingCuratedAgents.isEmpty && model.pendingCuratedContextWaste.isEmpty && !hasProactiveOffer {
	                CascadePanel { EmptyState(title: "Nothing to review right now", detail: "When the employee repeats real work in the recorded context, Cascade judges whether it's worth automating and surfaces the worthwhile processes here.") }
	            } else {
	                ForEach(model.pendingCuratedAgents) { curated in
	                    WasteCard(
                        curated: curated,
                        evidenceImagePath: evidenceImagePath(for: curated.source),
                        onApprove: { model.approveCurated(curated) },
	                        onDecline: { model.declineCurated(curated) }
	                    )
	                }
                    ForEach(model.pendingCuratedContextWaste) { curated in
                        ContextWasteCard(
                            curated: curated,
                            evidenceImagePath: evidenceImagePath(for: curated.source),
                            onApprove: { model.approveContextWaste(curated) },
                            onDecline: { model.declineContextWaste(curated) }
                        )
                    }
	            }
	        }
        .animation(.easeInOut(duration: 0.25), value: model.managerReviewNote)
    }

    /// The rewind frame nearest to when the workflow was last observed, from the
    /// same app — real visual evidence for the card.
    private func evidenceImagePath(for waste: DetectedWaste) -> String? {
        model.contexts
            .filter { $0.imagePath != nil && (waste.apps.contains($0.appName) || waste.apps.isEmpty) }
            .min { abs($0.capturedAt.timeIntervalSince(waste.lastSeenAt)) < abs($1.capturedAt.timeIntervalSince(waste.lastSeenAt)) }?
            .imagePath
    }

    private func evidenceImagePath(for waste: ContextWasteCandidate) -> String? {
        ContextWasteEvidenceImagePicker.safeImagePath(for: waste, contexts: model.contexts)
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

/// One number in the Cascades pipeline strip: review → agents → runs.
private struct PipelineStat: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: CascadeMetrics.s2) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cascadeAgent)
            Text(value).font(.cascadeSerif(22))
            Text(label).font(.cascadeMono(10, .semibold)).tracking(0.6).foregroundStyle(Color.cascadeText3)
        }
        .padding(.horizontal, CascadeMetrics.s4)
        .padding(.vertical, CascadeMetrics.s2 + 2)
        .background(Color.cascadePanel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }
}

/// Proof chips under an answer: the recorded moments it was grounded in.
/// Click one and the Reel jumps to that exact moment — the answer is checkable,
/// not just plausible.
private struct CitationChips: View {
    let citations: [CitedMoment]
    let onTap: (CitedMoment) -> Void

    var body: some View {
        HStack(spacing: CascadeMetrics.s2) {
            ForEach(citations) { citation in
                Button { onTap(citation) } label: {
                    HStack(spacing: 5) {
                        thumbnail(citation)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(citation.appName).font(.cascadeSans(10, .semibold)).lineLimit(1)
                            Text(citation.capturedAt.formatted(date: .omitted, time: .shortened))
                                .font(.cascadeMono(9)).foregroundStyle(Color.cascadeText3)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Jump the Reel to this moment")
            }
        }
    }

    @ViewBuilder private func thumbnail(_ citation: CitedMoment) -> some View {
        if let path = citation.imagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(Color.cascadeText3)
                .frame(width: 18, height: 18)
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

private struct AgentActivityRow: View {
    let event: AuditEvent

    var body: some View {
        let item = AgentActivityItem(event: event)
        HStack(spacing: CascadeMetrics.s3) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CascadeMetrics.s2) {
                    Text(item.title.uppercased())
                        .font(.cascadeMono(10, .semibold))
                        .foregroundStyle(Color.cascadeText3)
                    if let status = item.status {
                        Text(status.uppercased())
                            .font(.cascadeMono(9, .semibold))
                            .foregroundStyle(item.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(item.detail)
                    .font(.cascadeSans(13))
                    .foregroundStyle(Color.cascadeText)
                    .lineLimit(1)
            }
            Spacer()
            Text(event.createdAt, style: .time).font(.cascadeMono(11)).foregroundStyle(Color.cascadeText3)
        }
        .padding(.horizontal, CascadeMetrics.s4)
        .padding(.vertical, CascadeMetrics.s3)
        .background(Color.cascadePanel, in: RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
    }
}

private struct AgentActivityItem {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let status: String?

    init(event: AuditEvent) {
        let action = event.action
        let status = Self.value("status", in: event.detail) ?? Self.value("outcome", in: event.detail) ?? Self.value("verdict", in: event.detail)
        self.status = status
        switch action {
        case "assist.timing", "sandbox.turn":
            title = "Model turn"
            detail = Self.modelDetail(action: action, detail: event.detail)
            icon = "brain.head.profile"
            tint = Color.cascadeAgent
        case "assist.capture":
            title = "Budget"
            detail = Self.counts(event.detail, keys: ["imageTurns", "prunedImages", "inputTokens", "outputTokens"])
            icon = "camera.metering.matrix"
            tint = Color.cascadeAccent
        case "agent.ground", "grounding.verifier":
            title = "Grounding"
            detail = Self.groundingDetail(event.detail)
            icon = "scope"
            tint = Color.cascadeAccent
        case "agent.ground.miss":
            title = "Grounding miss"
            detail = Self.counts(event.detail, keys: ["turn", "controlCount", "missedTargetHash", "labelsHash"])
            icon = "scope.badge.questionmark"
            tint = Color.cascadeRecText
        case "scout.ocr.marks":
            title = "OCR marks"
            detail = Self.counts(event.detail, keys: ["turn", "controlCount", "ocrLineCount", "ocrMarksHash"])
            icon = "text.viewfinder"
            tint = Color.cascadeAccentWarm
        case "assist.verify.action", "assist.verify.unavailable", "assist.validate", "sandbox.verify":
            title = "Verifier"
            detail = Self.verifierDetail(event.detail)
            icon = "checkmark.seal"
            tint = status == "failed" || status == "incomplete" ? Color.cascadeRecText : Color.cascadeAccent
        case "assist.noeffect", "assist.stalled", "sandbox.noeffect", "sandbox.stalled":
            title = action.contains("noeffect") ? "No effect" : "Stall guard"
            detail = Self.counts(event.detail, keys: ["turn", "noEffectStreak", "controlCount", "textHash"])
            icon = "exclamationmark.triangle"
            tint = Color.cascadeRecText
        case "agent.action.refused", "sandbox.stopped":
            title = action == "sandbox.stopped" ? "Stopped" : "Refusal"
            detail = Self.safeSummary(for: action, detail: event.detail)
            icon = "hand.raised"
            tint = Color.cascadeRecText
        case "agent.trajectory_sketch":
            title = "Replay sketch"
            detail = Self.counts(event.detail, keys: ["score", "sketchHash", "actionCount", "checkCount"])
            icon = "point.topleft.down.curvedto.point.bottomright.up"
            tint = Color.cascadeAgent
        case "agent.failure_memory.used", "agent.failure_memory.saved":
            title = action.hasSuffix(".used") ? "Failure memory" : "Saved reflection"
            detail = Self.counts(event.detail, keys: ["count", "ids", "failureKinds", "memoryHash", "targetHash"])
            icon = "arrow.counterclockwise.circle"
            tint = Color.cascadeAccentWarm
        case "agent.run.completed", "sandbox.done", "sandbox.task":
            title = "Completion"
            detail = Self.safeSummary(for: action, detail: event.detail)
            icon = "checkmark.circle"
            tint = Color.cascadeAccent
        case "computer.act", "computer.zoom", "sandbox.act":
            title = action == "computer.zoom" ? "Zoom" : "Tool action"
            detail = Self.actionDetail(event.detail)
            icon = "cursorarrow.click"
            tint = Color.cascadeAgent
        default:
            if action.hasPrefix("harness.") || action == "sandbox.harness" {
                title = "Harness"
                detail = Self.safeSummary(for: action, detail: event.detail)
                icon = "terminal"
                tint = Color.cascadeAccent
            } else if action.hasPrefix("step.") || action == "recipe.step" {
                title = "Step"
                detail = Self.safeSummary(for: action, detail: event.detail)
                icon = "list.bullet.rectangle"
                tint = Color.cascadeAgent
            } else {
                title = action.replacingOccurrences(of: ".", with: " ")
                detail = Self.safeSummary(for: action, detail: event.detail)
                icon = "circle.grid.cross"
                tint = Color.cascadeText3
            }
        }
    }

    private static func modelDetail(action: String, detail: String) -> String {
        if action == "assist.timing" {
            return counts(detail, keys: ["total", "model", "actions", "turns", "effort"])
        }
        return safeSummary(for: action, detail: detail)
    }

    private static func groundingDetail(_ detail: String) -> String {
        let fields = ["source", "confidence", "failure", "candidates", "groundHash", "targetHash"]
        return counts(detail, keys: fields)
    }

    private static func verifierDetail(_ detail: String) -> String {
        counts(detail, keys: ["status", "actionKind", "failureKind", "verdict", "outcome", "confidence", "targetHash"])
    }

    private static func actionDetail(_ detail: String) -> String {
        counts(detail, keys: ["status", "actionKind", "kind", "coordinateValid", "failureKind", "surface", "region"])
    }

    private static func safeSummary(for action: String, detail: String) -> String {
        let keyed = counts(detail, keys: ["status", "outcome", "failureKind", "agentID", "tool", "actionKind", "textHash", "taskHash", "labelHash"])
        if keyed != "event recorded" { return keyed }
        return action.replacingOccurrences(of: ".", with: " ") + " recorded"
    }

    private static func counts(_ detail: String, keys: [String]) -> String {
        let parts = keys.compactMap { key -> String? in
            guard let value = value(key, in: detail) else { return nil }
            return "\(key)=\(safeToken(value))"
        }
        return parts.isEmpty ? "event recorded" : parts.joined(separator: " · ")
    }

    private static func value(_ key: String, in detail: String) -> String? {
        let prefix = "\(key)="
        return detail
            .split(separator: " ")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func safeToken(_ value: String) -> String {
        let safe = value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" || character == ","
        }
        return safe.isEmpty ? "redacted" : String(safe.prefix(36))
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
                section("CAPTURE POLICY", trailing: "privacy controls") {
                    PrivacyPolicyCard(model: model)
                }
                section("PRIVACY OUTBOX", trailing: "employee data rights") {
                    PrivacyOutboxCard(model: model)
                }
                section("PERSONALIZATION", trailing: "local priors") {
                    PersonalizationCard(model: model)
                }
                section("AUDIT EXPORT", trailing: "SIEM and release gates") {
                    AuditExportCard(model: model)
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
                    GroqKeyCard(model: model)
                    OpenRouterKeyCard(model: model)
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

private struct PrivacyPolicyCard: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Private mode").font(.cascadeSans(15, .semibold))
                        Text(model.capturePrivacyPolicy.privateModeEnabled ? "Capture is paused." : "Capture follows the local policy.")
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.capturePrivacyPolicy.privateModeEnabled },
                        set: { model.setCapturePrivateMode($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().overlay(Color.cascadeBorder)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Managed controls").font(.cascadeSans(15, .semibold))
                    Text(managedControls)
                        .font(.cascadeSans(12))
                        .foregroundStyle(Color.cascadeText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Color.cascadeBorder)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Managed JSON").font(.cascadeSans(15, .semibold))
                        Text("\(model.capturePrivacyPolicy.deniedBundleIdentifiers.count) bundle rules · \(model.capturePrivacyPolicy.deniedWindowTitleKeywords.count) title rules · \(model.capturePrivacyPolicy.deniedURLHosts.count) site rules")
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    Button("Import") { model.importCapturePolicyFromPasteboard() }
                        .buttonStyle(CascadeQuietButtonStyle())
                    Button("Export") { model.exportCapturePolicyToPasteboard() }
                        .buttonStyle(CascadeQuietButtonStyle())
                }
            }
        }
    }

    private var managedControls: String {
        let policy = model.capturePrivacyPolicy
        let controls = [
            ("Recording", policy.recordingAvailable),
            ("Background", policy.backgroundWebRunsAvailable),
            ("Schedules", policy.scheduledRunsAvailable),
            ("Power harness", policy.powerHarnessAvailable),
            ("Record recall", policy.recordRecallAvailable),
            ("Audit export", policy.agentAuditExportAvailable),
            ("Diagnostic export", policy.diagnosticBundleExportAvailable),
            ("Irreversible guard", policy.forceIrreversibleActionGuard),
        ]
        return controls.map { "\($0.0): \($0.1 ? "on" : "blocked")" }.joined(separator: " · ")
    }
}

private struct PrivacyOutboxCard: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Captured summary").font(.cascadeSans(15, .semibold))
                        Text(summaryLine)
                            .font(.cascadeSans(12))
                            .foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    Button("Export manifest") { model.exportPrivacyManifestToPasteboard() }
                        .buttonStyle(CascadeQuietButtonStyle())
                    Button("Delete all") { model.deletePrivacyData() }
                        .buttonStyle(CascadeQuietButtonStyle())
                }
                if let summary = model.privacySummary, !summary.buckets.isEmpty {
                    Divider().overlay(Color.cascadeBorder)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.buckets.prefix(3).enumerated()), id: \.offset) { _, bucket in
                            HStack {
                                Text(bucket.appName)
                                    .font(.cascadeSans(12, .medium))
                                    .foregroundStyle(Color.cascadeText)
                                Spacer()
                                Text("\(bucket.count) moments")
                                    .font(.cascadeMono(11))
                                    .foregroundStyle(Color.cascadeText3)
                            }
                        }
                    }
                }
                HStack(spacing: CascadeMetrics.s2) {
                    CascadeTag(model.capturePrivacyPolicy.privateModeEnabled ? "Private mode on" : "Private mode off", tone: model.capturePrivacyPolicy.privateModeEnabled ? .cascadeWarn : .cascadeGood)
                    Text("Exports omit OCR, image paths, metadata JSON, and input text.")
                        .font(.cascadeSans(11))
                        .foregroundStyle(Color.cascadeText3)
                }
            }
        }
    }

    private var summaryLine: String {
        guard let summary = model.privacySummary else { return "No captured summary loaded yet." }
        let megabytes = Double(summary.estimatedFrameBytes) / 1_000_000.0
        let start = summary.firstCapturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "none"
        let end = summary.lastCapturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "none"
        return "\(summary.totalContexts) moments · \(String(format: "%.1f", megabytes)) MB frames · \(start) to \(end)"
    }
}

private struct AuditExportCard: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent audit export").font(.cascadeSans(15, .semibold))
                        Text(auditLine)
                            .font(.cascadeSans(12))
                            .foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    Button("Copy SLO") { model.copySLOSnapshotToPasteboard() }
                        .buttonStyle(CascadeQuietButtonStyle())
                }
                Divider().overlay(Color.cascadeBorder)
                TraceExportSheet(model: model)
                Divider().overlay(Color.cascadeBorder)
                HStack(spacing: CascadeMetrics.s3) {
                    MetricPill(title: "Runs", value: "\(model.sloSnapshot?.totalRuns ?? 0)")
                    MetricPill(title: "SLO", value: model.sloSnapshot?.passesReleaseGate == false ? "Fail" : "Pass")
                    MetricPill(title: "Cost/run", value: String(format: "$%.2f", model.valueSummary.costPerCompletedRunUSD))
                }
            }
        }
    }

    private var auditLine: String {
        switch model.auditIntegrityStatus {
        case .trusted:
            return "Trusted audit chain. Export uses safe trace attributes and a manifest."
        case .untrusted:
            return "Audit chain is untrusted. Enforcement blocks export when enabled."
        case .verificationFailed(let reason):
            return "Audit verification failed: \(reason)"
        case .unchecked:
            return "Audit chain has not been checked yet."
        }
    }
}

private struct PersonalizationCard: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local preference model").font(.cascadeSans(15, .semibold))
                        Text(summaryLine)
                            .font(.cascadeSans(12))
                            .foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.personalizationEnabled },
                        set: { model.personalizationEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().overlay(Color.cascadeBorder)
                VStack(alignment: .leading, spacing: CascadeMetrics.s2) {
                    Picker("Suggestion timing", selection: $model.suggestionTimingPreference) {
                        Text("Early").tag(CascadeAppModel.SuggestionTimingPreference.early)
                        Text("Balanced").tag(CascadeAppModel.SuggestionTimingPreference.balanced)
                        Text("Strong evidence").tag(CascadeAppModel.SuggestionTimingPreference.strongEvidence)
                    }
                    .pickerStyle(.segmented)
                    Picker("Background agents", selection: $model.backgroundAgentPreference) {
                        Text("Prefer").tag(CascadeAppModel.BackgroundAgentPreference.prefer)
                        Text("Ask first").tag(CascadeAppModel.BackgroundAgentPreference.askFirst)
                        Text("Avoid").tag(CascadeAppModel.BackgroundAgentPreference.avoid)
                    }
                    .pickerStyle(.segmented)
                }
                Divider().overlay(Color.cascadeBorder)
                HStack(spacing: CascadeMetrics.s3) {
                    MetricPill(title: "Events", value: "\(model.personalizationSnapshot.eventCount)")
                    MetricPill(title: "Routines", value: "\(model.personalizationSnapshot.routineProfileCount)")
                    MetricPill(title: "Disabled", value: "\(model.personalizationSnapshot.disabledSignatureCount + model.personalizationSnapshot.disabledAppCount)")
                    Spacer()
                    Button("Clear all") { model.clearAllPersonalization() }
                        .buttonStyle(CascadeQuietButtonStyle())
                }
            }
        }
    }

    private var summaryLine: String {
        let last = model.personalizationSnapshot.lastEventAt?.formatted(date: .abbreviated, time: .shortened) ?? "none"
        return "Events and routine counters are stored locally. Last update: \(last)."
    }
}

private struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.cascadeSans(15, .semibold))
            Text(title).font(.cascadeMono(9, .semibold)).foregroundStyle(Color.cascadeText4)
        }
        .padding(.horizontal, CascadeMetrics.s3)
        .padding(.vertical, CascadeMetrics.s2)
        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        Text("run_command · run_applescript · write_file — the agent can run allowlisted argv-safe commands and drive scriptable apps (bulk-edit a spreadsheet in one script instead of hundreds of clicks). Commands and scripts are shown live for supervision; audit rows store safe descriptors, hashes, and byte counts. Shell syntax, destructive commands, and protected paths are refused, and Esc stops it mid-run.")
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
                Divider().overlay(Color.cascadeBorder)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On-screen engine").font(.cascadeSans(15, .semibold))
                        Text("Which model drives the on-screen agent. Claude is the proven Opus computer-use loop; Scout runs the cheap Llama 4 Scout planner on Groq, with the grounder below doing the clicks.")
                            .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText2)
                        if model.onScreenBackend == "scout" && !model.hasGroqKey {
                            Text("Add a Groq key above to use Scout.").font(.cascadeSans(11)).foregroundStyle(Color.cascadeWarn)
                        }
                    }
                    Spacer()
                    Picker("", selection: $model.onScreenBackend) {
                        Text("Claude").tag("claude")
                        Text("Scout").tag("scout")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 150)
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
                    keys: ["⌃", "⌥", "T"],
                    name: "Teach a task",
                    detail: "Press to start, do the task by hand (narrate if you like), press again to finish — Cascade turns the recording into an agent."
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
                Text("Stored in macOS Keychain. Used only for Claude-backed Q&A and reviewed agents.")
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

private struct GroqKeyCard: View {
    @ObservedObject var model: CascadeAppModel
    @State private var key = ""

    var body: some View {
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Groq key · cheaper models").font(.cascadeSans(16, .semibold))
                        Text(model.groqKeyMessage).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    CascadeTag(model.hasGroqKey ? "Connected" : "Groq off", tone: model.hasGroqKey ? .cascadeGood : .cascadeWarn)
                }
                SecureField("gsk_…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.cascadeMono(12))
                    .padding(.horizontal, CascadeMetrics.s3)
                    .padding(.vertical, CascadeMetrics.s2 + 1)
                    .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                HStack {
                    Button("Save key") { model.saveGroqKey(key); key = "" }.buttonStyle(CascadeAccentButtonStyle())
                    Button("Clear") { model.clearGroqKey(); key = "" }.buttonStyle(CascadeQuietButtonStyle())
                }
                Text("Stored in macOS Keychain. Runs the downgraded models: the task planner and completion validators on Llama 3.3 70B, and the on-screen agent on Llama 4 Scout (with UI-TARS grounding). Falls back to Claude when absent.")
                    .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            }
        }
    }
}

private struct OpenRouterKeyCard: View {
    @ObservedObject var model: CascadeAppModel
    @State private var key = ""
    @State private var endpoint = ""

    var body: some View {
        let runtime = model.visualGrounderRuntime
        CascadePanel {
            VStack(alignment: .leading, spacing: CascadeMetrics.s3) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Visual grounder runtime").font(.cascadeSans(16, .semibold))
                        Text(model.openRouterKeyMessage).font(.cascadeSans(13)).foregroundStyle(Color.cascadeText2)
                    }
                    Spacer()
                    CascadeTag(model.hasOpenRouterKey ? "Connected" : "Grounder off", tone: model.hasOpenRouterKey ? .cascadeGood : .cascadeWarn)
                }
                HStack(spacing: CascadeMetrics.s2) {
                    runtimePill("Backend", runtime.preset.endpointClass.rawValue)
                    runtimePill("Model", runtime.preset.modelSize)
                    runtimePill("Coord", runtime.coordSpace.rawValue)
                    runtimePill("Probe", runtime.probeStatus)
                }
                Picker("Preset", selection: Binding(
                    get: { model.visualGrounderRuntime.preset.id },
                    set: { model.selectVisualGrounderPreset($0); endpoint = model.visualGrounderRuntime.endpoint }
                )) {
                    ForEach(GrounderRegistry.presets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                HStack(spacing: CascadeMetrics.s2) {
                    TextField(runtime.endpoint, text: $endpoint)
                        .textFieldStyle(.plain)
                        .font(.cascadeMono(12))
                        .padding(.horizontal, CascadeMetrics.s3)
                        .padding(.vertical, CascadeMetrics.s2 + 1)
                        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                    Picker("Coord", selection: Binding(
                        get: { model.visualGrounderRuntime.coordSpace.rawValue },
                        set: { model.updateVisualGrounderCoordSpace($0) }
                    )) {
                        ForEach(UITARSGrounder.CoordSpace.allCases, id: \.rawValue) { space in
                            Text(space.rawValue).tag(space.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Button("Save runtime") {
                        model.updateVisualGrounderEndpoint(endpoint.isEmpty ? runtime.endpoint : endpoint)
                    }.buttonStyle(CascadeQuietButtonStyle())
                    Button("Run coord probe") { model.runVisualGrounderCoordinateProbe() }
                        .buttonStyle(CascadeQuietButtonStyle())
                    Spacer()
                    runtimePill("License", runtime.preset.license.rawValue)
                    runtimePill("Eval", runtime.lastMiniEvalScore.map { String(format: "%.0f%%", $0 * 100) } ?? "none")
                }
                Text(runtime.preset.note)
                    .font(.cascadeSans(12))
                    .foregroundStyle(Color.cascadeText3)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(Color.cascadeBorder)
                SecureField("sk-or-…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.cascadeMono(12))
                    .padding(.horizontal, CascadeMetrics.s3)
                    .padding(.vertical, CascadeMetrics.s2 + 1)
                    .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
                HStack {
                    Button("Save key") { model.saveOpenRouterKey(key); key = "" }.buttonStyle(CascadeAccentButtonStyle())
                    Button("Clear") { model.clearOpenRouterKey(); key = "" }.buttonStyle(CascadeQuietButtonStyle())
                }
                Text("OpenRouter keys stay in macOS Keychain. Local and BYO presets require their own endpoint; no model weights are bundled.")
                    .font(.cascadeSans(12)).foregroundStyle(Color.cascadeText3)
            }
            .onAppear { endpoint = model.visualGrounderRuntime.endpoint }
        }
    }

    private func runtimePill(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.cascadeMono(8, .semibold))
                .foregroundStyle(Color.cascadeText4)
            Text(value)
                .font(.cascadeMono(10))
                .foregroundStyle(Color.cascadeText2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, CascadeMetrics.s2)
        .padding(.vertical, 5)
        .background(Color.cascadePanel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.cascadeBorder, lineWidth: 1))
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
