# Changelog

## [0.4.0] - 2026-07-08
### ✨ Added
- Dedicated Update button in the popover footer for easier access to new versions.
- Optimized popover layout for a more polished experience.

### 🐛 Fixed
- Backward elapsed time jumps caused by player polling lag.

### 🔧 Changed
- Update button now opens the release page in your browser instead of downloading directly.

## [0.3.0] - 2026-07-07
### ✨ Added
- Smooth lyric line transitions and word-by-word highlighting animations.
- Word-by-word lyrics in the menu bar.
- Playback seeking support directly from the app, including tap-to-seek on lyrics.
- Smart lyric search: automatically falls back to alternative providers if the main one fails.
- Support for displaying unsynced lyrics when synced versions are unavailable.
- Alternative lyric provider (Lyrica) as a fallback.
- Lyric provider attribution at the bottom of the lyrics list.
- High-resolution album artwork specifically for Kaset.
- Hidden scrollbar in the lyrics list for a cleaner interface.
- Aligned progress bar slider with time indicators and increased their text size.

### 🐛 Fixed
- Lyric timing precision by flooring the elapsed time instead of rounding.
- Lyric micro-stuttering by smoothing the time interpolation.
- Flickering lyrics caused by synchronization issues with macOS duration reporting.
- Song information disappearing when playback is paused.
- Empty state indicator in the menu bar to a friendlier "Lyrics not found".
- Spacing issues in the menu bar when the text is empty.

### 🔧 Changed
- Overall application performance improvements by reducing search and disk write operations.

## [0.2.0] - 2026-06-30
### ✨ Added
- Manual lyrics scrolling. Scrolling pauses auto-scroll; a floating "Sync" button re-aligns lyrics to the song.
- Media playback controls (Play/Pause, Previous, Next) inside the popover.
- Two-line mode in the menu bar to view the current and next lyric lines simultaneously (with the next line dimmed).
- Automatic daily update checker with a download button in settings.
- Option to automatically launch Lyripeek when your Mac starts (Open at Login).

### 🐛 Fixed
- Memory leak caused by repeatedly opening and closing the debug window.

### 🔧 Changed
- Intelligent LRU caching for album artwork and lyrics to conserve disk space.
- Highly accurate LRCLIB lyric searches that account for both album name and song duration.
- Conserves battery and network usage by reusing macOS system artwork instead of re-downloading it.
- Significantly reduced CPU and battery drain when no music apps are actively playing.

## [0.1.0] - 2026-06-27
### ✨ Added
- Initial release of Lyripeek: A smooth menu bar lyrics app.
- System-wide music detection via macOS Now Playing.
- Advanced automatic detection for Apple Music, Spotify, and Kaset.
- Instant, precise lyrics from LRCLIB.
- Beautiful, translucent popover design native to macOS.
- Indicator shown when more than two music players are active at once.
- Real-time lyrics that animate to the rhythm with 10Hz updates.
- Lyric offset/delay adjustment that persists across sessions.
- Runs entirely in the background without cluttering your Dock.

### 🔧 Changed
- Dynamic music player detection strategy prioritizes the most active, frontmost music app.

### 🗑️ Removed
- Demo mode and test lyrics used during early development.
