import AppKit
import MediaRemoteAdapter

/// Fallback: reads whatever macOS says is playing, via the MediaRemote adapter.
/// Everything adapter-related lives in THIS file only.
/// If macOS blocks it, `failed` turns on and this source quietly returns nothing.
final class SystemSource: PlayerSource {
    let id = "system"
    let name = "System"

    /// Set to false to switch the whole system source off.
    static let isEnabled = true

    private let controller = MediaController()
    private var latest: TrackInfo?
    private var started = false
    private var failed = false
    private var artKey = ""
    private var artData: Data?

    var isRunning: Bool { Self.isEnabled && !failed }
    var permissionDenied: Bool { false }

    private func startIfNeeded() {
        guard Self.isEnabled, !started else { return }
        started = true
        controller.onTrackInfoReceived = { [weak self] info in
            DispatchQueue.main.async { self?.latest = info }
        }
        controller.onListenerTerminated = { [weak self] in
            DispatchQueue.main.async {
                self?.failed = true
                self?.latest = nil
            }
        }
        controller.startListening()
    }

    func currentTrack() -> PlayerTrack? {
        guard Self.isEnabled, !failed else { return nil }
        startIfNeeded()

        guard let p = latest?.payload,
              let title = p.title, !title.isEmpty else { return nil }

        let artist = p.artist ?? ""
        let album = p.album ?? ""
        let playing = p.isPlaying ?? ((p.playbackRate ?? 0) > 0)

        // Convert the artwork once per song (not every second). Cover often arrives late, so retry while empty.
        let key = "\(title)|\(artist)|\(album)"
        if key != artKey || (artData == nil && p.artwork != nil) {
            artKey = key
            artData = p.artwork?.tiffRepresentation
        }

        return PlayerTrack(sourceID: id, sourceName: name,
                           title: title, artist: artist, album: album,
                           artworkURL: nil, artworkData: artData,
                           isPlaying: playing,
                           position: p.currentElapsedTime ?? 0,
                           duration: (p.durationMicros ?? 0) / 1_000_000,
                           isAd: false)
    }

    func send(_ command: PlayerCommand) {
        guard Self.isEnabled, !failed else { return }
        switch command {
        case .playPause: controller.togglePlayPause()
        case .next:      controller.nextTrack()
        case .previous:  controller.previousTrack()
        }
    }

    func seek(to seconds: Double) {
        guard Self.isEnabled, !failed, seconds.isFinite else { return }
        controller.setTime(seconds: seconds)
    }
}
