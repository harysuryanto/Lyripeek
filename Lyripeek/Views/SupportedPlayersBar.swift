//
//  NowPlayingFromView.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import SwiftUI

/// Single-line "Playing from X" indicator shown between the lyrics and the
/// popover footer. Only renders when two or more known audio sources are
/// actively playing at the same time — the user already knows which app is
/// playing from the menu bar / NowPlayingCard in the single-player case.
struct NowPlayingFromView: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService

    var body: some View {
        Group {
            if shouldShow {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(labelText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shouldShow)
    }

    private var shouldShow: Bool {
        nowPlayingService.isMultipleActivePlayers
            && !nowPlayingService.title.isEmpty
    }

    /// "Playing from Spotify" for known sources, "Playing from Control Center"
    /// for the system fallback (Safari, VLC, etc.).
    private var labelText: String {
        let source = nowPlayingService.sourceDescription
        let cleaned = (source.isEmpty || source == "Now Playing")
            ? "Control Center"
            : source
        return "Playing from \(cleaned)"
    }
}
