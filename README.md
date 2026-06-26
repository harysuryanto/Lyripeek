# Lyripeek

A lightweight macOS menu-bar app that shows time-synced lyrics for the music you're currently playing.

## Screenshots

<img width="451" height="454" alt="Screenshot 2026-06-26 at 11 20 17" src="https://github.com/user-attachments/assets/b66e3435-6245-422d-b711-2df78bab4495" />

https://github.com/user-attachments/assets/8e129347-866d-49d7-8ca0-7c0ddc0b4cb1

## Features

- **Menu-bar lyrics** – see the current line right in the macOS menu bar.
- **Works with any app in Control Center** – reads the system-wide `MPNowPlayingInfoCenter` (the same source the macOS Control Center Now Playing widget uses), so any app that publishes now-playing info works automatically — VLC, Safari, Podcasts, Audible, and more.
- **Enriched for Spotify, Apple Music, and Kaset** – for these apps, an AppleScript overlay refines the live `position` and shows a clean source label. Adding more players is a single `PlayerSource` file.
- **Friendly source labels** – the active publisher's app name is shown in the popover subtitle (e.g. "Album • Spotify", "Album • VLC").
- **LRCLIB integration** – fetches synced LRC lyrics from [lrclib.net](https://lrclib.net).
- **Offline fallback** – shows a short mock lyric set when no synced lyrics are available.
- **Offset adjustment** – fine-tune lyric timing with a native input field and ± buttons (200 ms steps).
- **Demo mode** – simulate playback to test the UI when no music app is running.
- **Debug raw info** – inspect parsed player metadata, raw `MPNowPlayingInfoCenter` data, and the AppleScript output from each registered source.

## Requirements

- macOS 15.0+
- Xcode 17+
- Swift 5

## Install

Download the latest `Lyripeek.app.zip` from the [Releases](../../releases) page, then:

1. Unzip and drag `Lyripeek.app` into the `/Applications` folder.
2. Open Terminal and run the following to clear the quarantine attribute. Lyripeek is not signed with an Apple Developer ID because the developer is not enrolled in the Apple Developer Program, so macOS Gatekeeper would otherwise block the app:

   ```bash
   xattr -cr /Applications/Lyripeek.app
   ```

3. Launch the app from Finder (or `open /Applications/Lyripeek.app`). It appears as a music-note icon in the menu bar.

On first launch macOS will prompt you to allow Lyripeek to send AppleEvents to other apps (Spotify, Apple Music, Kaset) for the enriched source experience. Click **OK** to grant access.

## Build & Run

Open `Lyripeek.xcodeproj` in Xcode and run the **Lyripeek** scheme, or build from the command line:

```bash
xcodebuild -project Lyripeek.xcodeproj -scheme Lyripeek -destination 'platform=macOS' build
```

The app runs as a menu-bar item. Click the music-note icon to open the lyrics popover.

## Usage

1. Start playing music in any app that appears in the macOS Control Center **Now Playing** widget.
2. Lyripeek detects the track and fetches synced lyrics.
3. The current lyric line appears in the menu bar.
4. Open the popover to see surrounding lines and adjust timing with the **Offset** control if needed.

> **Note:** Lyripeek uses AppleScript to talk to Spotify, Apple Music, and Kaset for an enriched experience (fresher position, cleaner source label). All other publishers work via the system Now Playing service. Make sure apps are allowed to be scripted when prompted.

## Architecture

- `LyripeekApp.swift` – app entry point and `AppDelegate`; wires up services.
- `StatusBarController.swift` – manages the `NSStatusItem`, menu-bar title, and lyrics popover.
- `NowPlayingService.swift` – actively-playing scan orchestrator: prefers a non-paused `MPNowPlayingInfoCenter` track, then iterates known `PlayerSource`s (in frontmost-app-priority order) for the first one that is actively playing, then falls back to a paused system track. No static priority list gates track selection.
- `Services/MediaRemoteClient.swift` – loads the private `MediaRemote.framework` via `dlsym` and falls back to `NSWorkspace.shared.runningApplications` to identify the active publisher. The MediaRemote PID getter is known to crash on unprivileged clients and is intentionally not called; the public `NSWorkspace` scan is the reliable path.
- `PlayerSources/PlayerSource.swift` – protocol every provider implements.
- `PlayerSources/SystemNowPlayingPlayerSource.swift` – the always-on system fallback.
- `PlayerSources/SpotifyPlayerSource.swift` – AppleScript enrichment for Spotify.
- `PlayerSources/AppleMusicPlayerSource.swift` – AppleScript enrichment for Apple Music.
- `PlayerSources/KasetPlayerSource.swift` – JSON-based AppleScript enrichment for [Kaset](https://github.com/sozercan/kaset).
- `LyricsService.swift` – loads and caches LRC lyrics from LRCLIB; applies user offset.
- `LRCParser.swift` – parses LRC timestamp tags into `LyricLine` structs.
- `SyncEngine.swift` – binary search for the active lyric line at a given time.
- `ContentView.swift` – SwiftUI popover UI.

## License

[MIT](LICENSE)
