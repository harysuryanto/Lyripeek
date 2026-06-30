//
//  SystemNowPlayingPlayerSource.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import AppKit
import Foundation
import MediaPlayer

/// Reads the system-wide `MPNowPlayingInfoCenter` — the same data the macOS
/// Control Center Now Playing widget uses. This is the always-on primary
/// source: any app that publishes to the system works here, even ones we
/// have no `PlayerSource` for.
final class SystemNowPlayingPlayerSource: PlayerSource {
    let bundleIdentifier: String? = nil
    let displayName = "Now Playing"

    private(set) var lastError: String = ""
    private(set) var lastOutput: String = ""
    private(set) var rawNowPlayingInfo: [String: Any] = [:]
    private(set) var systemArtwork: NSImage? = nil

    func currentTrack() async -> DesktopTrack? {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        rawNowPlayingInfo = info
        lastOutput = info.isEmpty ? "<empty>" : "\(info.count) keys"

        systemArtwork = Self.makeImage(from: info[MPMediaItemPropertyArtwork])

        let title = normalizeMetadata(info[MPMediaItemPropertyTitle] as? String ?? "")
        let artist = normalizeMetadata(info[MPMediaItemPropertyArtist] as? String ?? "")
        let album = normalizeMetadata(info[MPMediaItemPropertyAlbumTitle] as? String ?? "")
        let duration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
        let rawElapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 1

        guard !title.isEmpty || !artist.isEmpty else {
            return nil
        }

        // `MPNowPlayingInfoPropertyPlaybackRate` is 0 when paused, > 0 when
        // playing. Apps that don't publish a rate default to 1, which we
        // treat as "playing" so we don't falsely flag healthy data.
        let isPaused = rate == 0

        return DesktopTrack(
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
    }

    /// Dispatches transport commands through the private MediaRemote framework
    /// so any app publishing to the system Now Playing service (VLC, Safari,
    /// Podcasts, Audible, …) is controllable, not just the AppleScript-enriched
    /// ones. Returns `false` when MediaRemote isn't loadable so the orchestrator
    /// knows no command was sent.
    func sendCommand(_ command: PlaybackCommand) async -> Bool {
        MediaRemoteClient.shared.sendCommand(command)
    }

    nonisolated private static let artworkRenderSize = CGSize(width: 600, height: 600)

    nonisolated private static func makeImage(from raw: Any?) -> NSImage? {
        guard let artwork = raw as? MPMediaItemArtwork else { return nil }
        return artwork.image(at: artworkRenderSize)
    }
}
