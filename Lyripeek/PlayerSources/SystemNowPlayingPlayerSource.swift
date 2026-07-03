//
//  SystemNowPlayingPlayerSource.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import AppKit
import Foundation
import MediaPlayer

struct SystemTrackResult {
    let track: DesktopTrack?
    let rawInfo: [String: Any]
    let artwork: NSImage?
    let lastOutput: String
}

/// Reads the system-wide `MPNowPlayingInfoCenter` — the same data the macOS
/// Control Center Now Playing widget uses. This is the always-on primary
/// source: any app that publishes to the system works here, even ones we
/// have no `PlayerSource` for.
final class SystemNowPlayingPlayerSource: PlayerSource {
    let bundleIdentifier: String? = nil
    let displayName = "Now Playing"

    private(set) var lastError: String = ""
    private(set) var lastOutput: String = ""

    func currentTrack() async -> DesktopTrack? {
        let result = await currentTrackWithMetadata()
        lastOutput = result.lastOutput
        return result.track
    }

    func currentTrackWithMetadata() async -> SystemTrackResult {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let output = info.isEmpty ? "<empty>" : "\(info.count) keys"
        let artwork = Self.makeImage(from: info[MPMediaItemPropertyArtwork])

        let title = normalizeMetadata(info[MPMediaItemPropertyTitle] as? String ?? "")
        let artist = normalizeMetadata(info[MPMediaItemPropertyArtist] as? String ?? "")
        let album = normalizeMetadata(info[MPMediaItemPropertyAlbumTitle] as? String ?? "")
        let duration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
        let rawElapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 1

        guard !title.isEmpty || !artist.isEmpty else {
            return SystemTrackResult(
                track: nil,
                rawInfo: info,
                artwork: artwork,
                lastOutput: output
            )
        }

        // `MPNowPlayingInfoPropertyPlaybackRate` is 0 when paused, > 0 when
        // playing. Apps that don't publish a rate default to 1, which we
        // treat as "playing" so we don't falsely flag healthy data.
        let isPaused = rate == 0

        let track = DesktopTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: rawElapsed,
            playbackRate: rate,
            source: "Now Playing",
            bundleIdentifier: nil,
            isPaused: isPaused
        )

        return SystemTrackResult(
            track: track,
            rawInfo: info,
            artwork: artwork,
            lastOutput: output
        )
    }

    /// Dispatches transport commands through the private MediaRemote framework
    /// so any app publishing to the system Now Playing service (VLC, Safari,
    /// Podcasts, Audible, …) is controllable, not just the AppleScript-enriched
    /// ones. Returns `false` when MediaRemote isn't loadable so the orchestrator
    /// knows no command was sent.
    func sendCommand(_ command: PlaybackCommand) async -> Bool {
        MediaRemoteClient.shared.sendCommand(command)
    }

    func seek(to position: TimeInterval) async -> Bool {
        MediaRemoteClient.shared.seek(to: position)
    }

    nonisolated private static let artworkRenderSize = CGSize(width: 600, height: 600)

    nonisolated private static func makeImage(from raw: Any?) -> NSImage? {
        guard let artwork = raw as? MPMediaItemArtwork else { return nil }
        return artwork.image(at: artworkRenderSize)
    }
}
