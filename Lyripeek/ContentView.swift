//
//  ContentView.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService
    @EnvironmentObject private var lyricsService: LyricsService
    @EnvironmentObject private var artworkService: ArtworkService
    @EnvironmentObject private var updateService: UpdateService

    var onOpenDebug: () -> Void = { }
    var onQuit: () -> Void = { }

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingCard()
                .environmentObject(nowPlayingService)
                .environmentObject(artworkService)

            Divider()

            SyncedLyricsView()
                .environmentObject(nowPlayingService)
                .environmentObject(lyricsService)

            Divider()

            PopoverFooter(onOpenDebug: onOpenDebug, onQuit: onQuit)
                .environmentObject(lyricsService)
                .environmentObject(updateService)
        }
        .frame(minWidth: 420, minHeight: 400)
    }
}

#Preview {
    ContentView()
        .environmentObject(NowPlayingService())
        .environmentObject(LyricsService())
        .environmentObject(ArtworkService())
        .environmentObject(UpdateService())
}
