import AppKit
import SwiftUI
import Combine

/// UserDefaults keys used by the settings.
enum SettingsKey {
    static let replaceLockWallpaper = "replaceLockWallpaper"
    static let savedWallpapers = "savedWallpapers"
}

/// While the Mac is locked, swaps the desktop wallpaper (which macOS also shows on the
/// lock screen) for the cover art, then puts the original back.
final class WallpaperManager {
    static let shared = WallpaperManager()

    // ===== LOOK: change these numbers =====
    static let blurRadius: CGFloat = 60
    static let dimAmount: Double = 0.30      // 0 = no darkening, 1 = black
    // ======================================

    private var cancellable: AnyCancellable?
    private var applied = false
    private var lastKey = ""
    private var savedOptions: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]

    private let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musiczy/Wallpaper", isDirectory: true)

    func start() {
        // If a previous run was killed while the wallpaper was swapped, put the original back first.
        restore()

        cancellable = Publishers.CombineLatest(
            LockScreenController.shared.$isLocked,
            NowPlayingViewModel.shared.$song
        )
        .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
        .sink { [weak self] locked, song in
            self?.update(locked: locked, song: song)
        }
    }

    // MARK: - Deciding what to do

    private func update(locked: Bool, song: Song) {
        let enabled = UserDefaults.standard.bool(forKey: SettingsKey.replaceLockWallpaper)

        guard locked, enabled else {
            restore()
            return
        }
        guard let art = song.artwork, song.title != "Nothing playing" else { return }

        let key = "\(song.title)|\(song.artist)|\(song.album)"
        guard !applied || key != lastKey else { return }   // this song is already showing
        apply(art, key: key)
    }

    // MARK: - Swapping the wallpaper

    private func apply(_ art: NSImage, key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Remember the user's own wallpaper once, before the first swap.
        if !applied { saveOriginals() }

        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: NSNumber(value: true)
        ]

        var newFiles: [URL] = []
        for screen in NSScreen.screens {
            guard let data = renderJPEG(art, size: screen.frame.size, scale: screen.backingScaleFactor)
            else { continue }

            // A new file name every time, because macOS caches wallpapers by file path.
            let file = folder.appendingPathComponent("cover-\(UUID().uuidString).jpg")
            guard (try? data.write(to: file)) != nil else { continue }

            do {
                try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
                newFiles.append(file)
            } catch {
                print("Wallpaper error:", error)
            }
        }

        applied = !newFiles.isEmpty
        lastKey = key
        deleteFiles(except: newFiles)
    }

    /// Puts the user's original wallpaper back.
    func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: SettingsKey.savedWallpapers) as? [String: String] ?? [:]
        guard !saved.isEmpty || applied else { return }

        for screen in NSScreen.screens {
            guard let id = screenID(screen),
                  let string = saved[id],
                  let url = URL(string: string) else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: savedOptions[id] ?? [:])
            } catch {
                print("Wallpaper restore error:", error)
            }
        }

        UserDefaults.standard.removeObject(forKey: SettingsKey.savedWallpapers)
        applied = false
        lastKey = ""
        savedOptions = [:]
        deleteFiles(except: [])
    }

    // MARK: - Helpers

    /// Saved to disk too, so the wallpaper can be restored even if the app crashes.
    private func saveOriginals() {
        var urls: [String: String] = [:]
        savedOptions = [:]
        for screen in NSScreen.screens {
            guard let id = screenID(screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !url.path.hasPrefix(folder.path) else { continue }   // never save our own cover as the original
            urls[id] = url.absoluteString
            if let opts = NSWorkspace.shared.desktopImageOptions(for: screen) {
                savedOptions[id] = opts
            }
        }
        UserDefaults.standard.set(urls, forKey: SettingsKey.savedWallpapers)
    }

    private func screenID(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    private func deleteFiles(except keep: [URL]) {
        let keepNames = Set(keep.map { $0.lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keepNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Draws the blurred cover at the screen's size and returns it as a JPEG.
    private func renderJPEG(_ art: NSImage, size: CGSize, scale: CGFloat) -> Data? {
        MainActor.assumeIsolated { () -> Data? in
            let renderer = ImageRenderer(content: WallpaperCanvas(image: art, size: size))
            renderer.scale = scale
            guard let cg = renderer.cgImage else { return nil }
            return NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }
}

/// Same look as the main window's background.
private struct WallpaperCanvas: View {
    let image: NSImage
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .blur(radius: WallpaperManager.blurRadius)
                .saturation(1.6)
                .brightness(0.05)
                .scaleEffect(1.3)
            Color.black.opacity(WallpaperManager.dimAmount)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
