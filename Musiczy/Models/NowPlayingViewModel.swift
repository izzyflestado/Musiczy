import AppKit
import SwiftUI
import Combine

final class NowPlayingViewModel: ObservableObject {
    static let shared = NowPlayingViewModel()
    @Published var song = Song(title: "Nothing playing",
                               artist: "Open a music player and press play",
                               album: "",
                               artwork: nil)
    @Published var progress: Double = 0   // 0.0 to 1.0
    @Published var isPlaying = false
    @Published var position: Double = 0   // seconds played
    @Published var duration: Double = 0   // total seconds
    @Published var lyrics: [LyricLine] = []
    @Published var currentLyricIndex = -1
    @Published var animateProgress = true
    @Published var hiResArtwork: NSImage?
    private var lastHiResURL: URL?
    private let hiResSession = URLSession(configuration: .ephemeral)
    var wantsHiRes = false
    private var currentCoverURL: URL?
    private var timer: Timer?
    @Published var isAd = false
    var pausePollingUntil = Date.distantPast
    var positionStamp = Date()   // when `position` was last set
    private var showingAdFile = false                // true while the ad music is what the screen shows
    private var adMusicObserver: AnyCancellable?
    
    private var lastTrackKey = ""
    private var currentArtwork: NSImage?
    private var lastArtworkURL: URL?
    private let detector = NowPlayingDetector()
    
    init() {
        // Wait until SwiftUI has finished creating the view before touching @Published values.
        DispatchQueue.main.async { [weak self] in
            self?.startDetecting()
        }
    }
    
    private func startDetecting() {
        detector.onUpdate = { [weak self] _ in
            self?.refresh()
        }
        detector.start()
        
        // When the ad music changes (a new file, or its name and cover finished loading), update right away.
                adMusicObserver = AdAudioPlayer.shared.$current
                    .dropFirst()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.refresh() }
        
        // Also check right now, in case a song is already playing.
        refresh()
        // Check once per second so the progress bar moves.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    
    /// Reads the current track from whichever player has priority and updates the main screen.
    func refresh() {
        guard Date() >= pausePollingUntil else { return }

        guard let reported = PlayerHub.currentTrack() else {
            AdAudioPlayer.shared.trackLost()
            updateIdleHint()
            return
        }

        SpotifyBridge.setAdMuted(reported.isAd)
        AdAudioPlayer.shared.update(isAd: reported.isAd, isPlaying: reported.isPlaying)

        // The ad file's name and cover are still loading (a few milliseconds): wait for them.
        if reported.isAd, AdAudioPlayer.shared.isPreparing { return }

        // During an ad, show the ad music instead, like a normal song.
        let track = adMusicTrack(replacing: reported) ?? reported
        showingAdFile = track.sourceID == AdAudioPlayer.sourceID

        isPlaying = track.isPlaying
        isAd = track.isAd
        
        // Update the progress bar (runs every second, before the song-change check)
        let newProgress = track.duration > 0
            ? min(max(track.position / track.duration, 0), 1)
            : 0
        // Big jumps (new song, ad, seek) snap instantly; normal ticks glide.
        animateProgress = abs(newProgress - progress) < 0.05
        progress = newProgress
        position = track.position
        positionStamp = Date()
        duration = track.duration
        updateLyricIndex()
        
        // Only update the screen when the song actually changes
        // (not on every pause/play).
        let key = "\(track.sourceID)|\(track.title)|\(track.artist)|\(track.album)"

        // Same song, but the cover arrived late: add it now.
        if key == lastTrackKey, song.artwork == nil,
           let data = track.artworkData, let image = NSImage(data: data) {
            currentArtwork = image
            song = Song(title: song.title, artist: song.artist,
                        album: song.album, artwork: image)
            return
        }

        guard key != lastTrackKey else { return }
        lastTrackKey = key
        currentCoverURL = track.artworkURL
        if wantsHiRes {
            loadHiRes(from: track.artworkURL)
        } else if track.artworkURL != lastHiResURL {
            // Song changed to a different cover: drop the old HD one.
            hiResArtwork = nil
            lastHiResURL = nil
        }
        // New song: clear old lyrics and look up the new ones.
        lyrics = []
        currentLyricIndex = -1
        let gotLyrics: ([LyricLine]) -> Void = { [weak self] lines in
            guard let self, self.lastTrackKey == key else { return }
            self.lyrics = lines
            self.updateLyricIndex()
        }
        if showingAdFile, let path = AdAudioPlayer.shared.current?.path {
            // The ad music: we know the exact file, so look next to it.
            LyricsService.fetchForFile(URL(fileURLWithPath: path), title: track.title,
                                       artist: track.artist, duration: track.duration,
                                       completion: gotLyrics)
        } else {
            LyricsService.fetchLocalFirst(title: track.title, artist: track.artist,
                                          duration: track.duration, completion: gotLyrics)
        }
        
        // Artwork that came as raw image data (Apple Music and other non-Spotify players).
        if let data = track.artworkData, let image = NSImage(data: data) {
            lastArtworkURL = nil
            currentArtwork = image
            song = Song(title: track.title, artist: track.artist,
                        album: track.album, artwork: image)
            fetchLocalHD(title: track.title, artist: track.artist, key: key)
            return
        }
        
        // No artwork available: show the text only.
        guard let url = track.artworkURL else {
            song = Song(title: track.title, artist: track.artist,
                        album: track.album, artwork: nil)
            fetchLocalHD(title: track.title, artist: track.artist, key: key)
            return
        }
        
        // Same artwork as before (e.g. next song on the same album): reuse it.
        if url == lastArtworkURL, let art = currentArtwork {
            song = Song(title: track.title, artist: track.artist,
                        album: track.album, artwork: art)
            return
        }
        
        // New artwork: download it, then update everything together
        // so the text and picture change at the same moment.
        lastArtworkURL = url
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self, self.lastTrackKey == key else { return }
                
                if let data, let image = NSImage(data: data) {
                    self.currentArtwork = image
                    self.song = Song(title: track.title, artist: track.artist,
                                     album: track.album, artwork: image)
                } else {
                    // Download failed: show text only and allow a retry later.
                    self.lastArtworkURL = nil
                    self.song = Song(title: track.title, artist: track.artist,
                                     album: track.album, artwork: nil)
                }
            }
        }.resume()
    }
    
    /// When nothing is playing, the placeholder text normally says to press play.
    /// If macOS has refused our Apple events, it says how to fix that instead.
    private func updateIdleHint() {
        guard song.title == "Nothing playing" else { return }
        let wanted = PlayerHub.permissionDenied
            ? "Allow Musiczy to control your music player in System Settings > Privacy & Security > Automation"
            : "Open a music player and press play"
        if song.artist != wanted {
            song = Song(title: song.title, artist: wanted, album: "", artwork: nil)
        }
    }

    /// Downloads a bigger copy of the cover for the full-screen view (Spotify only).
    private func loadHiRes(from url: URL?) {
        guard let url else { hiResArtwork = nil; return }
        guard url != lastHiResURL else { return }
        lastHiResURL = url
        hiResArtwork = nil

        let bigString = url.absoluteString
            .replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d000082c1")
        guard let big = URL(string: bigString), big != url else { return }

        hiResSession.dataTask(with: big) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, self.lastHiResURL == url else { return }
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                if ok, let data, let image = NSImage(data: data) {
                    self.hiResArtwork = image
                }
            }
        }.resume()
    }
    
    func setWantsHiRes(_ on: Bool) {
        wantsHiRes = on
        // Turning it off keeps the HD cover. It's only cleared when the song changes.
        if on { loadHiRes(from: currentCoverURL) }
    }
    
    /// For non-Spotify songs: finds the HD cover online. If offline or no match, the embedded cover stays.
    private func fetchLocalHD(title: String, artist: String, key: String) {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = c.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8

        hiResSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return }

            let a = artist.lowercased(), t = title.lowercased()
            let match = results.first {
                let ra = ($0["artistName"] as? String ?? "").lowercased()
                let rt = ($0["trackName"] as? String ?? "").lowercased()
                let artistOK = a.isEmpty || (!ra.isEmpty && (ra.contains(a) || a.contains(ra)))
                return !rt.isEmpty && artistOK && (rt.contains(t) || t.contains(rt))
            }
            guard let small = match?["artworkUrl100"] as? String,
                  let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
            else { return }

            self.hiResSession.dataTask(with: big) { [weak self] data, response, _ in
                DispatchQueue.main.async {
                    guard let self, self.lastTrackKey == key,
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let data, let image = NSImage(data: data) else { return }
                    self.currentArtwork = image
                    self.hiResArtwork = image
                    self.song = Song(title: self.song.title, artist: self.song.artist,
                                     album: self.song.album, artwork: image)
                }
            }.resume()
        }.resume()
    }
    
    // MARK: - Lyrics
    
    /// Picks the lyric line that matches the current playback time.
    private func updateLyricIndex() {
        let now = position + 0.5   // players report whole seconds, so nudge forward
        var index = -1
        for (i, line) in lyrics.enumerated() where line.time <= now {
            index = i
        }
        if index != currentLyricIndex { currentLyricIndex = index }
    }
    
    var currentLyric: String {
        guard currentLyricIndex >= 0, currentLyricIndex < lyrics.count else { return "" }
        return lyrics[currentLyricIndex].text
    }
    
    var nextLyric: String {
        let i = currentLyricIndex + 1
        guard i >= 0, i < lyrics.count else { return "" }
        return lyrics[i].text
    }
    
    // MARK: - Controls (go to whichever player is shown)
    
    func playPause() {
        PlayerHub.send(.playPause)
        refreshSoon()
    }
    
    func nextTrack() {
        if showingAdFile {
            AdAudioPlayer.shared.skipToNext()      // another random ad file
        } else {
            PlayerHub.send(.next)
        }
        refreshSoon()
    }
    
    func previousTrack() {
        if showingAdFile {
            AdAudioPlayer.shared.restart()         // start the ad file again
        } else {
            PlayerHub.send(.previous)
        }
        refreshSoon()
    }
    
    /// Seeks to a point in the song, from 0.0 (start) to 1.0 (end).
    func seek(toFraction fraction: Double) {
        guard duration > 0, !isAd else { return }
        let f = min(max(fraction, 0), 1)
        position = f * duration
        positionStamp = Date()
        progress = f
        updateLyricIndex()
        seekPlayer(to: position)
        refreshSoon()
    }
    
    /// Jumps to a specific time in the song (used by tapping a lyric line).
    func seek(toTime seconds: Double) {
        guard duration > 0, !isAd else { return }
        // Round up: players take whole seconds, and rounding down would land on the previous line.
        let t = min(ceil(seconds), duration)
        position = t
        positionStamp = Date()
        progress = t / duration
        updateLyricIndex()
        seekPlayer(to: t)
        refreshSoon()
    }
    
    /// While an ad plays and the ad music is playing, describes the ad music as a normal track.
    private func adMusicTrack(replacing ad: PlayerTrack) -> PlayerTrack? {
        guard ad.isAd, let file = AdAudioPlayer.shared.current else { return nil }
        return PlayerTrack(sourceID: AdAudioPlayer.sourceID, sourceName: "Ad music",
                           title: file.title, artist: file.artist, album: file.album,
                           artworkURL: nil, artworkData: file.artworkData,
                           isPlaying: ad.isPlaying,
                           position: AdAudioPlayer.shared.position,
                           duration: file.duration, isAd: false)
    }

    /// Seeks whatever the screen is showing: the ad music during an ad, otherwise the music player.
    private func seekPlayer(to seconds: Double) {
        if showingAdFile {
            AdAudioPlayer.shared.seek(to: seconds)
        } else {
            PlayerHub.seek(to: seconds)
        }
    }
    
    /// Gives the player a moment to react, then updates the screen.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
    }
}
