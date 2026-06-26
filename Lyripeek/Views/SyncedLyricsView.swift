//
//  SyncedLyricsView.swift
//  Lyripeek
//

import SwiftUI

/// Apple Music-style large, centered, auto-scrolling synced lyrics.
struct SyncedLyricsView: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService
    @EnvironmentObject private var lyricsService: LyricsService

    private var currentIndex: Int {
        currentLineIndex(
            lines: lyricsService.lines,
            currentTime: nowPlayingService.elapsedTime - lyricsService.offset
        )
    }

    var body: some View {
        Group {
            if lyricsService.isLoading {
                loadingState
            } else if lyricsService.lines.isEmpty {
                emptyState
            } else {
                lyricsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .top)
        .onChange(of: nowPlayingService.elapsedTime) { _, newTime in
            lyricsService.updateCurrentLine(at: newTime)
        }
        .onChange(of: lyricsService.offset) { _, _ in
            lyricsService.updateCurrentLine(at: nowPlayingService.elapsedTime)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Fetching lyrics…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(lyricsService.isResetAvailable
                 ? "No lyrics found for this track"
                 : "No lyrics available")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    // Spacer at the top so the first lines don't get cut off
                    // when scrolled to .center.
                    Color.clear.frame(height: 40).id("top-spacer")

                    ForEach(Array(lyricsService.lines.enumerated()), id: \.element.id) { index, line in
                        lyricLineView(line: line, index: index)
                            .id(line.id)
                    }

                    Color.clear.frame(height: 40).id("bottom-spacer")
                }
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.35), value: currentIndex)
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard lyricsService.lines.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lyricsService.lines[newIndex].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Line

    private func lyricLineView(line: LyricLine, index: Int) -> some View {
        let isCurrent = index == currentIndex
        let distance = abs(index - currentIndex)
        let pastOpacity: Double = 0.45
        let futureOpacity: Double = index < currentIndex ? pastOpacity : (distance == 1 ? 0.7 : 0.45)
        let opacity: Double = isCurrent ? 1.0 : futureOpacity

        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(lineStyle(isCurrent: isCurrent, opacity: opacity))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }

    /// Active line uses the system accent color at full opacity; all other
    /// lines use the primary text color with a distance-based opacity so the
    /// current line stands out without changing glyph metrics.
    private func lineStyle(isCurrent: Bool, opacity: Double) -> AnyShapeStyle {
        if isCurrent {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(Color.primary.opacity(opacity))
    }
}
