//
//  CascadeDesignSystem.swift
//  Cascade — design foundation translated from the HTML/CSS (OKLCH) prototype.
//
//  Tokens are the exact sRGB conversions of the prototype's OKLCH values (see
//  docs / palette-check.html). Colors are adaptive: dark values in .dark, light
//  values in .light — the native equivalent of the CSS `[data-theme]` swap.
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - Hex + adaptive helpers

private extension Color {
    init(hex: String, alpha: Double = 1) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// A single Color that resolves to `dark` in dark mode and `light` in light mode.
private func adaptive(dark: String, light: String) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(Color(hex: isDark ? dark : light))
    })
    #else
    return Color(hex: dark)
    #endif
}

// MARK: - Color tokens

public extension Color {
    // Surfaces
    static let cascadeBG = adaptive(dark: "#0A0D0A", light: "#FBFAF6")
    static let cascadePanel = adaptive(dark: "#141713", light: "#FFFFFF")
    static let cascadePanel2 = adaptive(dark: "#1D211C", light: "#F8F7F2")
    static let cascadePanel3 = adaptive(dark: "#262A25", light: "#F0EEE9")
    static let cascadeBorder = adaptive(dark: "#2D322C", light: "#E5E4DE")
    static let cascadeBorderHi = adaptive(dark: "#454B44", light: "#C8C6BD")

    // Text ramp
    static let cascadeText = adaptive(dark: "#F4F4EF", light: "#191C16")
    static let cascadeText2 = adaptive(dark: "#B1B0A9", light: "#565953")
    static let cascadeText3 = adaptive(dark: "#75756D", light: "#868780")
    static let cascadeText4 = adaptive(dark: "#494A42", light: "#B2B1AC")

    // Sage / terracotta accent
    static let cascadeAccent = adaptive(dark: "#E9A679", light: "#B66028")
    static let cascadeAccent2 = adaptive(dark: "#BE6438", light: "#9C3A11")
    static let cascadeAccentWarm = adaptive(dark: "#F19F91", light: "#B65C4E")
    static let cascadeOnAccent = adaptive(dark: "#220A00", light: "#FEFBF8")

    // Recording pill
    static let cascadeRecText = adaptive(dark: "#FDB7A5", light: "#B14F42")
    static let cascadeRecDot = adaptive(dark: "#F17260", light: "#D64938")

    // Status (on-brand additions: sage-green positive, terracotta caution)
    static let cascadeGood = adaptive(dark: "#8FBF7A", light: "#5C8A3E")
    static let cascadeWarn = adaptive(dark: "#E9A679", light: "#B66028")

    // Agent / automation accent — the "intentional blue" that marks agent surfaces
    // (compose, cascaded helpers, live agent activity), distinct from the warm
    // terracotta of the human record.
    static let cascadeAgent = adaptive(dark: "#5BC8EA", light: "#1C84C6")
    static let cascadeAgentDeep = adaptive(dark: "#3FA9D8", light: "#0E6CA8")
}

// MARK: - Typography
//
// The prototype uses Inter Tight (UI), Instrument Serif (display), JetBrains Mono.
// Until those .ttf/.otf are bundled (add them to the target + Info.plist), these
// resolve to the closest native faces — SF Pro / New York / SF Mono — so the right
// type *category* always renders. Bundle the fonts and swap to `.custom(...)` to
// pixel-match.

public extension Font {
    static func cascadeSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func cascadeSerif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif)
    }

    static func cascadeMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Spacing, radii, shadow

public enum CascadeMetrics {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s8: CGFloat = 32

    public static let radiusCard: CGFloat = 14
    public static let radiusPanel: CGFloat = 18
    public static let radiusWindow: CGFloat = 16
    public static let radiusPill: CGFloat = 999
}

public extension View {
    func cascadeWindowShadow() -> some View {
        shadow(color: .black.opacity(0.55), radius: 40, x: 0, y: 32)
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
    }
}

// MARK: - Panel card

public struct CascadePanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = CascadeMetrics.s5, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(Color.cascadePanel)
            .clipShape(RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CascadeMetrics.radiusCard, style: .continuous)
                    .stroke(Color.cascadeBorder, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

public struct CascadeAccentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cascadeSans(13, .semibold))
            .foregroundStyle(Color.cascadeOnAccent)
            .padding(.horizontal, CascadeMetrics.s4)
            .padding(.vertical, CascadeMetrics.s2 + 1)
            .background(Color.cascadeAccent)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct CascadeQuietButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cascadeSans(13, .medium))
            .foregroundStyle(Color.cascadeText)
            .padding(.horizontal, CascadeMetrics.s4)
            .padding(.vertical, CascadeMetrics.s2 + 1)
            .background(Color.cascadePanel2)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.cascadeBorderHi, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Recording pill

public struct CascadeRecordingPill: View {
    private let label: String
    private let active: Bool
    @State private var pulse = false

    public init(label: String = "Recording", active: Bool = true) {
        self.label = label
        self.active = active
    }

    public var body: some View {
        HStack(spacing: CascadeMetrics.s2) {
            Circle()
                .fill(active ? Color.cascadeRecDot : Color.cascadeText3)
                .frame(width: 7, height: 7)
                .opacity(active && pulse ? 0.4 : 1)
                .animation(active ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(label)
                .font(.cascadeMono(11, .medium))
                .foregroundStyle(active ? Color.cascadeRecText : Color.cascadeText2)
        }
        .padding(.horizontal, CascadeMetrics.s3)
        .padding(.vertical, CascadeMetrics.s1 + 2)
        .background((active ? Color.cascadeRecDot : Color.cascadeText4).opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke((active ? Color.cascadeRecDot : Color.cascadeBorderHi).opacity(0.45), lineWidth: 1))
        .onAppear { pulse = true }
    }
}

// MARK: - Tag pill

public struct CascadeTag: View {
    private let label: String
    private let tone: Color

    public init(_ label: String, tone: Color = .cascadeAccent) {
        self.label = label
        self.tone = tone
    }

    public var body: some View {
        Text(label.uppercased())
            .font(.cascadeMono(10, .semibold))
            .tracking(0.6)
            .foregroundStyle(tone)
            .padding(.horizontal, CascadeMetrics.s2 + 2)
            .padding(.vertical, CascadeMetrics.s1 + 1)
            .background(tone.opacity(0.13))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tone.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Sidebar / nav row

public struct CascadeSidebarRow: View {
    private let title: String
    private let systemImage: String
    private let isActive: Bool

    public init(title: String, systemImage: String, isActive: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: CascadeMetrics.s2) {
            Image(systemName: systemImage)
            Text(title).font(.cascadeSans(13, isActive ? .semibold : .medium))
        }
        .foregroundStyle(isActive ? Color.cascadeOnAccent : Color.cascadeText2)
        .padding(.horizontal, CascadeMetrics.s3)
        .padding(.vertical, CascadeMetrics.s2)
        .background(isActive ? Color.cascadeAccent : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Legacy bridge
//
// The first UI slice used a dark blue/cyan system (`CascadePalette`, `CascadeCard`,
// `CascadePill`, `Cascade{Primary,Secondary}ButtonStyle`). These now map onto the
// real design tokens so any remaining references re-skin automatically.

public enum CascadePalette {
    public static let background = Color.cascadeBG
    public static let panel = Color.cascadePanel
    public static let panelRaised = Color.cascadePanel2
    public static let text = Color.cascadeText
    public static let secondaryText = Color.cascadeText2
    public static let blue = Color.cascadeAccent
    public static let cyan = Color.cascadeAccentWarm
    public static let line = Color.cascadeBorder
    public static let good = Color.cascadeGood
    public static let warn = Color.cascadeAccent2
}

public struct CascadeCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        CascadePanel(padding: 18) { content }
    }
}

public struct CascadePill: View {
    private let label: String
    private let tone: Color
    public init(_ label: String, tone: Color = .cascadeAccent) {
        self.label = label
        self.tone = tone
    }
    public var body: some View { CascadeTag(label, tone: tone) }
}

public struct CascadePrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        CascadeAccentButtonStyle().makeBody(configuration: configuration)
    }
}

public struct CascadeSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        CascadeQuietButtonStyle().makeBody(configuration: configuration)
    }
}
