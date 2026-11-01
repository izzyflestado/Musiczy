import SwiftUI
import Combine

/// The song the lock screen shows (cover, glow, title, artist).
/// Normally it follows the player at once. While the Mac is locked and the wallpaper
/// option is on, a new song waits until its wallpaper is in place, so the card and the
/// wallpaper change at the same moment.
final class LockSongGate: ObservableObject {
    static let shared = LockSongGate()

    // ===== TIMING: change these numbers =====
    /// Seconds to wait after the wallpaper is set, before the card starts to change.
    /// Raise it if the card changes BEFORE the wallpaper, lower it if it changes after.
    static let wallpaperLead: Double = 0.25
    /// The card never waits longer than this many seconds.
    static let maxWait: Double = 3.0
    // ========================================

    @Published private(set) var song: Song

    private var pending: Song?
    private var readyKey: String?
    private var timeout: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        song = NowPlayingViewModel.shared.song
    }

    /// The text used to recognise a song (WallpaperManager uses the same one).
    static func key(_ song: Song) -> String {
        "\(song.title)|\(song.artist)|\(song.album)"
    }

    func start() {
        guard cancellables.isEmpty else { return }

        NowPlayingViewModel.shared.$song
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.songChanged($0) }
            .store(in: &cancellables)

        // Unlocking shows the newest song at once.
        LockScreenController.shared.$isLocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                guard !locked else { return }
                self?.readyKey = nil
                self?.release()
            }
            .store(in: &cancellables)

        // So does opening the full-screen lock view (the wallpaper is hidden behind it).
        LockScreenController.shared.$isFullscreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] full in
                if full { self?.release() }
            }
            .store(in: &cancellables)
    }

    /// Called by WallpaperManager once the wallpaper for this song is in place.
    func wallpaperReady(key: String) {
        readyKey = key
        guard let p = pending, Self.key(p) == key else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wallpaperLead) { [weak self] in
            guard let self, let p = self.pending, Self.key(p) == key else { return }
            self.release()
        }
    }

    // MARK: - Helpers

    private func songChanged(_ new: Song) {
        guard shouldHold(new) else {
            clearPending()
            song = new
            return
        }

        pending = new
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.release() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxWait, execute: work)
    }

    /// Only a NEW song on the small lock card, with the wallpaper option on, is held back.
    private func shouldHold(_ new: Song) -> Bool {
        let lock = LockScreenController.shared
        return lock.isLocked
            && !lock.isFullscreen
            && UserDefaults.standard.bool(forKey: SettingsKey.replaceLockWallpaper)
            && new.artwork != nil
            && Self.key(new) != Self.key(song)
            && Self.key(new) != readyKey          // its wallpaper is already in place
    }

    private func release() {
        timeout?.cancel()
        timeout = nil
        guard let p = pending else { return }
        pending = nil
        song = p
    }

    private func clearPending() {
        timeout?.cancel()
        timeout = nil
        pending = nil
    }
}
