#<p align="center">
  <img src="Media/logo.png" alt="Multimail_logo" width="100">
</p>

<h1 align="center">Musiczy</h1>

<br>

A music visualizer for macOS with synced lyrics, several styles, plus a lock screen option.

Musiczy reads what is playing from Spotify, Apple Music and a few other players (also support browser playback), shows the cover art on a blurred full-screen background, scrolls time-synced lyrics, and lets you control playback with the mouse or keyboard.

## Preview
![Musiczy Screenshot](Media/Untitled%20design.png)


## Download
Grab the latest [Musiczy.dmg](https://github.com/izzyflestado/Musiczy/releases/download/V1.0.0/Musiczy.dmg) from the [Releases page](https://github.com/izzyflestado/Musiczy/releases).

1. Open the DMG and drag Musiczy into Applications.
2. Open Musiczy from Applications.
3. If macOS says the app can't be opened because it is from an unidentified developer, right-click the app, choose Open, then confirm. You can also go to System Settings > Privacy & Security and click Open Anyway.

## Features

- **Full-screen player.** Large cover art, title / artist / album, a seekable progress bar and play / previous / next controls over a blurred, colour-boosted copy of the cover.
- **Synced lyrics.** The current line is highlighted and scrolls with the song. Click a line to jump to it; scroll to browse (it snaps back to the current line after 3 seconds).
- **Three display styles.** Press the active *Art* or *Lyrics* button again to cycle: normal, full-screen HD cover, and full-screen HD cover with a bottom bar.
- **Lock-screen card.** When the Mac locks, a small glass card with the cover and title floats above the lock screen. Hover to expand it (progress bar and controls), click the cover to go full-screen with lyrics.
- **Muted ads.** Mute Spotify when playing ads then returns to original volume after finishing.
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


## First launch and permissions

macOS asks for permission the first time Musiczy talks to Spotify or Music: "Musiczy wants access to control Spotify". Click OK.

If you click Don't Allow, Musiczy shows a hint on the placeholder screen. Fix it in System Settings > Privacy & Security > Automation and tick the player under Musiczy. To bring the prompt back: 

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
| Quit | The ✕ button|

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

## Known bugs

- Visual bug on lock screen - Unblurred glow effect on lock screen.
- Visual bug during ads
- Visual bug - Sometimes does not switch cover art when changing songs (might do this if tabbed out).

## Known limitations

- Uses private macOS APIs (SkyLight for the lock-screen window, MediaRemote for the system fallback). A macOS update can break them.
- The lock-screen card is created on the main display only.
- Players are polled once per second through AppleScript.

## Roadmap

- [ ] Add mode state: Option to make blurred background black with animated shine on border mode
- [ ] Fix: Detert cover art for alternate file for ad
- [x] Add option: Select display style on settings with preview
- [x] Add feature: Option to replace lock screen wallpaper with cover art
- [x] Add feature: Select file to play during ads
- [x] Add feature: Menu bar icon and option
- [x] Add branding: Logo
- [x] Add feature: Mute music during adds

## Credits & acknowledgement 

- [LRCLIB](https://lrclib.net) for free synced lyrics
- [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter), a fork of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) to detect system media.
- [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) for locked screen display
