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
/// When the song changes, the wallpaper fades to the new cover.
final class WallpaperManager {
    static let shared = WallpaperManager()

    // ===== LOOK: change these numbers =====
    static let blurRadius: CGFloat = 60
    static let dimAmount: Double = 0.30      // 0 = no darkening, 1 = black
    // ======================================

    // ===== FADE: change these numbers =====
    /// Seconds the wallpaper takes to fade to the new cover. 0 = change instantly.
    static let fadeDuration: Double = 1.0
    /// How many pictures are shown during the fade. More = smoother but heavier.
    static let fadeSteps = 8
    // ======================================

    /// One picture to show: the file contents, plus the image itself (kept for the next fade).
    private struct Frame {
        let data: Data
        let image: CGImage
    }

    private var cancellable: AnyCancellable?
    private var applied = false
    private var lastKey = ""
    private var savedOptions: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]

    /// What each screen is showing right now, so the next song can fade from it.
    private var shown: [String: CGImage] = [:]
    private var currentFiles: [URL] = []
    private var previousFiles: [URL] = []

    /// Lets a newer song (or an unlock) stop a fade that is still running.
    private let tokenLock = NSLock()
    private var tokenValue = 0
    private var currentToken: Int {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return tokenValue
    }
    private func newToken() -> Int {
        tokenLock.lock(); defer { tokenLock.unlock() }
        tokenValue += 1
        return tokenValue
    }

    private let encodeQueue = DispatchQueue(label: "musiczy.wallpaper.fade", qos: .userInitiated)

    private let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musiczy/Wallpaper", isDirectory: true)

    func start() {
        // If a previous run was killed while the wallpaper was swapped, put the original back first.
        restore()

        // Lock and unlock still wait 0.4 s. A song change while locked is handled right away.
        let lockState = LockScreenController.shared.$isLocked
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)

        cancellable = Publishers.CombineLatest(
            lockState,
            NowPlayingViewModel.shared.$song.receive(on: DispatchQueue.main)
        )
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

        let key = LockSongGate.key(song)
        if !applied || key != lastKey {           // skip if this song is already showing
            apply(art, key: key)
        }

        // Tell the lock screen this song's wallpaper is on its way, so the card can change now.
        LockSongGate.shared.wallpaperReady(key: key)
    }

    // MARK: - Swapping the wallpaper (with a fade)

    private func apply(_ art: NSImage, key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Use the HD cover when we have it.
        let source = NowPlayingViewModel.shared.hiResArtwork ?? art

        // Remember the user's own wallpaper once, before the first swap.
        if !applied { saveOriginals() }

        // Draw the new wallpaper for every screen.
        var targets: [String: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let id = screenID(screen),
                  let image = renderCG(source, size: screen.frame.size, scale: screen.backingScaleFactor)
            else { continue }
            targets[id] = image
        }
        guard !targets.isEmpty else { return }

        // Fade from whatever is on screen now. The very first swap after locking is not faded.
        let starts = shown
        let fading = applied && !starts.isEmpty && Self.fadeDuration > 0 && Self.fadeSteps > 1
        let steps = fading ? Self.fadeSteps : 1

        applied = true
        lastKey = key
        let token = newToken()
        let begin = Date()
        let duration = Self.fadeDuration

        // Blending and encoding happen in the background; only setting the wallpaper is on the main thread.
        encodeQueue.async { [weak self] in
            for step in 1...steps {
                guard let self, self.currentToken == token else { return }
                let last = step == steps
                let t = Double(step) / Double(steps)

                var frames: [String: Frame] = [:]
                for (id, target) in targets {
                    var image = target
                    if !last, let start = starts[id], let mixed = Self.blend(start, target, t) {
                        image = mixed
                    }
                    // In-between pictures are JPEG (fast, only on screen briefly). The last one is lossless PNG.
                    if let data = Self.encode(image, png: last) {
                        frames[id] = Frame(data: data, image: image)
                    }
                }

                // Space the pictures out evenly over the fade.
                if fading {
                    let wait = begin.addingTimeInterval(duration * t).timeIntervalSinceNow
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
                guard self.currentToken == token else { return }

                DispatchQueue.main.async { [weak self] in
                    self?.show(frames, png: last, token: token)
                }
            }
        }
    }

    /// Sets one picture as the wallpaper on each screen.
    private func show(_ frames: [String: Frame], png: Bool, token: Int) {
        guard token == currentToken else { return }   // a newer song or an unlock took over

        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: NSNumber(value: true)
        ]

        var files: [URL] = []
        for (id, frame) in frames {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == id }) else { continue }

            // A new file name every time, because macOS caches wallpapers by file path.
            let file = folder.appendingPathComponent("cover-\(UUID().uuidString).\(png ? "png" : "jpg")")
            guard (try? frame.data.write(to: file)) != nil else { continue }

            do {
                try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
                files.append(file)
                shown[id] = frame.image
            } catch {
                print("Wallpaper error:", error)
            }
        }
        guard !files.isEmpty else { return }

        // Keep the previous pictures for a moment, in case macOS is still reading them.
        previousFiles = currentFiles
        currentFiles = files
        deleteFiles(except: currentFiles + previousFiles)
    }

    /// Puts the user's original wallpaper back.
    func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: SettingsKey.savedWallpapers) as? [String: String] ?? [:]
        guard !saved.isEmpty || applied else { return }

        _ = newToken()   // stops a fade that is still running

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
        shown = [:]
        currentFiles = []
        previousFiles = []
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

    /// Draws the blurred cover at the screen's size.
    private func renderCG(_ art: NSImage, size: CGSize, scale: CGFloat) -> CGImage? {
        MainActor.assumeIsolated { () -> CGImage? in
            let renderer = ImageRenderer(content: WallpaperCanvas(image: art, size: size))
            renderer.scale = scale
            return renderer.cgImage
        }
    }

    /// Mixes two pictures: t = 0 is all `from`, t = 1 is all `to`.
    private static func blend(_ from: CGImage, _ to: CGImage, _ t: Double) -> CGImage? {
        let space: CGColorSpace
        if let s = to.colorSpace, s.model == .rgb {
            space = s
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let ctx = CGContext(data: nil,
                                  width: to.width, height: to.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: to.width, height: to.height)
        ctx.interpolationQuality = .high
        ctx.draw(from, in: rect)
        ctx.setAlpha(CGFloat(t))
        ctx.draw(to, in: rect)
        return ctx.makeImage()
    }

    private static func encode(_ image: CGImage, png: Bool) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return png
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
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
