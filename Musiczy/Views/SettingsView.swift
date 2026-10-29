import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(SettingsKey.replaceLockWallpaper) private var replaceWallpaper = false
    @AppStorage(SettingsKey.adFilePath) private var adFilePath = ""
    @AppStorage(SettingsKey.adVolume) private var adVolume = 0.8
    @ObservedObject private var adPlayer = AdAudioPlayer.shared
    @State private var pickingFile = false

    private var adFileName: String {
        adFilePath.isEmpty ? "No file selected"
                           : URL(fileURLWithPath: adFilePath).lastPathComponent
    }

    var body: some View {
        Form {
            Section("Display style") {
                DisplayStylePicker()
            }

            Section("Lock screen") {
                Toggle("Use cover art as lock screen wallpaper", isOn: $replaceWallpaper)
            }

            Section("Ads") {
                LabeledContent("Ad sound") {
                    Text(adFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Choose File…") { pickingFile = true }
                    if !adFilePath.isEmpty {
                        Button(adPlayer.isPreviewing ? "Stop" : "Preview") {
                            adPlayer.togglePreview()
                        }
                        Button("Remove") {
                            adPlayer.stopPreview()
                            adFilePath = ""
                        }
                    }
                }

                Slider(value: $adVolume, in: 0...1) { Text("Volume") }

                Text("Spotify is muted during ads and this file plays on a loop until the ad ends. Any audio file works, such as MP3, M4A, WAV or FLAC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                adPlayer.stopPreview()
                adFilePath = url.path
            }
        }
        .onChange(of: adVolume) { _, _ in adPlayer.applyVolume() }
    }
}

/// Opens Settings in its own window: centered, active, and in front of everything.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        let w = window ?? makeWindow()
        window = w

        // Already open: just bring it back to the front.
        if w.isVisible {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            return
        }
        
        // Give the window its real size BEFORE centering it.
                // On the first open, SwiftUI hasn't measured the content yet.
                if let view = w.contentViewController?.view {
                    view.layoutSubtreeIfNeeded()
                    let size = view.fittingSize
                    if size.width > 0, size.height > 0 { w.setContentSize(size) }
                }
                w.layoutIfNeeded()

        // Exact center of the screen where the mouse is (the one whose menu bar you clicked).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let frame = screen?.frame {
            let size = w.frame.size
            w.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.midY - size.height / 2))
        }

        NSApp.activate()
        w.makeKeyAndOrderFront(nil)   // pops up with the system's alert-style animation
        w.orderFrontRegardless()      // comes forward even if another app is active
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        w.title = "Musiczy Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.hidesOnDeactivate = false                              // stays up when you click another app
        w.level = .modalPanel                                    // above normal and floating windows of other apps
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]   // opens on your current Space, even over full-screen apps
        w.animationBehavior = .alertPanel                        // the pop-up animation
        return w
    }
}
