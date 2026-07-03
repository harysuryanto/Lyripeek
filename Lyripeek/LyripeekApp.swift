//
//  LyripeekApp.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Combine
import SwiftUI

@main
struct LyripeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private let nowPlayingService = NowPlayingService()
    private let lyricsService = LyricsService()
    private let artworkService = ArtworkService()
    private let updateService = UpdateService()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "animateMenuBar": true
        ])

        // Load lyrics and artwork as soon as the playing track changes.
        nowPlayingService.trackChangedPublisher
            .sink { [weak self] track in
                guard let self else { return }
                self.lyricsService.loadLyrics(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration
                )
                // Skip the iTunes artwork fetch when the system already
                // provides artwork (e.g. Spotify and Apple Music).
                // For sources with a custom artwork URL (like Kaset), nowPlayingService.artwork
                // is explicitly set to nil, allowing us to load the custom URL directly.
                guard self.nowPlayingService.artwork == nil else { return }
                self.artworkService.load(
                    title: track.title,
                    artist: track.artist,
                    artworkURL: track.artworkURL
                )
            }
            .store(in: &cancellables)

        // Keep the menu-bar lyric line in sync with playback time, even when
        // the popover is closed.
        nowPlayingService.$elapsedTime
            .sink { [weak self] time in
                self?.lyricsService.updateCurrentLine(at: time)
            }
            .store(in: &cancellables)

        // When lyrics load after the current time is already known, pick the
        // correct line immediately.
        lyricsService.$lines
            .sink { [weak self] _ in
                self?.lyricsService.updateCurrentLine(
                    at: self?.nowPlayingService.elapsedTime ?? 0
                )
            }
            .store(in: &cancellables)

        // When the user changes the lyric offset, recompute the active line
        // immediately so the menu bar updates without waiting for the next
        // 10 Hz elapsedTime tick.
        lyricsService.$offset
            .sink { [weak self] _ in
                self?.lyricsService.updateCurrentLine(
                    at: self?.nowPlayingService.elapsedTime ?? 0
                )
            }
            .store(in: &cancellables)

        statusBarController.configure(
            nowPlayingService: nowPlayingService,
            lyricsService: lyricsService,
            artworkService: artworkService,
            updateService: updateService
        )

        // Start the daily 22:00 update check (with a launch-time catch-up
        // when the last check was more than 24 h ago).
        updateService.start()
    }
}
