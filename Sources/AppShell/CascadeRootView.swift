import AppKit
import CascadeDesignSystem
import CascadeMemory
import MacContextKit
import SuggestionEngine
import SwiftUI

public struct CascadeRootView: View {
    @ObservedObject private var model: CascadeAppModel

    public init(model: CascadeAppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            CascadePalette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                CascadeTopBar(model: model)
                content
            }
            if model.dock.visible {
                ControlDockView(model: model)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(CascadePalette.text)
        .frame(minWidth: 980, minHeight: 680)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .reel:
            ReelView(model: model)
        case .cascades:
            CascadesView(model: model)
        case .manager:
            ManagerView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

private struct CascadeTopBar: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(nsImage: NSImage(named: "cascadeTemplate") ?? NSImage())
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(CascadePalette.text)
                Text("Cascade")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }

            HStack(spacing: 6) {
                ForEach(CascadeAppModel.Tab.allCases) { tab in
                    CascadeTabButton(tab: tab, selectedTab: $model.selectedTab)
                }
            }
            .padding(4)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()

            Text(Date.now, style: .date)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CascadePalette.secondaryText)

            Button {
                model.recorder.status.running ? model.pauseRecording() : model.startRecording()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.recorder.status.running ? CascadePalette.good : CascadePalette.warn)
                        .frame(width: 7, height: 7)
                    Text(model.recorder.status.running ? "REC · LOCAL" : "PAUSED · LOCAL")
                }
            }
            .buttonStyle(CascadeSecondaryButtonStyle())
            .help("Everything stays on this Mac")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.20))
        .overlay(Rectangle().fill(CascadePalette.line).frame(height: 1), alignment: .bottom)
    }
}

private struct CascadeTabButton: View {
    let tab: CascadeAppModel.Tab
    @Binding var selectedTab: CascadeAppModel.Tab

    private var icon: String {
        switch tab {
        case .reel: "rectangle.stack"
        case .cascades: "sparkles"
        case .manager: "chart.bar"
        case .settings: "gearshape"
        }
    }

    var body: some View {
        Button {
            selectedTab = tab
        } label: {
            Label(tab.rawValue, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(minWidth: 92, minHeight: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTab == tab ? Color.white : CascadePalette.secondaryText)
        .background(selectedTab == tab ? CascadePalette.blue : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(tab.rawValue)
    }
}

private struct ReelView: View {
    @ObservedObject var model: CascadeAppModel
    @State private var question = "What was I doing here?"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                computerUsePanel
                HStack(alignment: .top, spacing: 18) {
                    momentViewer
                    timeline
                }
                HStack(alignment: .top, spacing: 18) {
                    askPanel
                    auditPanel
                }
            }
            .padding(32)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                CascadePill("CAPTURED · LOCAL", tone: CascadePalette.cyan)
                Text("Rewind your work context")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Screen, app, window, and accessibility context stay local first. Agents come after the record is trustworthy.")
                    .foregroundStyle(CascadePalette.secondaryText)
                    .font(.system(size: 14))
            }
            Spacer()
            Button("Capture now") { model.captureOnce() }
                .buttonStyle(CascadePrimaryButtonStyle())
        }
    }

    private var computerUsePanel: some View {
        CascadeCard {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: model.screenAgentReady ? "cursorarrow.motionlines" : "cursorarrow.rays")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(model.screenAgentReady ? CascadePalette.good : CascadePalette.warn)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Computer Use")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(model.screenAgentMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(CascadePalette.secondaryText)
                    Text("Use \(model.hotkey.label) or the button below to open the supervised dock. OpenClicky/TipTour action routing is the next port.")
                        .font(.system(size: 12))
                        .foregroundStyle(CascadePalette.secondaryText.opacity(0.85))
                }
                Spacer()
                Button("Use device") { model.beginUseDeviceIntent() }
                    .buttonStyle(CascadePrimaryButtonStyle())
                Button("Check") { model.refreshComputerUseHealthFromUI() }
                    .buttonStyle(CascadeSecondaryButtonStyle())
                Button("Settings") { model.selectedTab = .settings }
                    .buttonStyle(CascadeSecondaryButtonStyle())
            }
        }
    }

    private var timeline: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Today")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(model.contexts.count) samples")
                        .foregroundStyle(CascadePalette.secondaryText)
                }
                ForEach(model.contexts.prefix(10)) { context in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CascadePalette.blue.opacity(0.70))
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.appName)
                                .font(.system(size: 14, weight: .semibold))
                            Text(context.windowTitle ?? "No window title captured")
                                .font(.system(size: 12))
                                .foregroundStyle(CascadePalette.secondaryText)
                            Text(context.capturedAt, style: .time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(CascadePalette.secondaryText.opacity(0.75))
                        }
                        Spacer()
                    }
                    .frame(minHeight: 48)
                }
                if model.contexts.isEmpty {
                    EmptyState(title: "No context yet", detail: "Grant Screen Recording, then capture a local moment.")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
    }

    private var momentViewer: some View {
        let latest = model.contexts.first
        return CascadeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Moment")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    CascadePill(latest == nil ? "WAITING" : "LOCAL", tone: latest == nil ? CascadePalette.warn : CascadePalette.cyan)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(CascadePalette.line, lineWidth: 1)
                        )
                    VStack(spacing: 10) {
                        Image(systemName: "display")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(CascadePalette.blue)
                        Text(latest?.appName ?? "No captured moment yet")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(latest?.windowTitle ?? "Screen/OCR preview will land here when ScreenCaptureKit is ported.")
                            .font(.system(size: 12))
                            .foregroundStyle(CascadePalette.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                    .padding(18)
                }
                .frame(height: 230)
                if let latest {
                    MomentMeta(context: latest)
                }
            }
        }
        .frame(width: 360, alignment: .topLeading)
    }

    private var askPanel: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ask from context")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                TextField("Ask Cascade", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.ask(question) }
                HStack {
                    Button("Ask") { model.ask(question) }
                        .buttonStyle(CascadePrimaryButtonStyle())
                    Button("Use device") { model.beginUseDeviceIntent() }
                        .buttonStyle(CascadeSecondaryButtonStyle())
                    Button("What did I do today?") { model.ask("What did I do today?") }
                        .buttonStyle(CascadeSecondaryButtonStyle())
                }
                Divider().overlay(CascadePalette.line)
                Text(model.answer)
                    .font(.system(size: 14))
                    .foregroundStyle(CascadePalette.text)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var auditPanel: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audit")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                ForEach(model.audit.prefix(6)) { event in
                    HStack {
                        Text(event.action)
                            .font(.system(size: 12, design: .monospaced))
                        Text(event.detail)
                            .foregroundStyle(CascadePalette.secondaryText)
                        Spacer()
                        Text(event.createdAt, style: .time)
                            .foregroundStyle(CascadePalette.secondaryText.opacity(0.75))
                    }
                    .font(.system(size: 12))
                }
                if model.audit.isEmpty {
                    EmptyState(title: "No audit events", detail: "Recording and agent actions will appear here.")
                }
            }
        }
    }
}

private struct CascadesView: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    eyebrow: "CASCADES",
                    title: "Review, test, then run",
                    detail: "Helpers only run after evidence, sandboxing, approval, and a visible STOP control."
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(model.suggestions) { suggestion in
                        SuggestionCard(suggestion: suggestion)
                    }
                    if model.suggestions.isEmpty {
                        CascadeCard {
                            EmptyState(title: "No helpers suggested yet", detail: "Cascade needs enough repeated local context before suggesting an agent.")
                        }
                    }
                }
                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ManagerView: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeader(
                eyebrow: "MANAGER",
                title: "Suggestions from privacy-safe signals",
                detail: "This view is a local prototype. It should never expose raw OCR or screenshots to a manager."
            )
            HStack(spacing: 14) {
                MetricCard(value: "\(model.suggestions.count)", label: "Patterns to review")
                MetricCard(value: "\(model.contexts.count)", label: "Local samples")
                MetricCard(value: "0", label: "Raw manager screenshots")
            }
            Spacer()
        }
        .padding(32)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    eyebrow: "SETTINGS",
                    title: "Local trust controls",
                    detail: "Permissions are explicit. Cascade does not touch ScreenCaptureKit paths before Screen Recording is granted."
                )
                CascadeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        PermissionRow(name: "Screen Recording", granted: model.recorder.status.permissions.screenRecording)
                        PermissionRow(name: "Accessibility", granted: model.recorder.status.permissions.accessibility)
                        PermissionRow(name: "Input Monitoring", granted: model.recorder.status.permissions.inputMonitoring)
                        PermissionRow(name: "Use-device hotkey", granted: model.hotkey.running, detail: model.hotkey.label)
                        HStack {
                            Button("Refresh") { model.refreshPermissionState() }
                                .buttonStyle(CascadeSecondaryButtonStyle())
                            Button("Request Screen") { model.requestScreenRecording() }
                                .buttonStyle(CascadeSecondaryButtonStyle())
                            Button("Request AX") { model.requestAccessibility() }
                                .buttonStyle(CascadeSecondaryButtonStyle())
                            Button("Request Input") { model.requestInputMonitoring() }
                                .buttonStyle(CascadeSecondaryButtonStyle())
                            Button("Open Settings") { model.openSystemSettings() }
                                .buttonStyle(CascadePrimaryButtonStyle())
                        }
                    }
                }
                DiagnosticsCard(diagnostics: model.permissionDiagnostics)
                ClaudeKeyCard(model: model)
                Spacer()
            }
            .padding(32)
        }
    }
}

private struct ControlDockView: View {
    @ObservedObject var model: CascadeAppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSImage(named: "cascadeTemplate") ?? NSImage())
                .resizable()
                .renderingMode(.template)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.dock.title).font(.system(size: 13, weight: .semibold))
                Text(model.dock.detail).font(.system(size: 12)).foregroundStyle(CascadePalette.secondaryText)
            }
            Button("STOP") { model.dock.stop() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(CascadeSecondaryButtonStyle())
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CascadePalette.line))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
    }
}

private struct SectionHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CascadePill(eyebrow, tone: CascadePalette.cyan)
            Text(title)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(CascadePalette.secondaryText)
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: AgentSuggestion

    var body: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 12) {
                CascadePill("REVIEWABLE", tone: CascadePalette.warn)
                Text(suggestion.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(suggestion.summary)
                    .foregroundStyle(CascadePalette.secondaryText)
                    .font(.system(size: 13))
                Divider().overlay(CascadePalette.line)
                ForEach(suggestion.evidence, id: \.self) { item in
                    Label(item, systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(CascadePalette.secondaryText)
                }
                Text("\(Int(suggestion.confidence * 100))% confidence")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CascadePalette.cyan)
            }
        }
        .frame(width: 320)
    }
}

private struct MomentMeta: View {
    let context: RecordedContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(context.capturedAt.formatted(date: .omitted, time: .shortened), systemImage: "clock")
            Label(context.bundleIdentifier ?? "No bundle id", systemImage: "app")
            Label(context.source.rawValue, systemImage: "record.circle")
        }
        .font(.system(size: 12))
        .foregroundStyle(CascadePalette.secondaryText)
    }
}

private struct ClaudeKeyCard: View {
    @ObservedObject var model: CascadeAppModel
    @State private var key = ""

    var body: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude key")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(model.keyMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(CascadePalette.secondaryText)
                    }
                    Spacer()
                    CascadePill(model.hasAnthropicKey ? "CONNECTED" : "BYOK", tone: model.hasAnthropicKey ? CascadePalette.good : CascadePalette.warn)
                }
                SecureField("sk-ant-...", text: $key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") {
                        model.saveAnthropicKey(key)
                        key = ""
                    }
                    .buttonStyle(CascadePrimaryButtonStyle())
                    Button("Clear") {
                        model.clearAnthropicKey()
                        key = ""
                    }
                    .buttonStyle(CascadeSecondaryButtonStyle())
                }
                Text("Stored in macOS Keychain. Used only for Claude-backed Q&A, suggestions, and reviewed agents.")
                    .font(.system(size: 12))
                    .foregroundStyle(CascadePalette.secondaryText)
            }
        }
    }
}

private struct DiagnosticsCard: View {
    let diagnostics: PermissionDiagnostics

    var body: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("App identity")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    CascadePill(diagnostics.bundleIdentifier, tone: CascadePalette.cyan)
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
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .frame(width: 82, alignment: .leading)
                .foregroundStyle(CascadePalette.secondaryText)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.system(size: 12))
    }
}

private struct MetricCard: View {
    let value: String
    let label: String

    var body: some View {
        CascadeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CascadePalette.secondaryText)
            }
        }
        .frame(width: 210)
    }
}

private struct PermissionRow: View {
    let name: String
    let granted: Bool
    var detail: String? = nil

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? CascadePalette.good : CascadePalette.warn)
            Text(name)
            if let detail {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CascadePalette.secondaryText)
            }
            Spacer()
            Text(granted ? "Granted" : "Needed")
                .foregroundStyle(CascadePalette.secondaryText)
        }
    }
}

private struct EmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(CascadePalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}
