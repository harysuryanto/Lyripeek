//
//  PlayerSource.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import AppKit
import Foundation

/// Normalized track snapshot returned by any `PlayerSource`.
///
/// `source` is the human-friendly display name (e.g. "Spotify", "Apple Music",
/// "Kaset", "VLC", "Safari", "Now Playing"). `bundleIdentifier` is the
/// publishing app's bundle id when known, used by the orchestrator to pick
/// which enrichment source to overlay.
struct DesktopTrack {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let source: String
    let bundleIdentifier: String?
    let isPaused: Bool

    init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        playbackRate: Double = 1,
        source: String,
        bundleIdentifier: String?,
        isPaused: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.source = source
        self.bundleIdentifier = bundleIdentifier
        self.isPaused = isPaused
    }

    var hasMetadata: Bool {
        !title.isEmpty || !artist.isEmpty
    }
}

/// A pluggable provider of now-playing metadata for a single app (or for the
/// system in general).
///
/// Implementations are expected to be safe to call on a background queue and
/// to return `nil` when no track is available or the underlying app isn't
/// running. They must never throw; transient errors should be swallowed and
/// surfaced via `lastError` for the debug window.
protocol PlayerSource: AnyObject {
    /// Bundle id of the app this source represents. Used by the orchestrator
    /// to match the active publisher reported by `MediaRemoteClient`. `nil` is
    /// reserved for the generic system source, which is selected only when no
    /// other source matches.
    var bundleIdentifier: String? { get }

    /// Human-friendly display name shown in the popover subtitle and debug UI.
    var displayName: String { get }

    /// Returns the current track, or `nil` if nothing is playing or the app
    /// isn't running. `paused` should be `true` when a track is loaded but
    /// playback is paused — the orchestrator keeps the track visible in that
    /// case so lyrics stay attached.
    func currentTrack() async -> DesktopTrack?

    /// Most recent error message from the underlying transport (AppleScript,
    /// HTTP, etc.). Empty when the last call succeeded.
    var lastError: String { get }

    /// Most recent raw output (AppleScript stdout, JSON body, etc.). Useful
    /// for the debug window.
    var lastOutput: String { get }
}

extension PlayerSource {
}

/// Strips common noise from a metadata string (e.g. "Song (Official Video)").
func normalizeMetadata(_ value: String) -> String {
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

/// Parses an AppleScript numeric value, tolerating locale-specific decimal
/// separators (commas) and surrounding whitespace.
func parseAppleScriptTimeInterval(_ value: String) -> TimeInterval {
    let normalized = value
        .trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: ",", with: ".")
    return TimeInterval(normalized) ?? 0
}

/// Runs an AppleScript via `osascript` off the main thread.
///
/// Returns the trimmed stdout on success, `nil` on non-zero exit (script
/// error, app not running, etc.). Errors are surfaced via the optional
/// `errorHandler` so callers can stash them in `lastError` for the debug
/// window.
func runAppleScript(
    _ script: String,
    errorHandler: ((String) -> Void)? = nil
) async -> String? {
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

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        errorHandler?("")
                        continuation.resume(
                            returning: output.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    } else {
                        let message = error.isEmpty ? output : error
                        errorHandler?(message)
                        continuation.resume(returning: nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorHandler?(error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
