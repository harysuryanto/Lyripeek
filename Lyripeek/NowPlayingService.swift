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
/// - **Auto-drift correction**: when the source app is consistently behind
///   the wall clock (Spotify, Apple Music, and Kaset all update
///   `MPNowPlayingInfoCenter` only on state changes or every few seconds),
///   we detect the lag and add it to the interpolated value, capped at 5 s.
/// - **Adaptive polling**: the source-data poll runs at 1 Hz while a track
///   is playing and drops to a 5 s idle cadence once no track has been
///   playing for ~5 s, so the app stays quiet when idle. AppleScript
///   enrichment is additionally gated on the target app actually running,
///   so no `osascript` subprocess is spawned when no supported music app is
///   open. A `NSWorkspace` launch observer wakes the poll immediately when a
///   known music app starts.
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

    /// Emitted whenever the playing track (title + artist) changes.
    var trackChangedPublisher: AnyPublisher<(title: String, artist: String, album: String, duration: TimeInterval), Never> {
        trackChangedSubject.eraseToAnyPublisher()
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

    /// The source-app-reported elapsed time captured at `lastReportedAt`.
    /// Interpolated forward between source polls by `tickElapsedTimeInterpolation`.
    private var lastReportedElapsed: TimeInterval = 0
    private var lastReportedAt: Date = .distantPast
    /// `playbackRate` of the last source read; `0` when paused (which makes
    /// the tick a no-op so the progress bar freezes).
    private var lastReportedRate: Double = 0

    // MARK: - Auto-drift state

    /// Detected offset between the source's reported position and the actual
    /// wall-clock position. Added to the interpolated value before publish.
    /// Capped at `Self.driftCapSeconds` to prevent runaway.
    private var driftOffset: TimeInterval = 0
    /// The "fresh" baseline for drift detection: the source value + wall
    /// clock time we last accepted as truth. Used to estimate how far the
    /// source has fallen behind the wall clock.
    private var lastFreshSourceValue: TimeInterval? = nil
    private var lastFreshSourceAt: Date? = nil

    private static let driftCapSeconds: TimeInterval = 5.0

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
    private let trackChangedSubject = PassthroughSubject<(title: String, artist: String, album: String, duration: TimeInterval), Never>()

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
            self.restartPollingForLaunch()
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
            let interval = await currentPollInterval()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Returns the current poll interval based on how recently a track was
    /// playing. Runs on the main actor because `lastActiveAt` is written
    /// there (from `applyTrack`).
    private func currentPollInterval() async -> TimeInterval {
        await MainActor.run {
            let idle = Date().timeIntervalSince(lastActiveAt) >= Self.activeCooldownSeconds
            return idle ? Self.idleIntervalSeconds : Self.activeIntervalSeconds
        }
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

    private func refresh() async {
        // Layer 1: system-wide MPNowPlayingInfoCenter. This is the source of
        // truth and works for any app that publishes to the system.
        let systemTrack = await systemSource.currentTrack()
        let systemArtwork = systemSource.systemArtwork

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
            let runningKnownIDs = MediaRemoteClient.shared.runningKnownPublisherBundleIDs()
            for source in orderedSources {
                guard let id = source.bundleIdentifier, runningKnownIDs.contains(id) else {
                    continue
                }
                if let candidate = await source.currentTrack(), !candidate.isPaused {
                    resolvedTrack = candidate
                    break
                }
            }
        }

        // Layer 4: paused system track as a last resort so the user still
        // sees the last-known context (e.g. "Spotify — paused" in the menu bar).
        if resolvedTrack == nil {
            resolvedTrack = systemTrack
        }

        await MainActor.run {
            rawNowPlayingInfo = systemSource.rawNowPlayingInfo
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
                    isPaused: track.isPaused
                ),
                artwork: systemArtwork
            )
        }
    }

    // MARK: - Track state

    private func applyTrack(_ track: DesktopTrack, artwork: NSImage?) {
        let newTitle = track.title
        let newArtist = track.artist
        let newAlbum = track.album

        let trackDidChange = newTitle != title || newArtist != artist || newAlbum != album

        title = newTitle
        artist = newArtist
        album = newAlbum
        duration = track.duration
        lastParsedDuration = track.duration
        lastParsedElapsedTime = track.elapsedTime
        sourceDescription = track.source
        sourceBundleIdentifier = track.bundleIdentifier
        self.artwork = artwork

        // --- Interpolation baseline ---
        // Rate of 0 means "paused" — the 10 Hz tick will treat this as a
        // no-op and the progress bar will freeze at the last known value.
        lastReportedElapsed = track.elapsedTime
        lastReportedAt = Date()
        lastReportedRate = track.isPaused ? 0 : track.playbackRate

        // --- Poll-cadence state ---
        // Mark "active" only for a playing track so `currentPollInterval()`
        // keeps polling at 1 Hz. Paused tracks don't extend the active
        // window; once `activeCooldownSeconds` elapses without a playing
        // track the loop drops to the idle interval.
        if !track.isPaused {
            lastActiveAt = Date()
        }

        // --- Auto-drift detection ---
        updateDriftOffset(newSourceValue: track.elapsedTime)

        // --- Published elapsedTime ---
        // Use the interpolated + drift-corrected value so the very first
        // tick after a source update already shows the right number
        // (the next 10 Hz tick will keep advancing it).
        let interpolated = lastReportedElapsed + max(0, lastReportedAt.timeIntervalSinceNow) * -1 * lastReportedRate
        elapsedTime = max(0, interpolated + driftOffset)

        if trackDidChange && (!newTitle.isEmpty || !newArtist.isEmpty) {
            trackChangedSubject.send((title: newTitle, artist: newArtist, album: newAlbum, duration: track.duration))
        }
    }

    /// Recomputes `driftOffset` based on the new source value. Called on
    /// every `applyTrack`.
    ///
    /// The rule: if the source value is at or ahead of where wall clock
    /// would put it (since the last fresh baseline), the source has caught
    /// up — reset the drift. If the source is still behind, estimate the
    /// drift as the wall-clock delta minus the source's progress.
    private func updateDriftOffset(newSourceValue: TimeInterval) {
        let now = Date()

        guard let freshValue = lastFreshSourceValue,
              let freshAt = lastFreshSourceAt else {
            // First reading ever; nothing to compare against.
            lastFreshSourceValue = newSourceValue
            lastFreshSourceAt = now
            driftOffset = 0
            return
        }

        let wallClockSinceFresh = max(0, now.timeIntervalSince(freshAt))
        let expectedSinceFresh = wallClockSinceFresh * lastReportedRate
        let actualSinceFresh = newSourceValue - freshValue

        if actualSinceFresh >= expectedSinceFresh - 0.5 {
            // Source caught up. Accept as new fresh baseline.
            lastFreshSourceValue = newSourceValue
            lastFreshSourceAt = now
            driftOffset = 0
        } else if actualSinceFresh < 0 {
            // Seek backward. Accept the new value, reset drift.
            lastFreshSourceValue = newSourceValue
            lastFreshSourceAt = now
            driftOffset = 0
        } else {
            // Source is stale. Drift = how much we should add to stay in sync.
            let estimatedDrift = expectedSinceFresh - actualSinceFresh
            driftOffset = min(max(0, estimatedDrift), Self.driftCapSeconds)
        }
    }

    // MARK: - 10 Hz tick

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

        // Reset interpolation + drift state so the next track starts fresh.
        // `lastActiveAt` is intentionally NOT reset here: keeping it lets the
        // `activeCooldownSeconds` window bridge brief gaps (track ends → next
        // track starts) so polling stays at 1 Hz across the boundary.
        lastReportedElapsed = 0
        lastReportedAt = .distantPast
        lastReportedRate = 0
        driftOffset = 0
        lastFreshSourceValue = nil
        lastFreshSourceAt = nil
    }
}
