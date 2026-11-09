import AVFoundation
import Combine

extension SettingsKey {
    static let adFilePaths = "adFilePaths"
    static let adFilePath = "adFilePath"     // old single-file key, only used to carry your old choice over
}

/// What the ad file that is playing right now is.
struct AdTrackInfo {
    let path: String
    let title: String
    let artist: String
    let album: String
    let artworkData: Data?
    let duration: Double
}

/// Plays random files from the user's list while Spotify is playing an ad.
final class AdAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AdAudioPlayer()

    /// Tells the player screen that a track comes from the ad music.
    static let sourceID = "adfile"

    /// The files the user added, in the order they were added.
    @Published private(set) var paths: [String] = []
    /// The file being previewed from Settings (nil = no preview).
    @Published private(set) var previewingPath: String?
    /// The ad file playing right now, with its tags and cover (nil = none).
    @Published private(set) var current: AdTrackInfo?

    private var player: AVAudioPlayer?
    private var lastPlayedPath = ""
    private var failed = Set<String>()        // files that could not be opened, so we don't retry every second
    private var adActive = false
    private var adPlaying = false             // is Spotify's ad playing (not paused)?
    private var lastAdTick = Date.distantPast
    private var preparingPath: String?        // the file whose tags and cover are still loading
    private var infoCache: [String: AdTrackInfo] = [:]

    /// True for a few milliseconds while a new file's name and cover load.
    var isPreparing: Bool { preparingPath != nil }

    /// Where the ad file is, in seconds.
    var position: Double { player?.currentTime ?? 0 }

    /// Same level as Spotify's own volume (0.8 if Spotify can't be read).
    private var volume: Float {
        Float(min(max(SpotifyBridge.volumeLevel ?? 0.8, 0), 1))
    }

    private override init() {
        super.init()
        let d = UserDefaults.standard
        var list = d.stringArray(forKey: SettingsKey.adFilePaths) ?? []

        // Carry over the single file chosen in the old version.
        if let old = d.string(forKey: SettingsKey.adFilePath) {
            if !old.isEmpty, !list.contains(old) { list.append(old) }
            d.removeObject(forKey: SettingsKey.adFilePath)
            d.set(list, forKey: SettingsKey.adFilePaths)
        }
        paths = list
    }

    // MARK: - Called from NowPlayingViewModel.refresh() (once per second)

    func update(isAd: Bool, isPlaying: Bool) {
        if isAd {
            adActive = true
            adPlaying = isPlaying
            lastAdTick = Date()

            // An ad takes over from a preview.
            if previewingPath != nil { stopSound() }

            if isPlaying {
                if player == nil {
                    playRandom()
                } else if player?.isPlaying == false {
                    player?.play()
                }
                player?.volume = volume
            } else {
                player?.pause()            // ad paused: pause the file too
            }
        } else if adActive {
            adActive = false
            stopSound()
        }
    }

    /// Called when no track could be read. Stops the sound if that lasts 4 seconds
    /// (for example, Spotify was closed during an ad).
    func trackLost() {
        guard adActive, Date().timeIntervalSince(lastAdTick) > 4 else { return }
        adActive = false
        stopSound()
    }

    // MARK: - Used by the player screen during an ad

    /// Seeks the ad file (progress bar, or a tapped lyric line).
    func seek(to seconds: Double) {
        guard adActive, let p = player else { return }
        p.currentTime = min(max(seconds, 0), max(p.duration - 0.5, 0))
    }

    /// The next button during an ad: jump to another random file.
    func skipToNext() {
        guard adActive else { return }
        playRandom()
        if !adPlaying { player?.pause() }
    }

    /// The previous button during an ad: start the current file again.
    func restart() {
        guard adActive else { return }
        player?.currentTime = 0
    }

    // MARK: - Used by the Settings window

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls where !paths.contains(url.path) {
            paths.append(url.path)
            changed = true
        }
        if changed {
            failed.removeAll()
            save()
        }
    }

    func remove(_ path: String) {
        if previewingPath == path { stopSound() }
        paths.removeAll { $0 == path }
        failed.remove(path)
        infoCache.removeValue(forKey: path)
        save()
    }

    func removeAll() {
        stopSound()
        paths = []
        failed.removeAll()
        infoCache.removeAll()
        save()
    }

    func togglePreview(_ path: String) {
        if previewingPath == path {
            stopSound()
            return
        }
        stopSound()
        failed.remove(path)
        if start(path) {
            previewingPath = path
        } else {
            failed.insert(path)
        }
    }

    func stopPreview() {
        if previewingPath != nil { stopSound() }
    }


    // MARK: - Helpers

    private func save() {
        UserDefaults.standard.set(paths, forKey: SettingsKey.adFilePaths)
    }

    private func stopSound() {
        player?.stop()
        player = nil
        previewingPath = nil
        preparingPath = nil
        if current != nil { current = nil }
    }

    /// Picks a random file (never the same one twice in a row, if there are others) and plays it.
    private func playRandom() {
        let usable = paths.filter {
            !failed.contains($0) && FileManager.default.fileExists(atPath: $0)
        }
        guard !usable.isEmpty else { return }

        let pool = usable.count > 1 ? usable.filter { $0 != lastPlayedPath } : usable
        guard let pick = pool.randomElement() else { return }

        if start(pick) {
            loadInfo(for: pick)
        } else {
            failed.insert(pick)
            playRandom()                   // try another one
        }
    }

    /// Opens and plays one file. Returns false if it could not be played.
    private func start(_ path: String) -> Bool {
        player?.stop()
        player = nil
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.delegate = self
            p.numberOfLoops = 0            // play once, then we pick the next one
            p.volume = volume
            p.prepareToPlay()
            guard p.play() else { return false }
            player = p
            lastPlayedPath = path
            return true
        } catch {
            print("Ad audio error:", error)
            return false
        }
    }

    // MARK: - Tags and cover of the file that is playing

    private func loadInfo(for path: String) {
        // Played before: use what we already read.
        if let cached = infoCache[path] {
            current = cached
            return
        }

        preparingPath = path
        let duration = player?.duration ?? 0
        let url = URL(fileURLWithPath: path)

        Task { [weak self] in
            let tags = await AdFileMetadata.read(url)
            await MainActor.run { self?.finishInfo(path: path, duration: duration, tags: tags) }
        }

        // Safety: if reading is slow (a network drive, say), show the file name after 2 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.preparingPath == path else { return }
            self.finishInfo(path: path, duration: duration, tags: AdFileTags())
        }
    }

    private func finishInfo(path: String, duration: Double, tags: AdFileTags) {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let info = AdTrackInfo(path: path,
                               title: tags.title.isEmpty ? name : tags.title,
                               artist: tags.artist,
                               album: tags.album,
                               artworkData: tags.artwork,
                               duration: duration)

        if infoCache.count > 20 { infoCache.removeAll() }   // the covers can be big
        infoCache[path] = info

        if preparingPath == path { preparingPath = nil }
        if adActive, player != nil, lastPlayedPath == path { current = info }
    }

    // MARK: - AVAudioPlayerDelegate

    /// A file ended: during an ad, pick the next random one. After a preview, just stop.
    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, finished === self.player else { return }
            self.player = nil
            if self.adActive {
                self.playRandom()
            } else {
                self.previewingPath = nil
            }
        }
    }
}
