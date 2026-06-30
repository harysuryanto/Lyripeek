//
//  NowPlayingCard.swift
//  Lyripeek
//

import SwiftUI

/// The hero "Now Playing" card at the top of the popover.
///
/// Shows album artwork (or a gradient placeholder), track title, artist,
/// album + source, and a live progress bar.
struct NowPlayingCard: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService
    @EnvironmentObject private var artworkService: ArtworkService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                ArtworkTile(
                    artwork: displayArtwork,
                    isLoading: artworkService.isLoading && displayArtwork == nil,
                    seed: trackSeed
                )
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .help(displayTitle)

                    Text(displayArtist)
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(displayArtist)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .lineLimit(1)
                            .foregroundStyle(.secondary.opacity(0.85))
                            .help(subtitle)
                    }

                    TransportControls()
                }

                Spacer(minLength: 0)
            }

            ProgressBar(
                elapsed: nowPlayingService.elapsedTime,
                duration: nowPlayingService.duration
            )
        }
        .padding(20)
    }

    private var displayTitle: String {
        let title = nowPlayingService.title
        return title.isEmpty ? "No song detected" : title
    }

    private var displayArtist: String {
        let artist = nowPlayingService.artist
        return artist.isEmpty ? "Start playback in a supported music app" : artist
    }

    private var subtitle: String {
        let album = nowPlayingService.album
        let source = nowPlayingService.sourceDescription
        switch (album.isEmpty, source.isEmpty) {
        case (true, true): return ""
        case (false, true): return album
        case (true, false): return source
        case (false, false): return "\(album) • \(source)"
        }
    }

    private var trackSeed: String {
        "\(nowPlayingService.title)\(nowPlayingService.artist)"
    }

    /// Prefer the system-provided artwork (the same source the macOS
    /// Control Center Now Playing widget uses) and fall back to the
    /// iTunes Search API result when the system has none.
    private var displayArtwork: NSImage? {
        nowPlayingService.artwork ?? artworkService.artwork
    }
}

// MARK: - Artwork Tile

private struct ArtworkTile: View {
    let artwork: NSImage?
    let isLoading: Bool
    let seed: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(gradient)

            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }

            if isLoading && artwork == nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.001))
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .animation(.easeInOut(duration: 0.25), value: artwork)
    }

    private var gradient: LinearGradient {
        let palette: [(Color, Color)] = [
            (.purple, .indigo),
            (.pink, .purple),
            (.blue, .teal),
            (.orange, .pink),
            (.red, .orange),
            (.teal, .blue),
            (.indigo, .blue),
            (.green, .teal)
        ]
        let hash = abs(seed.hashValue)
        let pair = palette[hash % palette.count]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Progress Bar

private struct ProgressBar: View {
    let elapsed: TimeInterval
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.secondary.opacity(0.25))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progressFraction)
                }
            }
            .frame(height: 3)

            HStack {
                Text(format(elapsed))
                Spacer()
                Text(format(duration))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var progressFraction: CGFloat {
        guard duration > 0 else { return 0 }
        let fraction = elapsed / duration
        return CGFloat(max(0, min(1, fraction)))
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
