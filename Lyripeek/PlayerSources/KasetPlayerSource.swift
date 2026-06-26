//
//  KasetPlayerSource.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import Foundation

/// AppleScript enrichment for [Kaset](https://github.com/sozercan/kaset), a
/// native macOS YouTube / YouTube Music client. Kaset exposes a JSON payload
/// via `tell application "Kaset" to get player info` containing the current
/// track, position, duration, and artwork URL.
///
/// We use the same `position`/`duration` parsing the existing Spotify / Apple
/// Music scripts do, but for Kaset the values are already in seconds so no
/// millisecond conversion is needed.
final class KasetPlayerSource: PlayerSource {
    let bundleIdentifier: String? = "com.sertacozercan.Kaset"
    let displayName = "Kaset"

    private(set) var lastError: String = ""
    private(set) var lastOutput: String = "<empty>"

    private static let script = """
    tell application "Kaset"
        try
            return get player info
        end try
    end tell
    return ""
    """

    func currentTrack() async -> DesktopTrack? {
        let output = (await runAppleScript(Self.script) { [weak self] err in
            self?.lastError = err
        }) ?? ""
        lastOutput = output.isEmpty ? "<empty>" : output
        return Self.parse(jsonString: output, source: displayName, bundleIdentifier: bundleIdentifier)
    }

    static func parse(jsonString: String, source: String, bundleIdentifier: String?) -> DesktopTrack? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return nil
        }

        let info: KasetPlayerInfo
        do {
            info = try JSONDecoder().decode(KasetPlayerInfo.self, from: data)
        } catch {
            return nil
        }

        guard let track = info.currentTrack else {
            return nil
        }

        let title = normalizeMetadata(track.name ?? "")
        let artist = normalizeMetadata(track.artist ?? "")
        let album = normalizeMetadata(track.album ?? "")

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let position = info.position ?? track.duration ?? 0
        let duration = info.duration ?? track.duration ?? 0

        // Kaset reports `isPlaying: false` while paused. Treat either flag
        // as a definitive pause signal so the orchestrator can prefer
        // actively-playing tracks from other sources.
        let isPaused = info.isPlaying == false || info.isPaused == true

        return DesktopTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: position,
            playbackRate: 1,
            source: source,
            bundleIdentifier: bundleIdentifier,
            isPaused: isPaused
        )
    }
}

// MARK: - JSON model

private struct KasetPlayerInfo: Decodable {
    let isPlaying: Bool?
    let isPaused: Bool?
    let position: TimeInterval?
    let duration: TimeInterval?
    let currentTrack: KasetTrack?
}

private struct KasetTrack: Decodable {
    let name: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let videoId: String?
    let artworkURL: String?
}
