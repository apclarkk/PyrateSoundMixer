import AppKit
import SwiftUI

@main
struct PyrateSoundsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView().environment(delegate.store)
        } label: {
            Image(systemName: delegate.store.menuBarSymbol)
                .accessibilityLabel(delegate.store.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(delegate.store)
        }

        Window("Audio Routing", id: "routing") {
            RoutingWorkspace()
                .environment(delegate.store)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 720, height: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app sets LSUIElement; this covers running the bare executable.
        NSApp.setActivationPolicy(.accessory)
        store.start()
    }

    /// pyratesounds:// links from Shortcuts, scripts, and other apps.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { store.handle(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }
}
