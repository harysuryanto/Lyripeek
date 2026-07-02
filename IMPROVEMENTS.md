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
3. **Item C** (debounce offset writes) — small, low risk
4. **Item F** (`@MainActor` annotation) — medium refactor
5. **Item G** (split side effects) — small refactor, do last

## Commit style

Use Conventional Commits format:
```
type: short description
```
Examples:
- `perf: hoist currentIndex to avoid redundant binary searches in SyncedLyricsView`
- `perf: move orderedSources computation inside Layer 3 block`
- `perf: debounce offset UserDefaults writes to reduce disk I/O`
- `refactor: annotate NowPlayingService as @MainActor`
- `refactor: extract side effects from SystemNowPlayingPlayerSource.currentTrack()`

## Verification

After each change, run:
```bash
xcodebuild -project Lyripeek.xcodeproj -scheme Lyripeek -destination 'platform=macOS' build
```
The build must succeed with zero new warnings.
