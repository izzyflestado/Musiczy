import Foundation

/// A simple summary of what a media app told us.
struct DetectedTrack: Equatable {
    let source: String   // "Spotify" or "Apple Music"
    let state: String    // "Playing", "Paused", "Stopped"
    let title: String
    let artist: String
    let album: String
}

/// Listens for the playback notifications that Spotify and Apple Music
/// broadcast through macOS (public API: DistributedNotificationCenter).
final class NowPlayingDetector {
    var onUpdate: ((DetectedTrack) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()

        let spotify = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handle(note, source: "Spotify")
        }

        let music = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handle(note, source: "Apple Music")
        }

        observers = [spotify, music]
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func handle(_ note: Notification, source: String) {
        guard let info = note.userInfo else { return }

        let track = DetectedTrack(
            source: source,
            state:  info["Player State"] as? String ?? "Unknown",
            title:  info["Name"]   as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album:  info["Album"]  as? String ?? ""
        )
        onUpdate?(track)
    }
}
