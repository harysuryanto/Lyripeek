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

/// C function pointer for `MRMediaRemoteSendCommand`, the private MediaRemote
/// entry point that dispatches a transport command to the active Now Playing
/// app. Signature: `void MRMediaRemoteSendCommand(MRCommand, NSDictionary*)`.
private typealias MRMediaRemoteSendCommandFunc = @convention(c) (Int32, NSDictionary?) -> Void

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
    private let sendCommandSymbolAddress: UnsafeMutableRawObject?

    /// Bundle ids of the apps Lyripeek knows how to enrich via AppleScript
    /// (Spotify, Apple Music, Kaset). Used for two purposes:
    /// 1. A friendly source label when the system track has no
    ///    `bundleIdentifier` (see `currentPublisherDisplayName`).
    /// 2. Gating AppleScript enrichment in `NowPlayingService.refresh()`: only
    ///    apps that are actually running get polled, so no `osascript`
    ///    subprocess is spawned when nothing is playing. Order is a
    ///    deterministic tiebreaker when more than one known app is running.
    private let knownPublisherLabelIDs: [String] = [
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
            self.sendCommandSymbolAddress = nil
            return
        }

        let pidSymbol = dlsym(raw, "MRMediaRemoteGetNowPlayingApplicationPID")
        let displaySymbol = dlsym(raw, "MRMediaRemoteGetNowPlayingApplicationDisplayID")
        let sendCommandSymbol = dlsym(raw, "MRMediaRemoteSendCommand")

        if pidSymbol == nil {
            NSLog("MediaRemoteClient: MRMediaRemoteGetNowPlayingApplicationPID not found")
        }
        if displaySymbol == nil {
            NSLog("MediaRemoteClient: MRMediaRemoteGetNowPlayingApplicationDisplayID not found")
        }
        if sendCommandSymbol == nil {
            NSLog("MediaRemoteClient: MRMediaRemoteSendCommand not found")
        }

        // Keep the addresses for the debug UI; do NOT call them.
        // MRMediaRemoteGetNowPlayingApplicationPIDForOrigin crashes when
        // invoked from an unprivileged client. See class comment.
        self.pidSymbolAddress = pidSymbol
        self.displaySymbolAddress = displaySymbol
        // `MRMediaRemoteSendCommand` is a different, commonly-invoked entry
        // point used by media-key remappers without crashes, so it IS safe to
        // call from `sendCommand(_:)` below.
        self.sendCommandSymbolAddress = sendCommandSymbol
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

    // MARK: - Transport commands

    /// Reverse-engineered `MRCommand` constants for the private MediaRemote
    /// `MRMediaRemoteSendCommand` entry point. These are not in any public
    /// header and were determined from widely-referenced MediaRemote reverse
    /// engineering; if a command misroutes, this is the place to adjust.
    private static let mrCommandTogglePlayPause: Int32 = 2
    private static let mrCommandNextTrack: Int32 = 4
    private static let mrCommandPreviousTrack: Int32 = 5

    /// Dispatches a transport command to the active Now Playing app via the
    /// private `MRMediaRemoteSendCommand`. Returns `true` when the symbol was
    /// loaded and the call was dispatched, `false` when the MediaRemote
    /// framework isn't available. Unlike the PID getter, this entry point is
    /// safe to call from unprivileged clients (it's the same one media-key
    /// remappers use) and routes to whichever app is currently publishing.
    func sendCommand(_ command: PlaybackCommand) -> Bool {
        guard let address = sendCommandSymbolAddress else { return false }
        let rawCommand: Int32
        switch command {
        case .playPause: rawCommand = Self.mrCommandTogglePlayPause
        case .nextTrack: rawCommand = Self.mrCommandNextTrack
        case .previousTrack: rawCommand = Self.mrCommandPreviousTrack
        }
        let fn = unsafeBitCast(address, to: MRMediaRemoteSendCommandFunc.self)
        fn(rawCommand, nil)
        return true
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

    /// Returns the bundle ids of all known media apps that are currently
    /// running. Cheap, synchronous, safe. Used by `NowPlayingService` to gate
    /// AppleScript enrichment: only apps that are actually running get polled,
    /// so no `osascript` subprocess is spawned when no supported music app is
    /// running.
    func runningKnownPublisherBundleIDs() -> Set<String> {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier }
        )
        return Set(knownPublisherLabelIDs.filter { runningBundleIDs.contains($0) })
    }

    /// Returns true if `bundleIdentifier` is one of the apps Lyripeek knows
    /// how to enrich via AppleScript (Spotify, Apple Music, Kaset). Used by
    /// the `NSWorkspace.didLaunchApplicationNotification` observer to decide
    /// whether to wake the poll loop when an app launches. Does not check
    /// whether the app is running — the observer already has the launching
    /// `NSRunningApplication`, so a static membership test is enough and
    /// avoids racing `runningApplications` being updated.
    func isKnownPublisher(_ bundleIdentifier: String) -> Bool {
        knownPublisherLabelIDs.contains(bundleIdentifier)
    }

    // MARK: - Private

    /// Returns the bundle id of a known media app if it's running. Cheap,
    /// synchronous, safe. Used only to provide a friendly source label —
    /// the orchestrator's track selection runs independently in
    /// `NowPlayingService.refresh()`. Iterates `knownPublisherLabelIDs` in
    /// order so the pick is deterministic when more than one known app is
    /// running.
    private func detectKnownPublisherFromRunningApps() -> String? {
        let running = runningKnownPublisherBundleIDs()
        for id in knownPublisherLabelIDs where running.contains(id) {
            return id
        }
        return nil
    }
}
