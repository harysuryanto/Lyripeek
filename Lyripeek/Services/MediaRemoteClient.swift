//
//  MediaRemoteClient.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import AppKit
import Foundation
import Darwin

private typealias UnsafeMutableRawObject = UnsafeMutableRawPointer

/// Detects which app is currently publishing to macOS's Now Playing service
/// so the popover can show a friendly source label (e.g. "Spotify", "VLC",
/// "Safari", "Podcasts", "Audible").
///
/// We previously tried to call `MRMediaRemoteGetNowPlayingApplicationPID` via
/// `dlsym` on the private `MediaRemote.framework`, but the underlying
/// implementation (`MRMediaRemoteGetNowPlayingApplicationPIDForOrigin`)
/// dereferences internal state that is never populated for clients that
/// haven't been set up by the system, causing a hard crash even after
/// `MRMediaRemoteRegisterForNowPlayingNotifications`. The dlsym code is kept
/// as a probe so the debug UI can show the framework is reachable, but the
/// actual PID call is disabled.
///
/// The reliable detection path is `NSWorkspace.shared.runningApplications`:
/// for known apps (Spotify, Apple Music, Kaset) we match by bundle id, and
/// for unknown apps we fall back to the system label "Now Playing".
final class MediaRemoteClient {
    static let shared = MediaRemoteClient()

    /// True when the MediaRemote framework binary loaded successfully. Does
    /// not mean the PID getter is safe to call — see the comment above.
    private(set) var isMediaRemoteAvailable: Bool = false

    private let handle: UnsafeMutableRawObject?
    private let pidSymbolAddress: UnsafeMutableRawObject?
    private let displaySymbolAddress: UnsafeMutableRawObject?

    /// Bundle ids of apps we know how to detect via AppleScript if the
    /// MediaRemote dlsym path is unavailable. Order = priority.
    private let knownPublisherBundleIDs: [String] = [
        "com.spotify.client",
        "com.apple.Music",
        "com.sertacozercan.Kaset",
    ]

    private init() {
        // The MediaRemote framework binary is a small client dylib. Try a
        // few well-known locations; on some macOS releases the symlink under
        // Versions/A is intentionally broken and only the daemons in Support/
        // exist. dlopen returns nil in that case and we use the NSWorkspace
        // fallback.
        let candidatePaths = [
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "MediaRemote.framework/MediaRemote",
            "MediaRemote",
        ]

        var raw: UnsafeMutableRawObject?
        for path in candidatePaths {
            if let opened = dlopen(path, RTLD_LAZY) {
                raw = UnsafeMutableRawObject(opened)
                break
            }
        }

        self.handle = raw
        guard let raw else {
            NSLog("MediaRemoteClient: framework not loadable, using NSWorkspace fallback")
            self.pidSymbolAddress = nil
            self.displaySymbolAddress = nil
            return
        }

        let pidSymbol = dlsym(raw, "MRMediaRemoteGetNowPlayingApplicationPID")
        let displaySymbol = dlsym(raw, "MRMediaRemoteGetNowPlayingApplicationDisplayID")

        if pidSymbol == nil {
            NSLog("MediaRemoteClient: MRMediaRemoteGetNowPlayingApplicationPID not found")
        }
        if displaySymbol == nil {
            NSLog("MediaRemoteClient: MRMediaRemoteGetNowPlayingApplicationDisplayID not found")
        }

        // Keep the addresses for the debug UI; do NOT call them.
        // MRMediaRemoteGetNowPlayingApplicationPIDForOrigin crashes when
        // invoked from an unprivileged client. See class comment.
        self.pidSymbolAddress = pidSymbol
        self.displaySymbolAddress = displaySymbol
        self.isMediaRemoteAvailable = pidSymbol != nil
    }

    /// Returns the bundle id of the app currently publishing to the system
    /// Now Playing service, or `nil` if no app is publishing.
    ///
    /// Resolution order:
    /// 1. `NSWorkspace.shared.runningApplications` scan for known media apps
    /// 2. `nil`
    func currentPublisherBundleIdentifier() -> String? {
        detectKnownPublisherFromRunningApps()
    }

    /// Returns the localized name of the app currently publishing, e.g.
    /// "Spotify", "VLC", "Safari", "Podcasts". Falls back to "Now Playing"
    /// when no publisher is detected.
    func currentPublisherDisplayName() -> String {
        if let bundleID = currentPublisherBundleIdentifier(),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        return "Now Playing"
    }

    // MARK: - Debug

    /// Human-readable description of which detection path is active. Shown
    /// in the debug window.
    var detectionPathDescription: String {
        if isMediaRemoteAvailable {
            return "MediaRemote framework loaded (PID call disabled — known to crash on unprivileged clients). Using NSWorkspace scan."
        }
        return "MediaRemote framework not available. Using NSWorkspace scan."
    }

    // MARK: - Private

    /// Returns the bundle id of a known media app if it's running. Cheap,
    /// synchronous, safe. Synchronous means the orchestrator can call it on
    /// every poll without blocking the UI.
    private func detectKnownPublisherFromRunningApps() -> String? {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier }
        )
        for id in knownPublisherBundleIDs where runningBundleIDs.contains(id) {
            return id
        }
        return nil
    }
}
