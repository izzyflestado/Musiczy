import AVFoundation
import Combine

extension SettingsKey {
    static let adFilePath = "adFilePath"
    static let adVolume = "adVolume"
}

/// Plays the user's chosen sound file while Spotify is playing an ad.
final class AdAudioPlayer: ObservableObject {
    static let shared = AdAudioPlayer()

    /// True while the Preview button in Settings is playing the file.
    @Published private(set) var isPreviewing = false

    private var player: AVAudioPlayer?
    private var loadedPath = ""
    private var failedPath = ""            // a file that could not be opened, so we don't retry every second
    private var adActive = false
    private var lastAdTick = Date.distantPast

    private var filePath: String {
        UserDefaults.standard.string(forKey: SettingsKey.adFilePath) ?? ""
    }

    private var volume: Float {
        Float(UserDefaults.standard.object(forKey: SettingsKey.adVolume) as? Double ?? 0.8)
    }

    // MARK: - Called from NowPlayingViewModel.refresh() (once per second)

    func update(isAd: Bool, isPlaying: Bool) {
        if isAd {
            adActive = true
            lastAdTick = Date()
            if isPlaying {
                guard load() else { return }
                player?.volume = volume
                if player?.isPlaying == false { player?.play() }
            } else {
                player?.pause()            // ad paused: pause the file too
            }
        } else if adActive {
            adActive = false
            stop()
        }
    }

    /// Called when no track could be read. Stops the sound if that lasts 4 seconds
    /// (for example, Spotify was closed during an ad).
    func trackLost() {
        guard adActive, Date().timeIntervalSince(lastAdTick) > 4 else { return }
        adActive = false
        stop()
    }

    // MARK: - Used by the Settings window

    func togglePreview() {
        if isPreviewing {
            stop()
        } else if load() {
            player?.volume = volume
            player?.play()
            isPreviewing = true
        }
    }

    func stopPreview() {
        if isPreviewing { stop() }
    }

    func applyVolume() {
        player?.volume = volume
    }

    // MARK: - Helpers

    private func stop() {
        player?.stop()
        player?.currentTime = 0
        isPreviewing = false
    }

    /// Opens the chosen file (again, if the choice changed). Returns false if there is nothing to play.
    private func load() -> Bool {
        let path = filePath
        guard !path.isEmpty, path != failedPath else { return false }
        if player != nil, loadedPath == path { return true }
        guard FileManager.default.fileExists(atPath: path) else { return false }

        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.numberOfLoops = -1           // loop until the ad is over
            p.prepareToPlay()
            player = p
            loadedPath = path
            return true
        } catch {
            print("Ad audio error:", error)
            player = nil
            loadedPath = ""
            failedPath = path
            return false
        }
    }
}
