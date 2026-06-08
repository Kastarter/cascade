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

    var body: some Scene {
        WindowGroup("Cascade") {
            CascadeRootView(model: model.value)
                .preferredColorScheme(.dark)
                .task { await model.value.refreshAll() }
        }
        .windowStyle(.hiddenTitleBar)
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
