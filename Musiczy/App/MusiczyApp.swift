import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: EdgeToEdgeWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = EdgeToEdgeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: ContentView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        WindowManager.shared.setup(window)
        WallpaperManager.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    func applicationWillTerminate(_ notification: Notification) {
        SpotifyBridge.setAdMuted(false)
        WallpaperManager.shared.restore()
    }
}

@main
struct MusiczyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)
    }
}
