# Lyripeek

A lightweight macOS menu-bar app that shows time-synced lyrics for the music you're currently playing.

## Screenshots

<img width="451" height="454" alt="Screenshot 2026-06-26 at 11 20 17" src="https://github.com/user-attachments/assets/b66e3435-6245-422d-b711-2df78bab4495" />

https://github.com/user-attachments/assets/8e129347-866d-49d7-8ca0-7c0ddc0b4cb1

## Features

- **Menu-bar lyrics** – see the current line right in the macOS menu bar.
- **Desktop player support** – reads the now-playing track from **Spotify** and **Apple Music** via AppleScript.
- **LRCLIB integration** – fetches synced LRC lyrics from [lrclib.net](https://lrclib.net).
- **Offline fallback** – shows a short mock lyric set when no synced lyrics are available.
- **Offset adjustment** – fine-tune lyric timing with a native input field and ± buttons (200 ms steps).
- **Demo mode** – simulate playback to test the UI when no music app is running.
- **Debug raw info** – inspect parsed player metadata and raw LRC source.

## Requirements

- macOS 15.0+
- Xcode 17+
- Swift 5

## Build & Run

Open `Lyripeek.xcodeproj` in Xcode and run the **Lyripeek** scheme, or build from the command line:

```bash
xcodebuild -project Lyripeek.xcodeproj -scheme Lyripeek -destination 'platform=macOS' build
```

The app runs as a menu-bar item. Click the music-note icon to open the lyrics popover.

## Usage

1. Start playing music in **Spotify** or **Apple Music**.
2. Lyripeek detects the track and fetches synced lyrics.
3. The current lyric line appears in the menu bar.
4. Open the popover to see surrounding lines and adjust timing with the **Offset** control if needed.

> **Note:** Lyripeek uses AppleScript to talk to Spotify and Apple Music. Make sure the apps are allowed to be scripted when prompted.

## Architecture

- `LyripeekApp.swift` – app entry point and `AppDelegate`; wires up services.
- `StatusBarController.swift` – manages the `NSStatusItem`, menu-bar title, and lyrics popover.
- `NowPlayingService.swift` – polls desktop players and `MPNowPlayingInfoCenter` for track/playback state.
- `LyricsService.swift` – loads and caches LRC lyrics from LRCLIB; applies user offset.
- `LRCParser.swift` – parses LRC timestamp tags into `LyricLine` structs.
- `SyncEngine.swift` – binary search for the active lyric line at a given time.
- `ContentView.swift` – SwiftUI popover UI.

## License

[MIT](LICENSE)
