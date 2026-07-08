//
//  NowPlayingService.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import AppKit
import Combine
import Foundation
import MediaPlayer

/// Observes the system's currently playing media via three layers:
///
/// 1. **System layer** — `MPNowPlayingInfoCenter` is the always-on primary
///    source. Any app that publishes to the macOS Now Playing service (the
///    same one Control Center's Now Playing widget uses) works here.
/// 2. **Publisher detection** — `MediaRemoteClient` (private `MediaRemote`
///    framework, `dlsym`-loaded with graceful fallback) reports the bundle id
///    of the app currently publishing, so we can label unknown apps with a
///    friendly name and pick a matching `PlayerSource` for enrichment.
/// 3. **Enrichment overlay** — for known apps (Spotify, Apple Music, Kaset)
///    we run their AppleScript to overlay a fresh `position` and explicit
///    source name on top of the system data. The system data is never
///    replaced — enrichment is additive.
///
/// `elapsedTime` is published with two enhancements on top of the raw source
/// value:
///
/// - **Interpolation**: a 10 Hz tick recomputes `elapsedTime` as
///   `lastReportedElapsed + (now - lastReportedAt) * playbackRate`, so the
///   progress bar and lyric highlight move smoothly between source polls
///   instead of stepping in 1-second jumps.
/// - **Jitter smoothing**: on every 1 Hz source poll, the tiny fluctuation
///   in the reported player position (caused by AppleScript/OS execution
///   overhead) is absorbed into a `driftOffset` rather than applied directly.
///   This keeps `elapsedTime` perfectly monotonic — preventing the small
///   backward/forward jumps that would cause lyric lines to flicker. Genuine
///   seeks (> 0.5 s difference) bypass smoothing and snap immediately.
/// - **Adaptive polling**: the source-data poll runs at 1 Hz while a track
///   is playing and drops to a 5 s idle cadence once no track has been
///   playing for ~5 s, so the app stays quiet when idle. AppleScript
///   enrichment is additionally gated on the target app actually running,
///   so no `osascript` subprocess is spawned when no supported music app is
///   open. A `NSWorkspace` launch observer wakes the poll immediately when a
///   known music app starts.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var sourceDescription: String = ""
    @Published private(set) var sourceBundleIdentifier: String? = nil
    @Published private(set) var artwork: NSImage?
    @Published private(set) var rawNowPlayingInfo: [String: Any] = [:]
    @Published private(set) var lastAppleScriptError: String = ""
    @Published private(set) var lastSpotifyOutput: String = ""
    @Published private(set) var lastAppleMusicOutput: String = ""
    @Published private(set) var lastKasetOutput: String = ""
    @Published private(set) var lastParsedElapsedTime: TimeInterval = 0
    @Published private(set) var lastParsedDuration: TimeInterval = 0
    /// True while the resolved track is actively playing (rate > 0). Bound to
    /// the popover's play/pause button so the icon stays in sync with the
    /// underlying player.
    @Published private(set) var isPlaying: Bool = false

    /// Emitted whenever the playing track (title + artist) changes.
    var trackChangedPublisher: AnyPublisher<(title: String, artist: String, album: String, duration: TimeInterval, artworkURL: String?), Never> {
        trackChangedSubject.eraseToAnyPublisher()
    }

    /// True when there is a resolved track the transport controls can act on.
    /// Drives the disabled state of the play/pause/prev/next buttons; the app
    /// has no queue visibility, so we can't distinguish "has next" from "no
    /// next" — we enable all three while a track is active and let the source
    /// app no-op when there's nothing to skip to.
    var hasActiveTrack: Bool {
        !title.isEmpty || !artist.isEmpty
    }

    /// Exposed for the debug window so it can iterate the registry.
    let systemSource: SystemNowPlayingPlayerSource
    let spotifySource: SpotifyPlayerSource
    let appleMusicSource: AppleMusicPlayerSource
    let kasetSource: KasetPlayerSource

    private var enrichmentSources: [PlayerSource] {
        [spotifySource, appleMusicSource, kasetSource]
    }

    // MARK: - Interpolation state

    /// The source-app-reported elapsed time captured at the moment of the last
    /// poll. Serves as the baseline for wall-clock interpolation between polls.
    private var lastReportedElapsed: TimeInterval = 0
    /// Wall-clock timestamp of when `lastReportedElapsed` was captured.
    /// Set to `.distantPast` initially and after `clearTrack` so the 10 Hz
    /// tick guard skips interpolation before the first poll completes.
    private var lastReportedAt: Date = .distantPast
    /// `playbackRate` of the last source read; `0` when paused (which makes
    /// the tick a no-op so the progress bar freezes).
    private var lastReportedRate: Double = 0

    /// A one-shot correction offset added to the interpolated elapsed time.
    ///
    /// On every 1 Hz source poll during normal playback, the raw player
    /// position reported by the source may differ slightly from the local
    /// wall-clock expectation due to AppleScript or OS execution latency.
    /// Rather than snapping `elapsedTime` to the raw value (which causes
    /// visible backward/forward jitter in the lyric highlight), we set:
    ///
    ///   `driftOffset = expected − track.elapsedTime`
    ///
    /// so that at the moment of the poll `elapsedTime` stays exactly at
    /// `expected` (no jump), and subsequent 10 Hz ticks advance it smoothly:
    ///
    ///   `displayed = newLastReportedElapsed + Δt × rate + driftOffset`
    ///   `         = track.elapsedTime + Δt × rate + (expected − track.elapsedTime)`
    ///   `         = expected + Δt × rate`   ← perfectly continuous
    ///
    /// The offset is reset to 0 on pause, track change, resume, or a detected
    /// seek (|diff| > 0.5 s). It is intentionally a simple scalar — it does
    /// NOT accumulate across polls (see `applyTrack` for the proof).
    private var driftOffset: TimeInterval = 0

    // MARK: - Seek protection state
    private var lastSeekAt: Date? = nil
    private var lastSeekTarget: TimeInterval = 0

    // MARK: - Poll cadence state

    /// Keep polling at `activeIntervalSeconds` while a non-paused track has
    /// been applied within this window. Bridges brief gaps (track ends →
    /// next track starts) and bounds pause→resume detection for an
    /// already-running app.
    private static let activeCooldownSeconds: TimeInterval = 5.0
    /// Poll cadence while active (within `activeCooldownSeconds` of a play).
    private static let activeIntervalSeconds: TimeInterval = 1.0
    /// Poll cadence once idle. Cold-start responsiveness when a music app
    /// launches is handled by the `didLaunchApplicationNotification`
    /// observer, so this only bounds "app running, user presses play"
    /// detection.
    private static let idleIntervalSeconds: TimeInterval = 5.0
    /// Maximum |diff| (source time − wall-clock expectation) that is treated
    /// as pure AppleScript/OS jitter and suppressed entirely. When the diff
    /// is this small, re-anchoring the interpolation baseline would only
    /// introduce a micro-stutter on the very next 10 Hz tick; the running
    /// interpolator is already accurate enough to skip the update.
    private static let jitterToleranceSeconds: TimeInterval = 0.05

    /// Wall-clock time of the last non-paused `applyTrack`. Drives
    /// `currentPollInterval()`: while within `activeCooldownSeconds` of this
    /// timestamp the loop polls at `activeIntervalSeconds`, otherwise at
    /// `idleIntervalSeconds`. Intentionally not reset by `clearTrack` so the
    /// cooldown naturally bridges track gaps.
    private var lastActiveAt: Date = .distantPast

    /// The cooperative source-poll loop. Cancelling it (via
    /// `restartPollingForLaunch` or `deinit`) interrupts any in-flight
    /// `Task.sleep` so the next iteration begins promptly.
    private var pollTask: Task<Void, Never>?

    /// Token for the `NSWorkspace.didLaunchApplicationNotification` observer
    /// that wakes the poll loop when a known music app launches. Removed in
    /// `deinit`.
    private var launchObserver: NSObjectProtocol?

    private var cancellables = Set<AnyCancellable>()
    private let trackChangedSubject = PassthroughSubject<(title: String, artist: String, album: String, duration: TimeInterval, artworkURL: String?), Never>()

    init() {
        self.systemSource = SystemNowPlayingPlayerSource()
        self.spotifySource = SpotifyPlayerSource()
        self.appleMusicSource = AppleMusicPlayerSource()
        self.kasetSource = KasetPlayerSource()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
    }

    private func startPolling() {
        // 10 Hz interpolation tick. Lightweight: arithmetic + one @Published
        // set gated by a 10 ms threshold. Keeps the progress bar and lyric
        // highlight moving smoothly between source polls. Already a no-op
        // while no track is active (see `tickElapsedTimeInterpolation`).
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickElapsedTimeInterpolation()
            }
            .store(in: &cancellables)

        // Source-data poll. Runs as a single cooperative async loop whose
        // cadence adapts to activity: 1 Hz while a track is playing (so
        // seeking / track changes stay responsive and the 10 Hz
        // interpolation has fresh source data), 5 s once idle. See
        // `currentPollInterval()` for the state machine and
        // `restartPollingForLaunch()` for the cold-start wake path.
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }

        // Wake the poll loop immediately when a known music app launches so
        // lyrics appear without waiting for the next idle tick. Free while
        // idle: the system posts this regardless of our poll rate, and the
        // closure only does a cheap bundle-id check before restarting the
        // loop.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  MediaRemoteClient.shared.isKnownPublisher(bundleID)
            else { return }
            Task { @MainActor in
                self.restartPollingForLaunch()
            }
        }
    }

    /// Adaptive source-poll loop. Repeatedly refreshes then sleeps for
    /// `currentPollInterval()` seconds. Cancelling `pollTask` interrupts the
    /// in-flight sleep (via `CancellationError`, swallowed by `try?`) and the
    /// `Task.isCancelled` check exits the loop cleanly.
    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            if Task.isCancelled { break }
            let interval = currentPollInterval()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Returns the current poll interval based on how recently a track was
    /// playing. Runs on the main actor because `lastActiveAt` is written
    /// there (from `applyTrack`).
    private func currentPollInterval() -> TimeInterval {
        let idle = Date().timeIntervalSince(lastActiveAt) >= Self.activeCooldownSeconds
        return idle ? Self.idleIntervalSeconds : Self.activeIntervalSeconds
    }

    /// Cancels any in-flight poll sleep and restarts the loop with an
    /// immediate `refresh()`, so a freshly launched music app is detected
    /// within ~1 s instead of waiting for the next idle tick. Must be called
    /// on the main queue — the `didLaunchApplicationNotification` observer is
    /// registered with `queue: .main`.
    private func restartPollingForLaunch() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    // MARK: - Transport commands

    /// Routes a transport command (play/pause, next, previous) to the source
    /// owning the active track. Known AppleScript sources (Spotify, Apple
    /// Music, Kaset) handle their own verbs; everything else (VLC, Safari,
    /// Podcasts, …) falls through to the system source, which dispatches via
    /// the private MediaRemote framework. After dispatching, the poll loop is
    /// restarted so the UI reflects the new state within ~1s instead of
    /// waiting for the next idle tick.
    ///
    /// Must be called on the main queue (it reads `sourceBundleIdentifier` and
    /// calls `restartPollingForLaunch`); SwiftUI button actions satisfy this.
    func sendPlaybackCommand(_ command: PlaybackCommand) {
        let target = resolvedCommandSource()
        Task { [weak self] in
            _ = await target.sendCommand(command)
            self?.restartPollingForLaunch()
        }
    }

    /// Seeks the active player to the specified position (in seconds).
    /// If the matched player source cannot handle seeking, we fall back to
    /// the system Now Playing source.
    /// Rewinds the active player by 5 seconds, clamped to the start of the
    /// track. Reuses the existing seek path so all player sources behave
    /// consistently.
    func rewind5Seconds() {
        seek(to: max(0, elapsedTime - 5))
    }

    func seek(to position: TimeInterval) {
        // Snap interpolation state synchronously for instant visual feedback.
        // This must happen before the async Task so the 10 Hz tick immediately
        // interpolates from the new position, avoiding a ~0.5 s rubber-band
        // back to the old position while AppleScript completes.
        elapsedTime = position
        lastReportedElapsed = position
        driftOffset = 0
        lastReportedAt = Date()

        lastSeekAt = Date()
        lastSeekTarget = position

        let target = resolvedCommandSource()
        Task { [weak self] in
            let success = await target.seek(to: position)
            if !success {
                _ = await self?.systemSource.seek(to: position)
            }
            self?.restartPollingForLaunch()
        }
    }

    /// Picks the `PlayerSource` that should receive a transport command based
    /// on the active track's `sourceBundleIdentifier`. Falls back to the
    /// system source (MediaRemote) when the publisher isn't one of our
    /// AppleScript-enriched apps or is unknown.
    private func resolvedCommandSource() -> PlayerSource {
        guard let bundleID = sourceBundleIdentifier else { return systemSource }
        if spotifySource.bundleIdentifier == bundleID { return spotifySource }
        if appleMusicSource.bundleIdentifier == bundleID { return appleMusicSource }
        if kasetSource.bundleIdentifier == bundleID { return kasetSource }
        return systemSource
    }

    private func refresh() async {
        // Layer 1: system-wide MPNowPlayingInfoCenter. This is the source of
        // truth and works for any app that publishes to the system.
        let systemResult = await systemSource.currentTrackWithMetadata()
        let systemTrack = systemResult.track
        let systemArtwork = systemResult.artwork

        // Layer 2: prefer a non-paused system track. This is the path used
        // for Safari, VLC, Podcasts, Audible, and any other app that publishes
        // to the system Now Playing service.
        var resolvedTrack: DesktopTrack? = nil
        if let systemTrack, !systemTrack.isPaused {
            resolvedTrack = systemTrack
        }

        // Layer 3: scan known sources in frontmost-priority order. First one
        // that is actively playing wins. Gated by a running-app check so we
        // never spawn an `osascript` subprocess for an app that isn't
        // running — that spawn cost is the main energy waste this poll
        // would otherwise incur every tick.
        if resolvedTrack == nil {
            // If two known sources are both actively playing at the same time,
            // the frontmost app wins. The order below is the deterministic
            // tiebreaker for the rare case where the frontmost app isn't one of
            // our known sources.
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let orderedSources: [PlayerSource] = {
                guard let frontmostBundleID else { return enrichmentSources }
                var matched: [PlayerSource] = []
                var rest: [PlayerSource] = []
                for source in enrichmentSources {
                    if source.bundleIdentifier == frontmostBundleID {
                        matched.append(source)
                    } else {
                        rest.append(source)
                    }
                }
                return matched + rest
            }()

            let runningKnownIDs = MediaRemoteClient.shared.runningKnownPublisherBundleIDs()
            var pausedCandidate: DesktopTrack? = nil
            for source in orderedSources {
                guard let id = source.bundleIdentifier, runningKnownIDs.contains(id) else {
                    continue
                }
                if let candidate = await source.currentTrack() {
                    if !candidate.isPaused {
                        resolvedTrack = candidate
                        break
                    } else if pausedCandidate == nil {
                        pausedCandidate = candidate
                    }
                }
            }
            if resolvedTrack == nil {
                resolvedTrack = pausedCandidate
            }
        }

        // Layer 4: paused system track as a last resort so the user still
        // sees the last-known context (e.g. "Spotify — paused" in the menu bar).
        if resolvedTrack == nil {
            resolvedTrack = systemTrack
        }

        rawNowPlayingInfo = systemResult.rawInfo
        lastAppleScriptError = [
            spotifySource.lastError,
            appleMusicSource.lastError,
            kasetSource.lastError,
        ]
        .first(where: { !$0.isEmpty }) ?? ""

        lastSpotifyOutput = spotifySource.lastOutput
        lastAppleMusicOutput = appleMusicSource.lastOutput
        lastKasetOutput = kasetSource.lastOutput

        guard let track = resolvedTrack else {
            clearTrack()
            return
        }

        let resolvedSource: String
        if track.source != "Now Playing" {
            resolvedSource = track.source
        } else {
            resolvedSource = MediaRemoteClient.shared.currentPublisherDisplayName()
        }

        applyTrack(
            DesktopTrack(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                elapsedTime: track.elapsedTime,
                playbackRate: track.playbackRate,
                source: resolvedSource,
                bundleIdentifier: track.bundleIdentifier,
                isPaused: track.isPaused,
                artworkURL: track.artworkURL
            ),
            artwork: track.artworkURL != nil ? nil : systemArtwork
        )
    }

    // MARK: - Track state

    private func applyTrack(_ track: DesktopTrack, artwork: NSImage?) {
        var resolvedTrack = track

        if let seekAt = lastSeekAt {
            let elapsedSinceSeek = Date().timeIntervalSince(seekAt)
            if elapsedSinceSeek < 2.0 {
                let diffToTarget = abs(track.elapsedTime - lastSeekTarget)
                if diffToTarget > 1.5 {
                    // Player is still reporting the old position. Keep our local position.
                    resolvedTrack = DesktopTrack(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration,
                        elapsedTime: self.elapsedTime,
                        playbackRate: track.playbackRate,
                        source: track.source,
                        bundleIdentifier: track.bundleIdentifier,
                        isPaused: track.isPaused,
                        artworkURL: track.artworkURL
                    )
                } else {
                    lastSeekAt = nil
                }
            } else {
                lastSeekAt = nil
            }
        }

        let newTitle = resolvedTrack.title
        let newArtist = resolvedTrack.artist
        let newAlbum = resolvedTrack.album

        let trackDidChange = newTitle != title || newArtist != artist || newAlbum != album

        title = newTitle
        artist = newArtist
        album = newAlbum
        duration = resolvedTrack.duration
        lastParsedDuration = resolvedTrack.duration
        lastParsedElapsedTime = resolvedTrack.elapsedTime
        sourceDescription = resolvedTrack.source
        sourceBundleIdentifier = resolvedTrack.bundleIdentifier
        self.artwork = artwork

        let wasPlaying = isPlaying
        isPlaying = !resolvedTrack.isPaused

        // --- Poll-cadence state ---
        // Mark "active" only for a playing track so `currentPollInterval()`
        // keeps polling at 1 Hz. Paused tracks don't extend the active
        // window; once `activeCooldownSeconds` elapses without a playing
        // track the loop drops to the idle interval.
        if !resolvedTrack.isPaused {
            lastActiveAt = Date()
        }

        let now = Date()

        // Determine if there has been a recent control interaction (seek) from our app
        let no_control_interaction = (lastSeekAt == nil)

        if resolvedTrack.isPaused {
            // Paused: Reset drift and snap immediately to the exact player position.
            driftOffset = 0
            lastReportedElapsed = resolvedTrack.elapsedTime
            lastReportedAt = now
            lastReportedRate = 0
            
            // Prevent sudden reverse timestamp if it's just lag and no control interaction
            if no_control_interaction && resolvedTrack.elapsedTime < self.elapsedTime && (self.elapsedTime - resolvedTrack.elapsedTime) < 2.0 {
                // Do nothing to elapsedTime to keep it from jumping backwards
            } else {
                elapsedTime = resolvedTrack.elapsedTime
            }
        } else if trackDidChange || !wasPlaying {
            // Track changed or resumed from pause: Snap immediately to the exact player position.
            driftOffset = 0
            lastReportedElapsed = resolvedTrack.elapsedTime
            lastReportedAt = now
            lastReportedRate = resolvedTrack.playbackRate
            
            if no_control_interaction && !trackDidChange && resolvedTrack.elapsedTime < self.elapsedTime && (self.elapsedTime - resolvedTrack.elapsedTime) < 2.0 {
                // Prevent sudden reverse timestamp when resuming from pause
            } else {
                elapsedTime = resolvedTrack.elapsedTime
            }
        } else {
            // Normal playback: Calculate where the local wall clock expects playback to be.
            let expected: TimeInterval
            if lastReportedAt == .distantPast {
                expected = resolvedTrack.elapsedTime
            } else {
                let delta = max(0, now.timeIntervalSince(lastReportedAt))
                expected = lastReportedElapsed + delta * lastReportedRate
            }

            let diff = resolvedTrack.elapsedTime - expected

            // If the source is behind by up to 2.0 seconds, treat as lag, not a seek.
            // If the source jumps ahead by more than 0.5s, it's a forward seek.
            let isSeek = (diff > 0.5) || (diff < -2.0)

            if isSeek {
                // Seek detected
                driftOffset = 0
                lastReportedElapsed = resolvedTrack.elapsedTime
                lastReportedAt = now
                lastReportedRate = resolvedTrack.playbackRate
                elapsedTime = resolvedTrack.elapsedTime
            } else if abs(diff) < Self.jitterToleranceSeconds {
                // Negligible jitter (< 50 ms), existing driftOffset stays intact
            } else {
                // Polling/AppleScript jitter: minor diff caused by OS/AppleScript latency.
                //
                // If the source has fallen *behind* what our wall-clock expects and no
                // control interaction has happened, treat it as transient lag and skip
                // resetting the baseline. This prevents a backward jump without inflating
                // driftOffset (which would happen if we clamped nextElapsedTime and kept
                // anchoring lastReportedElapsed to the raw source each poll).
                if no_control_interaction && expected < self.elapsedTime {
                    // Source is behind wall-clock expectation: do not re-anchor.
                    // The running interpolator is already ahead; let the source catch up
                    // on the next poll rather than reversing elapsedTime.
                } else {
                    // Source is ahead (or no protection needed): absorb into driftOffset
                    // so elapsedTime stays at `expected` (no jump) and the 10 Hz tick
                    // continues smoothly from there.
                    driftOffset = expected - resolvedTrack.elapsedTime
                    lastReportedElapsed = resolvedTrack.elapsedTime
                    lastReportedAt = now
                    lastReportedRate = resolvedTrack.playbackRate
                    elapsedTime = expected
                }
            }
        }

        if trackDidChange && (!newTitle.isEmpty || !newArtist.isEmpty) {
            trackChangedSubject.send((title: newTitle, artist: newArtist, album: newAlbum, duration: resolvedTrack.duration, artworkURL: resolvedTrack.artworkURL))
        }
    }

    /// Advances `elapsedTime` by wall-clock interpolation between source polls.
    ///
    /// Called at 10 Hz by the Combine timer in `startPolling()`. Uses the
    /// baseline captured by the last `applyTrack` call:
    ///
    ///   `displayed = lastReportedElapsed + (now − lastReportedAt) × rate + driftOffset`
    ///
    /// A 0.01 s gate suppresses redundant `@Published` fires when the value
    /// has not meaningfully changed (e.g. immediately after `applyTrack`
    /// already set `elapsedTime` for the same instant).
    private func tickElapsedTimeInterpolation() {
        // Skip while paused (rate = 0) or when there's no active track.
        guard lastReportedRate > 0, lastReportedAt != .distantPast else { return }

        let now = Date()
        let delta = max(0, now.timeIntervalSince(lastReportedAt))
        let interpolated = lastReportedElapsed + delta * lastReportedRate
        let displayed = max(0, interpolated + driftOffset)

        // Only publish when the change is meaningful to avoid spamming
        // @Published fires when the value is essentially unchanged.
        if abs(displayed - elapsedTime) >= 0.01 {
            elapsedTime = displayed
        }
    }

    // MARK: - Clear

    private func clearTrack() {
        title = ""
        artist = ""
        album = ""
        duration = 0
        elapsedTime = 0
        sourceDescription = ""
        sourceBundleIdentifier = nil
        artwork = nil
        isPlaying = false

        // Reset interpolation + drift state so the next track starts fresh.
        // `lastActiveAt` is intentionally NOT reset here: keeping it lets the
        // `activeCooldownSeconds` window bridge brief gaps (track ends → next
        // track starts) so polling stays at 1 Hz across the boundary.
        lastReportedElapsed = 0
        lastReportedAt = .distantPast
        lastReportedRate = 0
        driftOffset = 0
    }
}
