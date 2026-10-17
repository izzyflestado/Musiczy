import AppKit

struct SpotifyTrack {
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let isPlaying: Bool
    let position: Double   // seconds played
    let duration: Double   // total seconds
    let isAd: Bool
}

/// Asks Spotify directly for the current track using AppleScript.
enum SpotifyBridge {
    static var lastError = ""

    /// True after macOS refused our Apple events (error -1743). Reset on the next success.
    static var permissionDenied = false

    /// True while an AppleScript call is running. NSAppleScript keeps the run loop
    /// spinning while it waits, so timers could start a second call inside the
    /// first one. This blocks that.
    private static var busy = false

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.spotify.client"
        }
    }

    // MARK: - Running scripts

    /// Compiled scripts, kept so each one is only built once.
    private static var compiled: [String: NSAppleScript] = [:]

    /// Runs one AppleScript. Returns nil if another script is already running.
    private static func run(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?)? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }

        // Seek scripts contain a different number each time, so don't let the cache grow forever.
        if compiled.count > 50 { compiled.removeAll() }

        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let new = NSAppleScript(source: source) else { return nil }
            compiled[source] = new
            script = new
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return (error == nil ? result : nil, error)
    }

    // MARK: - Mute during ads

    /// Spotify's volume from before we silenced it for an ad. nil = we haven't muted it.
    private static var savedVolume: Int?

    /// Sets Spotify's own volume to 0 during an ad, then puts it back.
    /// Only Spotify is affected, not the rest of your Mac's audio.
    static func setAdMuted(_ muted: Bool) {
        guard isRunning else {
            savedVolume = nil
            return
        }

        if muted {
            guard savedVolume == nil else { return }   // already muted
            guard let current = run("tell application id \"com.spotify.client\" to return sound volume")?
                    .result?.int32Value else { return }   // busy or failed: retry next second
            savedVolume = Int(current)
            _ = run("tell application id \"com.spotify.client\" to set sound volume to 0")
        } else if let volume = savedVolume {
            // Only forget the saved volume once the restore really ran.
            guard run("tell application id \"com.spotify.client\" to set sound volume to \(volume)") != nil
            else { return }
            savedVolume = nil
        }
    }
    
    // MARK: - Controls

    /// Sends a command to Spotify: "playpause", "next track" or "previous track".
    static func send(_ command: String) {
        guard isRunning else { return }
        let source = "tell application id \"com.spotify.client\" to \(command)"
        if let error = run(source)?.error {
            print("Spotify command error:", error)
        }
    }

    /// Jumps to a time in the current song (in seconds).
    static func seek(to seconds: Double) {
        guard isRunning, seconds.isFinite else { return }
        let source = "tell application id \"com.spotify.client\" to set player position to \(Int(max(seconds, 0)))"
        if let error = run(source)?.error {
            print("Spotify seek error:", error)
        }
    }

    // MARK: - Reading the current track

    static func currentTrack() -> SpotifyTrack? {
        // Never talk to Spotify if it isn't open, or AppleScript would launch it.
        guard isRunning else { return nil }

        let source = """
        tell application id "com.spotify.client"
            if player state is stopped then return ""
            set t to current track
            return {name of t, artist of t, album of t, artwork url of t, (player state as text), (player position as integer), (duration of t as integer), (spotify url of t)}
        end tell
        """

        // nil means another call is still running: skip this update quietly.
        guard let outcome = run(source) else { return nil }

        if let error = outcome.error {
            lastError = "\(error["NSAppleScriptErrorNumber"] ?? "?"): \(error["NSAppleScriptErrorMessage"] ?? "unknown")"
            permissionDenied = ScriptRunner.isPermissionError(error)
            print("Spotify AppleScript error:", error)
            return nil
        }
        lastError = ""
        permissionDenied = false

        // A stopped player returns an empty string, not a list of 8 items.
        guard let result = outcome.result, result.numberOfItems >= 8 else { return nil }

        // AppleScript lists start at index 1.
        let title      = result.atIndex(1)?.stringValue ?? ""
        let artist     = result.atIndex(2)?.stringValue ?? ""
        let album      = result.atIndex(3)?.stringValue ?? ""
        let urlString  = result.atIndex(4)?.stringValue ?? ""
        let state      = result.atIndex(5)?.stringValue ?? ""
        let position   = Double(result.atIndex(6)?.int32Value ?? 0)         // seconds
        let duration   = Double(result.atIndex(7)?.int32Value ?? 0) / 1000  // ms to seconds
        let spotifyURL = result.atIndex(8)?.stringValue ?? ""

        return SpotifyTrack(
            title: title,
            artist: artist,
            album: album,
            artworkURL: URL(string: urlString),
            isPlaying: state.lowercased().contains("play"),
            position: position,
            duration: duration,
            isAd: spotifyURL.hasPrefix("spotify:ad")
        )
    }
}
