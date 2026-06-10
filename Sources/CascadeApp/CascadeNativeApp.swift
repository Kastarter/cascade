import AppKit
import AppShell
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "cascadeTemplate")
            button.image?.isTemplate = true
            button.toolTip = "Cascade"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Cascade", action: #selector(openCascade), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Cascade", action: #selector(quitCascade), keyEquivalent: "q"))
        statusItem?.menu = menu

        // The app opens as a regular window — fullscreen stays one click away
        // (the top-bar expand button, ⌃⌘F, or the green traffic light).
        markFullScreenCapable(attempt: 0)
    }

    /// SwiftUI's WindowGroup creates the window slightly after launch; retry until
    /// it exists, then mark it fullscreen-primary so the toggle works, WITHOUT
    /// entering fullscreen automatically.
    private func markFullScreenCapable(attempt: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 200 : 120))
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
                if attempt < 50 { self.markFullScreenCapable(attempt: attempt + 1) }
                return
            }
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }

    @objc private func openCascade() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitCascade() {
        NSApp.terminate(nil)
    }
}

@main
struct CascadeNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModelBox.make()
    @StateObject private var notch = NotchController()

    var body: some Scene {
        WindowGroup("Cascade") {
            CascadeRootView(model: model.value)
                .task {
                    model.value.guidanceOverlay.startFollowing()
                    notch.attach(model: model.value)
                    await model.value.refreshAll()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandMenu("Cascade") {
                Button("Use Device") { model.value.beginUseDeviceIntent(source: "menu") }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                Button("Capture Moment") { model.value.captureOnce() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(model.value.recorder.status.running ? "Pause Recording" : "Start Recording") {
                    model.value.recorder.status.running ? model.value.pauseRecording() : model.value.startRecording()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Full Screen") {
                    NSApp.windows.first(where: { $0.canBecomeMain })?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}

@MainActor
private final class AppModelBox: ObservableObject {
    let value: CascadeAppModel

    init(value: CascadeAppModel) {
        self.value = value
    }

    static func make() -> AppModelBox {
        do {
            return AppModelBox(value: try CascadeAppModel())
        } catch {
            fatalError("Cascade failed to start: \(error.localizedDescription)")
        }
    }
}
