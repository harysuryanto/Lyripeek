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
                self.artworkService.load(
                    title: track.title,
                    artist: track.artist
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

        statusBarController.configure(
            nowPlayingService: nowPlayingService,
            lyricsService: lyricsService,
            artworkService: artworkService
        )
    }
}
