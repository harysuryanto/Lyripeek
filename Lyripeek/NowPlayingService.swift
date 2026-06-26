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

    /// Read-only list of all known `PlayerSource` instances (system + the
    /// three enriched apps). Used by the popover's "Supported Players" bar
    /// and the debug window.
    var allSources: [PlayerSource] {
        [systemSource, spotifySource, appleMusicSource, kasetSource]
    }

    private var cancellables = Set<AnyCancellable>()
    private let trackChangedSubject = PassthroughSubject<(title: String, artist: String, album: String, duration: TimeInterval), Never>()

    init() {
        self.systemSource = SystemNowPlayingPlayerSource()
        self.spotifySource = SpotifyPlayerSource()
        self.appleMusicSource = AppleMusicPlayerSource()
        self.kasetSource = KasetPlayerSource()
        startPolling()
    }

    private func startPolling() {
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)

        Task { [weak self] in
            await self?.refresh()
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
        // that is actively playing wins.
        if resolvedTrack == nil {
            for source in orderedSources {
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
        elapsedTime = track.elapsedTime
        lastParsedDuration = track.duration
        lastParsedElapsedTime = track.elapsedTime
        sourceDescription = track.source
        sourceBundleIdentifier = track.bundleIdentifier
        self.artwork = artwork

        if trackDidChange && (!newTitle.isEmpty || !newArtist.isEmpty) {
            trackChangedSubject.send((title: newTitle, artist: newArtist, album: newAlbum, duration: track.duration))
        }
    }

    private func clearTrack() {
        title = ""
        artist = ""
        album = ""
        duration = 0
        elapsedTime = 0
        sourceDescription = ""
        sourceBundleIdentifier = nil
        artwork = nil
    }
}
