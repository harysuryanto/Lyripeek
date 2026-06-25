//
//  LyripeekApp.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import SwiftUI

@main
struct LyripeekApp: App {
    @StateObject private var nowPlayingService = NowPlayingService()
    @StateObject private var lyricsService = LyricsService()

    var body: some Scene {
        MenuBarExtra("Lyripeek", systemImage: "music.note.list") {
            ContentView()
                .environmentObject(nowPlayingService)
                .environmentObject(lyricsService)
                .frame(minWidth: 360, minHeight: 480)
        }
        .menuBarExtraStyle(.window)
    }
}
