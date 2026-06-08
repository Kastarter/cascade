import SwiftUI

public enum CascadePalette {
    public static let background = Color(red: 0.055, green: 0.065, blue: 0.075)
    public static let panel = Color(red: 0.105, green: 0.120, blue: 0.140)
    public static let panelRaised = Color(red: 0.135, green: 0.155, blue: 0.180)
    public static let text = Color(red: 0.950, green: 0.970, blue: 0.990)
    public static let secondaryText = Color(red: 0.650, green: 0.700, blue: 0.760)
    public static let blue = Color(red: 0.270, green: 0.560, blue: 1.000)
    public static let cyan = Color(red: 0.240, green: 0.840, blue: 0.980)
    public static let line = Color.white.opacity(0.085)
    public static let good = Color(red: 0.280, green: 0.850, blue: 0.540)
    public static let warn = Color(red: 1.000, green: 0.760, blue: 0.330)
}

public struct CascadeCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CascadePalette.panel.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CascadePalette.line, lineWidth: 1)
                    )
            )
    }
}

public struct CascadePill: View {
    private let label: String
    private let tone: Color

    public init(_ label: String, tone: Color = CascadePalette.blue) {
        self.label = label
        self.tone = tone
    }

    public var body: some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(tone)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.opacity(0.13))
                    .overlay(Capsule(style: .continuous).stroke(tone.opacity(0.30), lineWidth: 1))
            )
    }
}

public struct CascadePrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [CascadePalette.blue, CascadePalette.cyan.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(configuration.isPressed ? 0.78 : 1)
            )
    }
}

public struct CascadeSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(CascadePalette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.075))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CascadePalette.line, lineWidth: 1)
                    )
            )
    }
}
