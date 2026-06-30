//
//  AppleMusicPlayerSource.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import Foundation

/// AppleScript enrichment for Apple Music. Used to overlay a fresh `position`
/// and a clean display name on top of the `MPNowPlayingInfoCenter` data when
/// the active publisher is Apple Music.
final class AppleMusicPlayerSource: PlayerSource {
    let bundleIdentifier: String? = "com.apple.Music"
    let displayName = "Apple Music"

    private(set) var lastError: String = ""
    private(set) var lastOutput: String = "<empty>"

    private static let script = """
    tell application "Music"
        if it is running then
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
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
        return SpotifyPlayerSource.parse(output: output, source: displayName, bundleIdentifier: bundleIdentifier)
    }

    func sendCommand(_ command: PlaybackCommand) async -> Bool {
        let statement: String
        switch command {
        case .playPause: statement = "playpause"
        case .nextTrack: statement = "next track"
        case .previousTrack: statement = "previous track"
        }
        let script = """
        tell application "Music"
            if it is running then
                \(statement)
                return "ok"
            end if
        end tell
        return ""
        """
        let output = await runAppleScript(script) { [weak self] err in
            self?.lastError = err
        }
        return output != nil && !(output?.isEmpty ?? true)
    }
}
