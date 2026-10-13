# Musiczy

A music visualizer for macOS with synced lyrics, several styles, plus a lock screen option.

Musiczy reads what is playing from Spotify, Apple Music and a few other players (also support browser playback), shows the cover art on a blurred full-screen background, scrolls time-synced lyrics, and lets you control playback with the mouse or keyboard.


## Preview
https://drive.google.com/file/d/1EoHRKORs2U1u0m3Dt28Tpa9JiY31hlql/view?usp=sharing

## Features

- **Full-screen player.** Large cover art, title / artist / album, a seekable progress bar and play / previous / next controls over a blurred, colour-boosted copy of the cover.
- **Synced lyrics.** The current line is highlighted and scrolls with the song. Click a line to jump to it; scroll to browse (it snaps back to the current line after 3 seconds).
- **Three display styles.** Press the active *Art* or *Lyrics* button again to cycle: normal, full-screen HD cover, and full-screen HD cover with a bottom bar.
- **Lock-screen card.** When the Mac locks, a small glass card with the cover and title floats above the lock screen. Hover to expand it (progress bar and controls), click the cover to go full-screen with lyrics.
- **HD artwork.** Spotify covers are swapped for a larger version; for other players Musiczy looks up a high-resolution cover through the iTunes Search API and falls back to the embedded one.
- **Multiple players.** See the table below. A player that is *playing* always wins over one that is only paused.
- **Idle mode.** After 3 seconds without mouse movement the cursor, buttons and controls fade out.

## Supported players

| Player (Priority) | How it is read | Status |
| --- | --- | --- |
| 1. Spotify | AppleScript | Works. Ads are detected: the title is hidden, lyrics are hidden and seeking is disabled. |
| 2. Apple Music | AppleScript (includes embedded artwork) | Works. |
| 3. Anything else | macOS "Now Playing" via [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter) | Fallback. Relies on private macOS APIs, so it may stop working after a macOS update. |


## Requirements

- macOS 14 (Sonoma) or later. The code uses SwiftUI APIs introduced in macOS 14.
- Xcode 15 or later.
- Not sandboxed (it uses AppleScript, runs `mdfind` and reads files next to your songs), so it is not set up for the Mac App Store.

## Build and run

### Option A: XcodeGen (quickest)

```sh
brew install xcodegen
xcodegen generate
open Musiczy.xcodeproj
```

Then pick your Team under *Signing & Capabilities* and press Run.

### Option B: set the project up by hand in Xcode

1. Create a new **macOS > App** project (SwiftUI, Swift), deployment target macOS 14.0.
2. Delete the template source files and drag the `.swift` files (keep the sub-folders) and `Assets.xcassets` from the `Musiczy/` folder into the project, ticking "Copy items if needed" and your target. Don't add `Info.plist` or the `.entitlements` file as target members; step 4 points the build settings at them instead.
3. *File > Add Package Dependencies*, then add both:
   - `https://github.com/ejbills/mediaremote-adapter.git` (branch `master`, product `MediaRemoteAdapter`)
   - `https://github.com/Lakr233/SkyLightWindow` (from `1.0.0`)
4. In the target's *Build Settings*: set **Swift Language Version** to Swift 5, **Info.plist File** to `Musiczy/Info.plist`, **Code Signing Entitlements** to `Musiczy/Musiczy.entitlements`.
5. In *Signing & Capabilities*, make sure **App Sandbox is not enabled**.
6. Build and run.

The project was not compiled in the environment where it was edited (no macOS toolchain available), so if Xcode reports a package product name mismatch, check the exact product names in the package list and adjust `project.yml` or the target's dependencies.

## First launch and permissions

macOS asks for permission the first time Musiczy talks to Spotify or Music: *"Musiczy wants access to control Spotify"*. Click **OK**.

If you click *Don't Allow*, Musiczy shows a hint on the placeholder screen. Fix it in **System Settings > Privacy & Security > Automation** and tick the player under Musiczy. To bring the prompt back:

```sh
tccutil reset AppleEvents com.izzyflestado.musiczy
```

## Using it

| Action | How |
| --- | --- |
| Play / pause | `Space`, or the play button |
| Previous / next | `←` / `→`, or the buttons |
| Seek | Click or drag the progress bar, or click a lyric line |
| Browse lyrics | Scroll; clicking empty space returns to the current line |
| Switch Art / Lyrics | The two buttons (for with-lyrics and art-only) above the cover. Press the active one again to change the display style |
| Window buttons | Move the mouse to the top edge. Red quits, green toggles full-screen / windowed |
| Quit | The ✕ button, the red window button, or closing the window |

Musiczy must already be running when you lock the Mac for the lock-screen card to appear, and it only shows once a song has been detected.

## How lyrics are found

For every new song, in this order:

1. A `.lrc` file next to the audio file (the file is located with Spotlight).
2. [LRCLIB](https://lrclib.net): an exact lookup by title, artist and length, then a search that accepts a result within 3 seconds of the song's length.
3. Synced lyrics embedded in a local FLAC file (`SYNCEDLYRICS` or `LYRICS` tag).

Lyrics that look like junk (too few lines, mostly empty, or the same line repeated) are rejected. Lines longer than 38 characters are split and the timing is shared between the pieces (`LyricsService.maxChars`).

## Network and privacy

Musiczy makes network requests only to:

- `lrclib.net` for lyrics (sends title, artist and song length)
- `itunes.apple.com` for HD covers of non-Spotify songs (sends artist and title)
- Spotify's image servers, for Spotify cover art

There is no account, analytics or tracking.


## Known limitations

- Uses private macOS APIs (SkyLight for the lock-screen window, MediaRemote for the system fallback). A macOS update can break them.
- The lock-screen card is created on the main display only.
- Players are polled once per second through AppleScript.

## Credits & acknowledgement 

- [LRCLIB](https://lrclib.net) for free synced lyrics
- [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter), a fork of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) to detect system media.
- [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) for locked screen display
