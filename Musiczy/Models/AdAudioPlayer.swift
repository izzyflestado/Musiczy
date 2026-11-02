import AVFoundation
import Combine

extension SettingsKey {
    static let adFilePaths = "adFilePaths"
    static let adFilePath = "adFilePath"     // old single-file key, only used to carry your old choice over
    static let adVolume = "adVolume"
}

/// Plays random files from the user's list while Spotify is playing an ad.
final class AdAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AdAudioPlayer()

    /// The files the user added, in the order they were added.
    @Published private(set) var paths: [String] = []
    /// The file being previewed from Settings (nil = no preview).
    @Published private(set) var previewingPath: String?

    private var player: AVAudioPlayer?
    private var lastPlayedPath = ""
    private var failed = Set<String>()        // files that could not be opened, so we don't retry every second
    private var adActive = false
    private var lastAdTick = Date.distantPast

    private var volume: Float {
        Float(UserDefaults.standard.object(forKey: SettingsKey.adVolume) as? Double ?? 0.8)
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
        save()
    }

    func removeAll() {
        stopSound()
        paths = []
        failed.removeAll()
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

    func applyVolume() {
        player?.volume = volume
    }

    // MARK: - Helpers

    private func save() {
        UserDefaults.standard.set(paths, forKey: SettingsKey.adFilePaths)
    }

    private func stopSound() {
        player?.stop()
        player = nil
        previewingPath = nil
    }

    /// Picks a random file (never the same one twice in a row, if there are others) and plays it.
    private func playRandom() {
        let usable = paths.filter {
            !failed.contains($0) && FileManager.default.fileExists(atPath: $0)
        }
        guard !usable.isEmpty else { return }

        let pool = usable.count > 1 ? usable.filter { $0 != lastPlayedPath } : usable
        guard let pick = pool.randomElement() else { return }

        if !start(pick) {
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
