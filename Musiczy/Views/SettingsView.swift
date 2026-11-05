import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(SettingsKey.replaceLockWallpaper) private var replaceWallpaper = false
    @AppStorage(SettingsKey.adVolume) private var adVolume = 0.8
    @AppStorage(SettingsKey.ambientShine) private var ambientShine = false
    @AppStorage(SettingsKey.blurredBackground) private var blurredBackground = true
    @AppStorage(SettingsKey.ambientSaturation) private var ambientSaturation = ShineDefault.saturation
    @AppStorage(SettingsKey.ambientSize) private var ambientSize = ShineDefault.size
    @AppStorage(SettingsKey.shineLength) private var shineLength = ShineDefault.length
    @AppStorage(SettingsKey.shineSpeed) private var shineSpeed = ShineDefault.speed
    @ObservedObject private var adPlayer = AdAudioPlayer.shared
    @State private var pickingFiles = false

    // ===== LIST SIZE: change these numbers =====
    private let rowHeight: CGFloat = 30
    private let maxListHeight: CGFloat = 150     // the list scrolls after this
    // ===========================================

    var body: some View {
        Form {
            Section("Display style") {
                DisplayStylePicker()

                Text("Click a style to switch the player right away. The Art and Lyrics buttons in the player change it too, and your choice is remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background") {
                Toggle("Blurred cover background", isOn: $blurredBackground)
                Toggle("Ambient border shine", isOn: $ambientShine)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ambient light")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 24) {
                            sliderCell("Saturation", $ambientSaturation, ShineDefault.saturationRange)
                            sliderCell("Size", $ambientSize, ShineDefault.sizeRange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 24) {
                            sliderCell("Length", $shineLength, ShineDefault.lengthRange)
                            sliderCell("Speed", $shineSpeed, ShineDefault.speedRange)
                        }
                    }

                    Button("Reset sliders") {
                        ambientSaturation = ShineDefault.saturation
                        ambientSize = ShineDefault.size
                        shineLength = ShineDefault.length
                        shineSpeed = ShineDefault.speed
                    }
                }
                .disabled(!ambientShine)
                .opacity(ambientShine ? 1 : 0.4)
            }

            Section("Lock screen") {
                Toggle("Use cover art as lock screen wallpaper", isOn: $replaceWallpaper)
                Text("While the Mac is locked, your wallpaper is replaced with a blurred copy of the cover. It goes back when you unlock or quit Musiczy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alternative music during ads") {
                if adPlayer.paths.isEmpty {
                    Text("No files added")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(adPlayer.paths, id: \.self) { path in
                                adRow(path)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(adPlayer.paths.count) * rowHeight, maxListHeight))
                }

                HStack {
                    Button("Add Files…") { pickingFiles = true }
                    if !adPlayer.paths.isEmpty {
                        Button("Remove All") { adPlayer.removeAll() }
                    }
                }

                Slider(value: $adVolume, in: 0...1) { Text("Volume") }

                Text("Spotify is muted during ads and Musiczy plays a random file from this list. When a file ends it picks another one, until the ad is over. The same file doesn't play twice in a row. Any audio file works, such as MP3, M4A, WAV or FLAC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .fileImporter(isPresented: $pickingFiles,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                adPlayer.stopPreview()
                adPlayer.add(urls)
            }
        }
        .onChange(of: adVolume) { _, _ in adPlayer.applyVolume() }
        .onDisappear { adPlayer.stopPreview() }
    }

    /// One slider with its name on the left. Two of these sit side by side on one line.
    private func sliderCell(_ title: String, _ value: Binding<Double>,
                            _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    /// One file in the list: name, preview button and remove button.
    private func adRow(_ path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        let previewing = adPlayer.previewingPath == path

        return HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !exists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("File not found. It is skipped during ads.")
            }

            Button {
                adPlayer.togglePreview(path)
            } label: {
                Image(systemName: previewing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!exists)
            .help(previewing ? "Stop" : "Preview")

            Button {
                adPlayer.remove(path)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from the list")
        }
        .frame(height: rowHeight)
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
