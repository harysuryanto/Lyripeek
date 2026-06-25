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

/// Observes the system's currently playing media.
///
/// Primary source: `MPNowPlayingInfoCenter` (Spotify, Apple Music, etc.).
/// Fallback source: active browser tab/window title for web players such as
/// YouTube Music that do not publish to `MPNowPlayingInfoCenter`.
final class NowPlayingService: ObservableObject {
    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var rawNowPlayingInfo: [String: Any] = [:]
    @Published private(set) var sourceDescription: String = ""
    @Published private(set) var lastRawBrowserTitle: String = ""
    @Published private(set) var lastAppleScriptError: String = ""

    /// Emitted whenever the playing track (title + artist) changes.
    var trackChangedPublisher: AnyPublisher<(title: String, artist: String), Never> {
        trackChangedSubject.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()
    private let trackChangedSubject = PassthroughSubject<(title: String, artist: String), Never>()

    // MARK: - MPNowPlayingInfoCenter state
    private var lastRawElapsedTime: TimeInterval = 0
    private var lastInfoTimestamp: Date?
    private var lastPlaybackRate: Double = 1

    // MARK: - Browser fallback state
    private var browserFallbackActive = false
    private var browserTrackStartTime: Date?
    private var browserLastDetectedTitle = ""

    init() {
        startPolling()
    }

    private func startPolling() {
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        refresh()
    }

    private func refresh() {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        rawNowPlayingInfo = info

        let extracted = extractTrackInfo(from: info)
        let hasSystemInfo = !extracted.title.isEmpty

        if hasSystemInfo {
            applySystemTrack(extracted)
        } else {
            detectBrowserTab { [weak self] browserTitle in
                self?.applyBrowserTrack(browserTitle)
            }
        }
    }

    // MARK: - System track handling

    private func applySystemTrack(_ extracted: (title: String, artist: String)) {
        browserFallbackActive = false
        browserLastDetectedTitle = ""
        browserTrackStartTime = nil

        let newTitle = normalizeMetadata(extracted.title)
        let newArtist = normalizeMetadata(extracted.artist)

        updateTrack(title: newTitle, artist: newArtist, source: "Now Playing")

        let info = rawNowPlayingInfo
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 1
        let rawElapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0

        let now = Date()
        if let lastTimestamp = lastInfoTimestamp {
            let delta = now.timeIntervalSince(lastTimestamp)
            elapsedTime = lastRawElapsedTime + (delta * rate)
        } else {
            elapsedTime = rawElapsed
            lastRawElapsedTime = rawElapsed
            lastInfoTimestamp = now
            lastPlaybackRate = rate
            return
        }

        // Resync if the player posted a notably different elapsed time.
        if abs(rawElapsed - elapsedTime) > 2.0 {
            elapsedTime = rawElapsed
            lastRawElapsedTime = rawElapsed
            lastInfoTimestamp = now
            lastPlaybackRate = rate
        }
    }

    // MARK: - Browser fallback handling

    private func applyBrowserTrack(_ browserTitle: String?) {
        guard let browserTitle, !browserTitle.isEmpty else {
            // No browser title either — clear everything if we were in browser fallback.
            if browserFallbackActive {
                updateTrack(title: "", artist: "", source: "")
                elapsedTime = 0
                browserFallbackActive = false
                browserTrackStartTime = nil
                browserLastDetectedTitle = ""
            }
            return
        }

        let parsed = parseBrowserTitle(browserTitle)
        let newTitle = normalizeMetadata(parsed.title)
        let newArtist = normalizeMetadata(parsed.artist)

        let trackKey = "\(newArtist) - \(newTitle)"
        let trackDidChange = trackKey != browserLastDetectedTitle

        browserFallbackActive = true
        lastInfoTimestamp = nil
        lastRawElapsedTime = 0

        if trackDidChange {
            browserLastDetectedTitle = trackKey
            browserTrackStartTime = Date()
            elapsedTime = 0
            updateTrack(title: newTitle, artist: newArtist, source: "Browser tab")
        } else if let startTime = browserTrackStartTime {
            elapsedTime = Date().timeIntervalSince(startTime)
        }
    }

    // MARK: - Shared track update

    private func updateTrack(title newTitle: String, artist newArtist: String, source: String) {
        let trackDidChange = newTitle != title || newArtist != artist
        title = newTitle
        artist = newArtist
        sourceDescription = source

        if trackDidChange && (!newTitle.isEmpty || !newArtist.isEmpty) {
            trackChangedSubject.send((title: newTitle, artist: newArtist))
        }
    }

    // MARK: - Parsing helpers

    private func extractTrackInfo(from info: [String: Any]) -> (title: String, artist: String) {
        var rawTitle = info[MPMediaItemPropertyTitle] as? String ?? ""
        var rawArtist = info[MPMediaItemPropertyArtist] as? String ?? ""

        if rawTitle.isEmpty {
            rawTitle = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""
        }

        if rawArtist.isEmpty && rawTitle.contains(" - ") {
            let components = rawTitle.components(separatedBy: " - ")
            if components.count >= 2 {
                rawArtist = components.dropLast().joined(separator: " - ")
                rawTitle = components.last ?? rawTitle
            }
        }

        return (title: rawTitle, artist: rawArtist)
    }

    /// Parses common browser tab titles. YouTube Music tabs are usually:
    ///   "Song Title - Artist"
    ///   "Song Title - Artist - Album"
    ///   "Song Title - Artist - YouTube Music"
    private func parseBrowserTitle(_ value: String) -> (title: String, artist: String) {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let siteSuffixes = [
            " - YouTube Music",
            " - YouTube",
            " - Spotify",
            " - Apple Music",
            " - SoundCloud",
        ]

        for suffix in siteSuffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned.removeLast(suffix.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            }
        }

        let components = cleaned.components(separatedBy: " - ")
        if components.count >= 2 {
            let title = components.last ?? cleaned
            let artist = components.dropLast().joined(separator: " - ")
            return (title: title, artist: artist)
        }

        return (title: cleaned, artist: "")
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

    // MARK: - AppleScript browser detection

    private func detectBrowserTab(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let browserNames = ["Safari", "Google Chrome", "Brave Browser", "Microsoft Edge", "Arc"]

            // Use NSWorkspace to find the frontmost app without needing System Events.
            let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName
            let targetBrowsers: [String]
            if let frontmostName, browserNames.contains(frontmostName) {
                targetBrowsers = [frontmostName] + browserNames.filter { $0 != frontmostName }
            } else {
                targetBrowsers = browserNames
            }

            var rawTitle = ""
            var scriptError = ""

            for browser in targetBrowsers {
                let script = """
                tell application "\(browser)"
                    if it is running then
                        try
                            return name of front window
                        on error errMsg
                            return "ERROR:" & errMsg
                        end try
                    end if
                end tell
                return ""
                """

                let (output, error) = self.runAppleScript(script)
                if let error, !error.isEmpty {
                    scriptError = error
                }

                let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.hasPrefix("ERROR:") {
                    scriptError = trimmed
                    continue
                }
                if !trimmed.isEmpty {
                    rawTitle = trimmed
                    break
                }
            }

            DispatchQueue.main.async {
                self.lastRawBrowserTitle = rawTitle
                self.lastAppleScriptError = scriptError.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(rawTitle.isEmpty ? nil : rawTitle)
            }
        }
    }

    private func runAppleScript(_ source: String) -> (output: String?, error: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8)
            let error = String(data: errorData, encoding: .utf8)
            return (output, error)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
