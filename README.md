# Lyripeek

A lightweight macOS menu-bar app that shows time-synced lyrics for the music you're currently playing.

## Screenshots

<img width="459" height="462" alt="image" src="https://github.com/user-attachments/assets/7c64c96c-4a88-4007-80c0-91824796b7f1" />

https://github.com/user-attachments/assets/8e129347-866d-49d7-8ca0-7c0ddc0b4cb1

## Features

- **Menu-bar lyrics** – see the current line right in the macOS menu bar.
- **Two-line mode** – show both the current and next lyric line in the menu bar, toggled from the popover footer.
- **Works with any app in Control Center** – reads the system-wide `MPNowPlayingInfoCenter` (the same source the macOS Control Center Now Playing widget uses), so any app that publishes now-playing info works automatically — VLC, Safari, Podcasts, Audible, and more.
- **Enriched for Spotify, Apple Music, and Kaset** – for these apps, an AppleScript overlay refines the live `position` and shows a clean source label. Adding more players is a single `PlayerSource` file.
- **Friendly source labels** – the active publisher's app name is shown in the popover subtitle (e.g. "Album • Spotify", "Album • VLC").
- **LRCLIB integration** – fetches synced LRC lyrics from [lrclib.net](https://lrclib.net) using exact lookup (album + duration) with a search fallback.
- **Media playback controls** – Previous Track, Play/Pause, and Next Track buttons in the popover.
- **Manual lyrics scrolling** – scroll through lyrics freely; a floating Sync button re-snaps to the current line.
- **Offset adjustment** – fine-tune lyric timing with a native input field and ± buttons (200 ms steps).
- **Launch at login** – optional toggle in the right-click context menu.
- **Update checker** – checks GitHub releases daily at 22:00 and shows a download button when a new version is available.
- **Adaptive polling** – polls at 1 Hz while music is playing, drops to 5 s when idle to reduce CPU and battery usage.
- **Disk-persisted artwork** – album artwork cached under `~/Library/Caches` with a 200-image LRU eviction cap.
- **Debug raw info** – standalone window with tabs for Now Playing metadata, AppleScript output, and raw LRC source.

## Install

**Requires macOS 14.0+**

Download the latest `Lyripeek.dmg` from the [Releases](../../releases) page, then:

1. Open the DMG and drag `Lyripeek.app` into the **Applications** folder shortcut inside the window.
2. Eject the DMG.
3. **Required.** Open Terminal and run the following to clear the quarantine attribute. Without this, macOS will show a "Lyripeek is damaged and can't be opened" error. This happens because the app is not signed with an Apple Developer ID, so macOS Gatekeeper blocks it by default:

   ```bash
   xattr -cr /Applications/Lyripeek.app
   ```

4. Launch the app from Finder (or `open /Applications/Lyripeek.app`). It appears as a music-note icon in the menu bar.

On first launch macOS will prompt you to allow Lyripeek to send AppleEvents to other apps (Spotify, Apple Music, Kaset) for the enriched source experience. Click **OK** to grant access.

## Usage

1. Start playing music in any app that appears in the macOS Control Center **Now Playing** widget.
2. Lyripeek detects the track and fetches synced lyrics.
3. The current lyric line appears in the menu bar (or both current and next line if two-line mode is enabled).
4. Open the popover to see surrounding lines, control playback, and adjust timing with the **Offset** control.
5. Scroll through lyrics manually — tap the **Sync** button to re-snap to the current line.
6. Right-click the menu-bar icon to toggle **Launch at Login**.

> **Note:** Lyripeek uses AppleScript to talk to Spotify, Apple Music, and Kaset for an enriched experience (fresher position, cleaner source label). All other publishers work via the system Now Playing service. Make sure apps are allowed to be scripted when prompted.

## Architecture

- `LyripeekApp.swift` – app entry point and `AppDelegate`; wires up services.
- `StatusBarController.swift` – manages the `NSStatusItem`, menu-bar title, lyrics popover, and context menu.
- `CrossfadeStatusView.swift` – custom `NSView` for the menu-bar status item with animated crossfade and two-line support.
- `NowPlayingService.swift` – actively-playing scan orchestrator; prefers a non-paused `MPNowPlayingInfoCenter` track, then iterates known `PlayerSource`s, then falls back to a paused system track. Runs adaptive polling (1 Hz playing, 5 s idle).
- `Services/MediaRemoteClient.swift` – loads the private `MediaRemote.framework` via `dlsym`; provides running-app detection and playback command routing.
- `Services/ArtworkService.swift` – fetches album artwork from the iTunes Search API; caches in memory and on disk (`~/Library/Caches/Lyripeek/Artwork/`) with a 200-image LRU cap.
- `Services/UpdateService.swift` – checks GitHub for newer releases daily at 22:00 (with launch-time catch-up); compares semver tags and exposes a download URL.
- `Services/LoginItemService.swift` – thin wrapper around `SMAppService.mainApp` for launch-at-login registration.
- `PlayerSources/PlayerSource.swift` – protocol every provider implements.
- `PlayerSources/SystemNowPlayingPlayerSource.swift` – the always-on system fallback.
- `PlayerSources/SpotifyPlayerSource.swift` – AppleScript enrichment for Spotify.
- `PlayerSources/AppleMusicPlayerSource.swift` – AppleScript enrichment for Apple Music.
- `PlayerSources/KasetPlayerSource.swift` – JSON-based AppleScript enrichment for [Kaset](https://github.com/sozercan/kaset).
- `LyricsService.swift` – loads and caches LRC lyrics from LRCLIB; applies user offset; exposes `nextLineText` for two-line mode.
- `LRCParser.swift` – parses LRC timestamp tags into `LyricLine` structs.
- `SyncEngine.swift` – binary search for the active lyric line at a given time.
- `Views/NowPlayingCard.swift` – hero card with album artwork, track metadata, progress bar, and transport controls.
- `Views/TransportControls.swift` – Previous / Play-Pause / Next buttons routed through `NowPlayingService.sendPlaybackCommand`.
- `Views/SyncedLyricsView.swift` – Apple Music-style synced lyrics with auto-scroll, manual scroll detection, and a floating Sync button.
- `Views/PopoverFooter.swift` – bottom control strip with offset stepper, two-line toggle, refetch button, and debug/info button.
- `Views/DebugWindow.swift` – standalone window with Now Playing, AppleScript, Raw LRC, and About (update checker) tabs.

## Build from Source

**Requires Xcode 17+ and Swift 5.**

Open `Lyripeek.xcodeproj` in Xcode and run the **Lyripeek** scheme, or build from the command line:

```bash
xcodebuild -project Lyripeek.xcodeproj -scheme Lyripeek -destination 'platform=macOS' build
```

The app runs as a menu-bar item. Click the music-note icon to open the lyrics popover.

To produce a distributable `Lyripeek-<version>.dmg` instead, run:

```bash
./scripts/build-dmg.sh
```

The DMG is written to `dist/`. The script uses only stock macOS tools (`xcodebuild`, `hdiutil`, `osascript`, `ditto`) — no Homebrew or other dependencies required.

## License

[MIT](LICENSE)
