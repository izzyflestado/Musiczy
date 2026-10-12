import AppKit

// MARK: - Shared types

enum PlayerCommand: String {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"
}

/// What every player reports, in one format.
struct PlayerTrack {
    let sourceID: String
    let sourceName: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?      // Spotify gives a URL
    let artworkData: Data?    // other players give raw image data
    let isPlaying: Bool
    let position: Double      // seconds
    let duration: Double      // seconds
    let isAd: Bool
}

protocol PlayerSource: AnyObject {
    var id: String { get }
    var name: String { get }
    var isRunning: Bool { get }
    /// True when macOS refused our Apple events (Automation not allowed yet).
    var permissionDenied: Bool { get }
    func currentTrack() -> PlayerTrack?
    func send(_ command: PlayerCommand)
    func seek(to seconds: Double)
}

// MARK: - The hub (priority order lives here)

enum PlayerHub {
    /// PRIORITY ORDER: top = highest. Reorder or delete lines to change it.
    static let sources: [PlayerSource] = [
        SpotifySource(),
        ScriptPlayer.appleMusic,
        //ScriptPlayer.vlc,
        ScriptPlayer.swinsian,
        ScriptPlayer.vox
    ]

    /// Fallback: whatever macOS says is playing. Lives in SystemNowPlaying.swift.
    static let system = SystemSource()

    /// True when a running player refused our Apple events (error -1743).
    static var permissionDenied: Bool {
        sources.contains { $0.isRunning && $0.permissionDenied }
    }

    private static var busy = false
    private static var active: PlayerSource?

    static func currentTrack() -> PlayerTrack? {
        // NSAppleScript spins the run loop, so block a second scan starting inside the first.
        guard !busy else { return nil }
        busy = true
        defer { busy = false }

        var firstPaused: (source: PlayerSource, track: PlayerTrack)?

        for source in sources where source.isRunning {
            guard let track = source.currentTrack() else { continue }
            if track.isPlaying {
                active = source
                return track
            }
            if firstPaused == nil { firstPaused = (source, track) }
        }

        let systemTrack = system.currentTrack()
        if let t = systemTrack, t.isPlaying { active = system; return t }
        if let p = firstPaused { active = p.source; return p.track }
        if let t = systemTrack { active = system; return t }

        active = nil
        return nil
    }

    /// Controls go to whichever player is currently shown.
    static func send(_ command: PlayerCommand) {
        (active ?? sources.first)?.send(command)
    }

    static func seek(to seconds: Double) {
        (active ?? sources.first)?.seek(to: seconds)
    }
}

// MARK: - Spotify (uses your existing SpotifyBridge, unchanged)

final class SpotifySource: PlayerSource {
    let id = "spotify"
    let name = "Spotify"
    var isRunning: Bool { SpotifyBridge.isRunning }
    var permissionDenied: Bool { SpotifyBridge.permissionDenied }

    func currentTrack() -> PlayerTrack? {
        guard let t = SpotifyBridge.currentTrack() else { return nil }
        return PlayerTrack(sourceID: id, sourceName: name,
                           title: t.title, artist: t.artist, album: t.album,
                           artworkURL: t.artworkURL, artworkData: nil,
                           isPlaying: t.isPlaying, position: t.position,
                           duration: t.duration, isAd: t.isAd)
    }

    func send(_ command: PlayerCommand) { SpotifyBridge.send(command.rawValue) }
    func seek(to seconds: Double) { SpotifyBridge.seek(to: seconds) }
}

// MARK: - AppleScript runner for the other players

enum ScriptRunner {
    /// macOS error -1743: "Not authorized to send Apple events".
    static func isPermissionError(_ error: NSDictionary?) -> Bool {
        (error?["NSAppleScriptErrorNumber"] as? Int) == -1743
    }

    private static var busy = false
    private static var cache: [String: NSAppleScript] = [:]   // compile each script only once

    static func run(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?)? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        if cache.count > 50 { cache.removeAll() }

        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let new = NSAppleScript(source: source) else { return nil }
            cache[source] = new
            script = new
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return (error == nil ? result : nil, error)
    }
}

// MARK: - One generic class for every scriptable player

final class ScriptPlayer: PlayerSource {
    let id: String
    let name: String
    private let bundleID: String
    private let readScript: String        // must return {title, artist, album, "playing"/"paused", position, duration}
    private let artworkScript: String?
    private let durationDivisor: Double   // 1 if the player reports seconds, 1000 for milliseconds
    private let commands: [PlayerCommand: String]
    private let seekText: String

    private var artKey = ""
    private var artData: Data?
    private(set) var permissionDenied = false

    init(id: String, name: String, bundleID: String, readScript: String,
         artworkScript: String? = nil, durationDivisor: Double = 1,
         commands: [PlayerCommand: String], seekText: String) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.readScript = readScript
        self.artworkScript = artworkScript
        self.durationDivisor = durationDivisor
        self.commands = commands
        self.seekText = seekText
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    func currentTrack() -> PlayerTrack? {
        guard isRunning else { return nil }
        guard let outcome = ScriptRunner.run(readScript) else { return nil }
        permissionDenied = ScriptRunner.isPermissionError(outcome.error)
        guard outcome.error == nil,
              let r = outcome.result,
              r.numberOfItems >= 6 else { return nil }

        let title    = r.atIndex(1)?.stringValue ?? ""
        let artist   = r.atIndex(2)?.stringValue ?? ""
        let album    = r.atIndex(3)?.stringValue ?? ""
        let state    = r.atIndex(4)?.stringValue ?? ""
        let position = Double(r.atIndex(5)?.int32Value ?? 0)
        let duration = Double(r.atIndex(6)?.int32Value ?? 0) / durationDivisor
        guard !title.isEmpty else { return nil }

        // Artwork is only fetched when the song changes.
        let key = "\(title)|\(artist)|\(album)"
        if let artScript = artworkScript, key != artKey,
           let artOutcome = ScriptRunner.run(artScript) {
            artKey = key
            if let d = artOutcome.result?.data, d.count > 100 {
                artData = d
            } else {
                artData = nil
            }
        }

        return PlayerTrack(sourceID: id, sourceName: name,
                           title: title, artist: artist, album: album,
                           artworkURL: nil,
                           artworkData: artworkScript != nil ? artData : nil,
                           isPlaying: state.lowercased().contains("play"),
                           position: position, duration: duration, isAd: false)
    }

    func send(_ command: PlayerCommand) {
        guard isRunning, let text = commands[command] else { return }
        _ = ScriptRunner.run("tell application id \"\(bundleID)\" to \(text)")
    }

    func seek(to seconds: Double) {
        guard isRunning, seconds.isFinite else { return }
        _ = ScriptRunner.run("tell application id \"\(bundleID)\" to \(seekText) \(Int(max(seconds, 0)))")
    }
}

// MARK: - The players. Each one is just a script + a few words.

extension ScriptPlayer {
    static let appleMusic = ScriptPlayer(
        id: "music", name: "Apple Music", bundleID: "com.apple.Music",
        readScript: """
        tell application id "com.apple.Music"
            if player state is stopped then return ""
            set t to current track
            set d to 0
            try
                set d to (duration of t as integer)
            end try
            return {name of t, artist of t, album of t, (player state as text), (player position as integer), d}
        end tell
        """,
        artworkScript: """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """,
        commands: [.playPause: "playpause", .next: "next track", .previous: "previous track"],
        seekText: "set player position to")

    // GUESS: written from memory of VLC's dictionary. Gives no artist, album or artwork.
    static let vlc = ScriptPlayer(
        id: "vlc", name: "VLC", bundleID: "org.videolan.vlc",
        readScript: """
        tell application id "org.videolan.vlc"
            set s to "paused"
            if playing then set s to "playing"
            return {name of current item, "", "", s, (current time as integer), (duration of current item as integer)}
        end tell
        """,
        commands: [.playPause: "play", .next: "next", .previous: "previous"],
        seekText: "set current time to")

    // GUESS: assumes Swinsian's dictionary matches iTunes/Music. No artwork yet.
    static let swinsian = ScriptPlayer(
        id: "swinsian", name: "Swinsian", bundleID: "com.swinsian.Swinsian",
        readScript: """
        tell application id "com.swinsian.Swinsian"
            if player state is stopped then return ""
            set t to current track
            return {name of t, artist of t, album of t, (player state as text), (player position as integer), (duration of t as integer)}
        end tell
        """,
        commands: [.playPause: "playpause", .next: "next track", .previous: "previous track"],
        seekText: "set player position to")

    // GUESS: the least certain one. VOX's terms are from memory. No artwork yet.
    static let vox = ScriptPlayer(
        id: "vox", name: "VOX", bundleID: "com.coppertino.Vox",
        readScript: """
        tell application id "com.coppertino.Vox"
            set s to "paused"
            if player state is 1 then set s to "playing"
            return {track, artist, album, s, (current time as integer), (total time as integer)}
        end tell
        """,
        commands: [.playPause: "playpause", .next: "next track", .previous: "previous track"],
        seekText: "set current time to")
}
