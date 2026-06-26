//
//  SpotifyPlayerSource.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import Foundation

/// AppleScript enrichment for Spotify. Used to overlay a fresh `position` and
/// a clean display name on top of the `MPNowPlayingInfoCenter` data when the
/// active publisher is Spotify.
final class SpotifyPlayerSource: PlayerSource {
    let bundleIdentifier: String? = "com.spotify.client"
    let displayName = "Spotify"

    private(set) var lastError: String = ""
    private(set) var lastOutput: String = "<empty>"

    private static let script = """
    tell application "Spotify"
        if it is running then
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to (duration of current track) / 1000
                set trackPosition to player position
                if player state is playing then
                    return trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
                else
                    return "PAUSED:" & trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
                end if
            end try
        end if
    end tell
    return ""
    """

    func currentTrack() async -> DesktopTrack? {
        let output = (await runAppleScript(Self.script) { [weak self] err in
            self?.lastError = err
        }) ?? ""
        lastOutput = output.isEmpty ? "<empty>" : output
        return Self.parse(output: output, source: displayName, bundleIdentifier: bundleIdentifier)
    }

    static func parse(output: String, source: String, bundleIdentifier: String?) -> DesktopTrack? {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isPaused: Bool
        if trimmed.hasPrefix("PAUSED:") {
            isPaused = true
            trimmed = String(trimmed.dropFirst(7))
        } else {
            isPaused = false
        }

        let parts = trimmed.components(separatedBy: "|")
        guard parts.count >= 5 else { return nil }

        let title = normalizeMetadata(parts[0])
        let artist = normalizeMetadata(parts[1])
        let album = normalizeMetadata(parts[2])
        let duration = parseAppleScriptTimeInterval(parts[3])
        let elapsed = parseAppleScriptTimeInterval(parts[4])

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        return DesktopTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsed,
            playbackRate: 1,
            source: source,
            bundleIdentifier: bundleIdentifier,
            isPaused: isPaused
        )
    }
}
