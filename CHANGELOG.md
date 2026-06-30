# Changelog

## [0.2.0] - 2026-06-30

### Added

- 🎛️ Media playback controls in the popover (Previous Track, Play/Pause, Next Track)
- 📝 Two-line mode for menu bar lyrics — shows current and next line, toggled from the popover footer
- 🔐 Launch-at-login support via the context menu
- 🔔 Update checker that checks GitHub releases daily at 22:00, with a download button and red-dot badge
- ✋ Manual lyrics scrolling with a floating Sync button to resume auto-scroll
- 💾 Disk-persisted artwork cache with 200-image LRU eviction under `~/Library/Caches`

### Changed

- 🔧 Migrated from deprecated `statusItem.view` to button embedding with Auto Layout
- 🔧 Lyrics and artwork caches moved from `~/Library/Application Support` to `~/Library/Caches` so macOS can purge them under disk pressure and Time Machine skips them
- 🔧 LRCLIB lyrics fetch now tries exact `/api/get` (album + duration) first, falling back to search
- 🔧 iTunes artwork fetch gated on system artwork presence — skipped when the system already provides it
- 🔧 Adaptive now-playing polling: 1 Hz while a track is playing, drops to 5 s when idle to reduce CPU and battery usage
- 🔧 LRC timestamp regex cached at file level instead of recompiled on every call

### Fixed

- 🐛 Debug window no longer leaks a new `NSWindow` when reopened
- 🐛 Removed duplicate `updateCurrentLine` calls when the popover was open

## [0.1.0] - 2026-06-27

### Added

- 🎵 Initial release: time-synced menu-bar lyrics for the currently playing track
- 📊 Status bar popover with surrounding lyric lines and a ± offset control for fine-tuning
- ✨ Custom menu-bar view with animated crossfade and right alignment
- 💾 Lyric offset is remembered between launches
- 📂 Lyric cache stored on disk, with a reset button in the popover
- 🎧 Generalized now-playing support — works with Spotify, Apple Music, VLC, Safari, Podcasts, and any app that publishes to the system Now Playing service
- ⏱️ Smoother now-playing progress: 10 Hz interpolation with drift correction so the active lyric line stays in sync
- 📦 DMG installer with a drag-to-Applications layout for easier installation

### Changed

- 🔧 Source label moved into the popover card subtitle (the standalone "now playing from" view was removed)
- 🔧 Publisher detection rewritten to scan for the actively playing source at query time, instead of using a static priority list
- 🔧 DMG window resized and icon dimensions reduced for a more compact installer layout

### Removed

- 🗑️ Demo mode and the mock lyric fallback (only real LRCLIB lyrics are shown now)
