//
//  NowPlayingService.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Combine
import Foundation
import MediaPlayer

/// Observes the system's currently playing media.
///
/// Primary sources are native desktop players (Spotify, Apple Music) queried
/// directly via AppleScript, because `MPNowPlayingInfoCenter` does not reliably
/// expose other apps' data on macOS. `MPNowPlayingInfoCenter` is kept as a
/// secondary fallback.
final class NowPlayingService: ObservableObject {
    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var sourceDescription: String = ""
    @Published private(set) var rawNowPlayingInfo: [String: Any] = [:]
    @Published private(set) var lastAppleScriptError: String = ""
    @Published private(set) var lastSpotifyOutput: String = ""
    @Published private(set) var lastAppleMusicOutput: String = ""
    @Published private(set) var lastParsedElapsedTime: TimeInterval = 0
    @Published private(set) var lastParsedDuration: TimeInterval = 0

    /// Emitted whenever the playing track (title + artist) changes.
    var trackChangedPublisher: AnyPublisher<(title: String, artist: String, album: String, duration: TimeInterval), Never> {
        trackChangedSubject.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()
    private let trackChangedSubject = PassthroughSubject<(title: String, artist: String, album: String, duration: TimeInterval), Never>()

    init() {
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
        // 1. Try desktop music apps directly via AppleScript.
        if let track = await fetchDesktopPlayerTrack() {
            await MainActor.run {
                applyTrack(track, source: track.source)
            }
            return
        }

        // 2. Fall back to MPNowPlayingInfoCenter.
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        let newTitle = normalizeMetadata(info[MPMediaItemPropertyTitle] as? String ?? "")
        let newArtist = normalizeMetadata(info[MPMediaItemPropertyArtist] as? String ?? "")
        let newAlbum = normalizeMetadata(info[MPMediaItemPropertyAlbumTitle] as? String ?? "")
        let newDuration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
        let rawElapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 1

        await MainActor.run {
            rawNowPlayingInfo = info

            if !newTitle.isEmpty || !newArtist.isEmpty {
                applyTrack(
                    DesktopTrack(
                        title: newTitle,
                        artist: newArtist,
                        album: newAlbum,
                        duration: newDuration,
                        elapsedTime: rawElapsed,
                        playbackRate: rate,
                        source: "Now Playing"
                    ),
                    source: "Now Playing"
                )
            } else {
                clearTrack()
            }
        }
    }

    // MARK: - Desktop player AppleScript

    private func fetchDesktopPlayerTrack() async -> DesktopTrack? {
        let spotify = await runAppleScript(Self.spotifyScript) ?? ""
        lastSpotifyOutput = spotify.isEmpty ? "<empty>" : spotify
        if let track = parseDesktopPlayerOutput(spotify, source: "Spotify") {
            return track
        }

        let music = await runAppleScript(Self.appleMusicScript) ?? ""
        lastAppleMusicOutput = music.isEmpty ? "<empty>" : music
        if let track = parseDesktopPlayerOutput(music, source: "Apple Music") {
            return track
        }

        return nil
    }

    private static let spotifyScript = """
    tell application "Spotify"
        if it is running then
            if player state is playing then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to (duration of current track) / 1000
                set trackPosition to player position
                return trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
            end if
        end if
    end tell
    return ""
    """

    private static let appleMusicScript = """
    tell application "Music"
        if it is running then
            if player state is playing then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                return trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
            end if
        end if
    end tell
    return ""
    """

    private func parseDesktopPlayerOutput(_ output: String, source: String) -> DesktopTrack? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.components(separatedBy: "|")
        guard parts.count >= 5 else { return nil }

        let title = normalizeMetadata(parts[0])
        let artist = normalizeMetadata(parts[1])
        let album = normalizeMetadata(parts[2])
        let duration = parseTimeInterval(parts[3])
        let elapsed = parseTimeInterval(parts[4])

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        return DesktopTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsed,
            playbackRate: 1,
            source: source
        )
    }

    private func parseTimeInterval(_ value: String) -> TimeInterval {
        let normalized = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return TimeInterval(normalized) ?? 0
    }

    private func runAppleScript(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""

                    DispatchQueue.main.async { [weak self] in
                        if process.terminationStatus == 0 {
                            self?.lastAppleScriptError = ""
                            continuation.resume(
                                returning: output.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        } else {
                            self?.lastAppleScriptError = error.isEmpty ? output : error
                            continuation.resume(returning: nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.lastAppleScriptError = error.localizedDescription
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    // MARK: - Track state

    private func applyTrack(_ track: DesktopTrack, source: String) {
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
        sourceDescription = source

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
    }

    private func normalizeMetadata(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let noisePatterns = [
            "(Official Video)",
            "(Official Music Video)",
            "(Lyrics)",
            "(Lyric Video)",
            "(Audio)",
            "(Visualizer)",
            "- Official Video",
            "- Official Music Video",
        ]

        for pattern in noisePatterns {
            result = result.replacingOccurrences(of: pattern, with: "")
        }

        return result.trimmingCharacters(in: .whitespaces)
    }
}

private struct DesktopTrack {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let source: String
}
