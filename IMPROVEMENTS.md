# Lyripeek Performance & Quality Improvements — Remaining Work

## Project overview

Lyripeek is a lightweight macOS menu-bar app that displays synced lyrics from multiple player sources (Spotify, Apple Music, Kaset, system Now Playing). The app must stay energy-efficient since it runs as a menu-bar accessory.

**Key constraints:**
- Swift 5.0, deployment target macOS 14.0
- Uses Swift concurrency (async/await), Combine, AppKit (no SwiftUI app lifecycle for the menu-bar logic)
- Single Xcode target: `Lyripeek` app — **no test target exists yet**

**Repository:** `github.com:harysuryanto/Lyripeek`

---

## Completed items (DO NOT redo)

| # | Commit | Description |
|---|--------|-------------|
| 1 | `2a9df48` | Adaptive now-playing polling (1 Hz active / 5 s idle, NSWorkspace launch notification, `deinit` cleanup) — `NowPlayingService.swift` |
| 2 | `290b528` | Cache LRC timestamp regex as file-private `let` — `LRCParser.swift` |
| 3 | `1505df4` | Fix debug window leak (reuse existing `NSWindow`) — `DebugWindow.swift` |
| 4 | `92f137b` | Remove duplicate `updateCurrentLine` calls when popover is open — `SyncedLyricsView.swift`, `LyripeekApp.swift` |
| 5 | `e2d256d` | Gate iTunes artwork fetch on system artwork presence — `LyripeekApp.swift` |
| 6 | `31a929f` | Use LRCLIB exact `/api/get` with album+duration, fall back to `/api/search` — `LyricsService.swift` |
| 7 | `828a7c9` | Persist lyrics + artwork under `~/Library/Caches/` with 200-image LRU cap — `LyricsService.swift`, `ArtworkService.swift` |

---

## Remaining items to implement

### Item A: Hoist `currentIndex` in `SyncedLyricsView` (trivial, ~5 lines)

**File:** `Lyripeek/Views/SyncedLyricsView.swift`

**Problem:** `currentIndex` is a computed property (lines 16–21) that calls `currentLineIndex(lines:currentTime:)` every time it's accessed. It is evaluated **at least 5 times per body re-render** at 10 Hz:
- Line 80: `.animation(.easeInOut(duration: 0.35), value: currentIndex)`
- Line 82: `.onChange(of: currentIndex) { _, newIndex in`
- Lines 118–121: inside `lyricLineView()`, called once per `ForEach` iteration — `isCurrent = index == currentIndex`, `distance = abs(index - currentIndex)`, `index < currentIndex`
- Line 180: inside `scrollToCurrent`

Each access re-runs the binary search over the full lyrics array.

**Fix:** At the top of `lyricsList` (or the view body), compute `currentIndex` once into a local `let`:
```swift
let currentIndex = currentLineIndex(
    lines: lyricsService.lines,
    currentTime: nowPlayingService.elapsedTime - lyricsService.offset
)
```
Then pass this single value through to all call sites. This avoids 4+ redundant binary searches per render cycle.

**Note:** The `currentIndex` computed property is currently `private var` at line 16. You can either:
1. Replace the body to use a local `let` and remove the computed property, OR
2. Keep the computed property but add a `@State` that caches it and updates via `.onChange(of: nowPlayingService.elapsedTime)`

Option 1 (local `let`) is simpler and preferred.

---

### Item B: Move `orderedSources` inside Layer 3 block (trivial, ~3 lines)

**File:** `Lyripeek/NowPlayingService.swift`

**Problem:** In `refresh()` (lines 272–369), `orderedSources` is computed at lines 283–295 via a closure that iterates `enrichmentSources` and partitions by frontmost bundle ID. But it is **only used inside the `if resolvedTrack == nil` block** (line 310–321). When Layer 2 succeeds (system track is playing and not paused), the computation is wasted.

**Fix:** Move the `orderedSources` closure + invocation (lines 283–295) to inside the `if resolvedTrack == nil {` block, right before the `for source in orderedSources` loop.

---

### Item C: Debounce `offset` UserDefaults writes (~8 lines)

**File:** `Lyripeek/LyricsService.swift`

**Problem:** The `offset` published property (line 25) has a `didSet` (line 28–30) that writes to `UserDefaults` on every assignment:
```swift
@Published var offset: TimeInterval {
    didSet {
        UserDefaults.standard.set(offset, forKey: Self.offsetDefaultsKey)
    }
}
```
When the user drags the offset slider in the popover, this fires on every slider tick (potentially 10+ times per second), writing to disk each time.

**Fix:** Debounce the UserDefaults write. Replace the immediate `didSet` write with a debounced write:

```swift
private static var offsetWriteWork = DispatchWorkItem()

@Published var offset: TimeInterval {
    didSet {
        Self.offsetWriteWork.cancel()
        Self.offsetWriteWork = DispatchWorkItem {
            UserDefaults.standard.set(self.offset, forKey: Self.offsetDefaultsKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: Self.offsetWriteWork)
    }
}
```

**Important:** The `offset` is also read from UserDefaults in `init()` (line 35). The debounce only affects writes, not reads, so this is safe.

---

### Item D: Stable gradient hash in `NowPlayingCard` (~8 lines)

**File:** `Lyripeek/Views/NowPlayingCard.swift`

**Problem:** Lines 141–142 in `ArtworkTile.gradient`:
```swift
let hash = abs(seed.hashValue)
let pair = palette[hash % palette.count]
```
`String.hashValue` is randomized per process launch (Swift SE-0206). This means the same track gets a different gradient palette every time the app restarts. For a menu-bar app that relaunches frequently, this is visually inconsistent.

**Fix:** Replace `String.hashValue` with a deterministic hash function. Add a helper (e.g., in a private extension or inline):

```swift
/// Deterministic hash (FNV-1a) so the same track always gets the same gradient.
private func stableHash(_ s: String) -> Int {
    var hash: UInt64 = 14695981039346656037 // FNV offset basis
    for byte in s.utf8 {
        hash ^= UInt64(byte)
        hash *= 1099511628211 // FNV prime
    }
    return Int(bitPattern: hash)
}
```

Then replace line 141:
```swift
let hash = abs(stableHash(seed))
```

**Note:** `ArtworkService.swift` already has a similar comment at line 126 about `String.hashValue` being randomized. You can reuse the same approach there if desired, though the artwork cache key uses a different slugify function already.

---

### Item E: Add unit test target and tests (medium effort, highest long-term value)

**Current state:** The Xcode project (`project.pbxproj`) has a single native target: `Lyripeek` app. No test target exists. No test files exist.

**Steps:**

1. **Create a test target** in the Xcode project. You can either:
   - Add it via Xcode UI (File → New → Target → macOS Unit Testing Bundle), OR
   - Manually add a `PBXNativeTarget` entry to `project.pbxproj` with a `XCTest` dependency. The test target should be named `LyripeekTests` and depend on the `Lyripeek` app target.

2. **Create test file:** `LyripeekTests/SyncEngineTests.swift` — test the `currentLineIndex` function.

   **Function under test:** `Lyripeek/SyncEngine.swift:18`
   ```swift
   func currentLineIndex(lines: [LyricLine], currentTime: TimeInterval) -> Int
   ```

   **Edge cases to test:**
   - Empty lines array → returns 0
   - Single line → returns 0
   - `currentTime` before first line → returns 0
   - `currentTime` exactly at a line timestamp → returns that line's index
   - `currentTime` between two lines → returns the earlier line's index
   - Seek backward (currentTime goes from line 3 back to line 1) → returns line 1
   - Tied timestamps (two lines with same timestamp) → returns the later one (or earlier, depending on implementation — verify and document)
   - Fractional timestamps (e.g., `[00:01.50]`) → handled correctly

3. **Create test file:** `LyripeekTests/LRCParserTests.swift` — test `parseLRC`.

   **Function under test:** `Lyripeek/LRCParser.swift:32`
   ```swift
   func parseLRC(_ lrc: String) -> [LyricLine]
   ```

   **Edge cases to test:**
   - Empty string → returns empty array
   - Single line with timestamp → returns one `LyricLine`
   - Multiple lines in order → sorted correctly
   - Fractional timestamps (`[01:23.45]`) → parsed correctly
   - Malformed timestamps (e.g., `[XX:XX]`) → skipped or handled
   - Lines without timestamps → skipped or treated as 0
   - Metadata tags (`[ti:Song]`, `[ar:Artist]`) → skipped (not treated as lyrics)
   - Windows-style line endings (`\r\n`) → handled
   - Trailing newline → no extra empty line

4. **Create test file:** `LyripeekTests/SpotifyPlayerSourceTests.swift` — test `parse`.

   **Function under test:** `Lyripeek/PlayerSources/SpotifyPlayerSource.swift:73`
   ```swift
   static func parse(output: String, source: String, bundleIdentifier: String?) -> DesktopTrack?
   ```

   **Edge cases to test:**
   - Valid JSON with all fields → returns `DesktopTrack`
   - Empty string → returns nil
   - Malformed JSON → returns nil
   - Missing required fields (e.g., no `kSpPlayerName`) → returns nil
   - Zero duration → returns `DesktopTrack` with `duration == 0`
   - Special characters in title/artist → preserved correctly

5. **Create test file:** `LyripeekTests/LyricsServiceTests.swift` — test `cacheKey` (requires making it `internal` instead of `private`, or test via reflection).

   **Function under test:** `Lyripeek/LyricsService.swift:265`
   ```swift
   private func cacheKey(title: String, artist: String, album: String) -> String
   ```

   **Edge cases to test:**
   - Consistency: same inputs → same key across calls
   - Different titles → different keys
   - Different artists → different keys
   - Different albums → different keys
   - Empty strings → valid key (no crash)
   - Unicode characters → valid key

   **Note:** Since `cacheKey` is `private`, you have two options:
   - Change it to `internal` (remove `private`) — acceptable for testing
   - Test indirectly through `loadLyrics` with mocked network — more complex, skip for now

---

### Item F: Mark `NowPlayingService` `@MainActor` (medium effort, Swift 6 readiness)

**File:** `Lyripeek/NowPlayingService.swift`

**Current state:** Class declaration at line 45:
```swift
final class NowPlayingService: ObservableObject {
```
No `@MainActor` annotation. The class has 5 manual `MainActor.run` / `.main` scheduler hops:
- Line 169: `Timer.publish(every: 0.1, on: .main, in: .common)` — 10 Hz tick timer
- Line 194: `queue: .main` — NSWorkspace notification observer
- Line 222: `await MainActor.run { ... }` — reads `lastActiveAt`
- Line 256: `await MainActor.run { self?.restartPollingForLaunch() }` — after `sendPlaybackCommand`
- Lines 329–368: `await MainActor.run { ... }` — bulk `@Published` property updates

**Fix:**
1. Add `@MainActor` to the class declaration:
   ```swift
   @MainActor
   final class NowPlayingService: ObservableObject {
   ```
2. Remove all 5 manual `MainActor.run` / `.main` scheduler hops — they become redundant since the class is now isolated to `@MainActor`.
3. Verify that all callers of `NowPlayingService` methods are compatible (they should be, since most callers are already on `@MainActor` or use `await`).

**Risk:** This is a larger refactor. If `refresh()` is called from a non-main-actor context, adding `@MainActor` to the class means `refresh()` will also be isolated to `@MainActor`, which could affect the async polling loop. Test thoroughly.

---

### Item G: Split `SystemNowPlayingPlayerSource` side effects (small, design clarity)

**File:** `Lyripeek/PlayerSources/SystemNowPlayingPlayerSource.swift`

**Current state:** `currentTrack()` (lines 25–59) has 3 side effects that write to instance state:
- Line 27: `rawNowPlayingInfo = info`
- Line 28: `lastOutput = ...`
- Line 30: `systemArtwork = Self.makeImage(from: ...)`

These side effects are then read by `NowPlayingService.refresh()` at lines 276 and 330.

**Fix:** Extract the side effects into a separate method or return type:

Option A — Return a tuple/struct:
```swift
struct SystemTrackResult {
    let track: DesktopTrack?
    let rawInfo: [String: Any]
    let artwork: NSImage?
}

func currentTrackWithMetadata() async -> SystemTrackResult {
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    let artwork = Self.makeImage(from: info[MPMediaItemPropertyArtwork])
    // ... parse track ...
    return SystemTrackResult(track: track, rawInfo: info, artwork: artwork)
}
```

Option B — Keep `currentTrack()` clean and add separate methods:
```swift
func fetchRawInfo() -> [String: Any] { ... }
func fetchArtwork() -> NSImage? { ... }
```

**Risk:** Low. The side effects are only consumed by `NowPlayingService.refresh()`, so the refactoring surface is small. But verify that no other code reads `rawNowPlayingInfo` or `systemArtwork` directly.

---

## Implementation order

1. **Item A** (hoist `currentIndex`) — trivial, no risk, immediate CPU savings
2. **Item B** (move `orderedSources`) — trivial, no risk
3. **Item D** (stable gradient hash) — trivial, cosmetic improvement
4. **Item C** (debounce offset writes) — small, low risk
5. **Item E** (unit tests) — highest long-term value, do this before larger refactors
6. **Item F** (`@MainActor` annotation) — medium refactor, do after tests are in place
7. **Item G** (split side effects) — small refactor, do last

## Commit style

Use Conventional Commits format:
```
type: short description
```
Examples:
- `perf: hoist currentIndex to avoid redundant binary searches in SyncedLyricsView`
- `perf: move orderedSources computation inside Layer 3 block`
- `perf: debounce offset UserDefaults writes to reduce disk I/O`
- `fix: use deterministic hash for artwork gradient seed`
- `test: add unit tests for LRCParser, SyncEngine, SpotifyPlayerSource, LyricsService`
- `refactor: annotate NowPlayingService as @MainActor`
- `refactor: extract side effects from SystemNowPlayingPlayerSource.currentTrack()`

## Verification

After each change, run:
```bash
xcodebuild -project Lyripeek.xcodeproj -scheme Lyripeek -destination 'platform=macOS' build
```
The build must succeed with zero new warnings.

For tests (Item E), run:
```bash
xcodebuild -project Lyripeek.xcodeproj -scheme Lyripeek -destination 'platform=macOS' test
```
