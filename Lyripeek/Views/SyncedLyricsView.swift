//
//  SyncedLyricsView.swift
//  Lyripeek
//

import Combine
import SwiftUI

/// Apple Music-style large, centered, auto-scrolling synced lyrics.
struct SyncedLyricsView: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService
    @EnvironmentObject private var lyricsService: LyricsService

    @StateObject private var scrollCoordinator = ScrollCoordinator()

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
                guard !scrollCoordinator.isAutoScrollPaused else { return }
                guard lyricsService.lines.indices.contains(newIndex) else { return }
                scrollToLine(newIndex, using: proxy)
            }
            .onChange(of: nowPlayingService.title) { _, _ in
                scrollCoordinator.isAutoScrollPaused = false
            }
            .onHover { scrollCoordinator.isHovered = $0 }
            .onAppear {
                scrollCoordinator.isAutoScrollPaused = false
                scrollToCurrent(using: proxy)
                scrollCoordinator.startMonitoring()
            }
            .onDisappear {
                scrollCoordinator.stopMonitoring()
            }
            .overlay(alignment: .bottom) {
                if scrollCoordinator.isAutoScrollPaused {
                    Button {
                        scrollCoordinator.isAutoScrollPaused = false
                        scrollToCurrent(using: proxy)
                    } label: {
                        syncButtonLabel
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .help("Resume auto-scroll and jump to the current lyric")
                }
            }
        }
    }

    // MARK: - Line

    @ViewBuilder
    private func lyricLineView(line: LyricLine, index: Int) -> some View {
        let isCurrent = index == currentIndex
        let distance = abs(index - currentIndex)
        let pastOpacity: Double = 0.45
        let futureOpacity: Double = index < currentIndex ? pastOpacity : (distance == 1 ? 0.7 : 0.45)
        let opacity: Double = isCurrent ? 1.0 : futureOpacity

        if isCurrent && !line.words.isEmpty {
            line.words.reduce(Text("")) { (result, word) -> Text in
                let isWordActive = nowPlayingService.elapsedTime >= (word.startTime)
                let wordColor = isWordActive ? Color.accentColor : Color.primary.opacity(0.45)
                let wordText = Text(word.text).foregroundColor(wordColor)
                return result + (result == Text("") ? Text("") : Text(" ")) + wordText
            }
            .font(.system(size: 17, weight: .semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(lineStyle(isCurrent: isCurrent, opacity: opacity))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .animation(.easeInOut(duration: 0.25), value: isCurrent)
        }
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

    // MARK: - Sync Button

    @ViewBuilder
    private var syncButtonLabel: some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "arrow.2.circlepath")
                .font(.system(size: 11))
            Text("Sync")
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)

        if #available(macOS 26, *) {
            content
                .glassEffect(.clear, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
        }
    }

    // MARK: - Scrolling

    private func scrollToLine(_ index: Int, using proxy: ScrollViewProxy) {
        guard lyricsService.lines.indices.contains(index) else { return }
        scrollCoordinator.performProgrammaticScroll {
            withAnimation(.easeInOut(duration: 0.4)) {
                proxy.scrollTo(lyricsService.lines[index].id, anchor: .center)
            }
        }
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy) {
        scrollToLine(currentIndex, using: proxy)
    }
}

// MARK: - ScrollCoordinator

extension SyncedLyricsView {
    final class ScrollCoordinator: ObservableObject {
        @Published var isAutoScrollPaused = false
        var isProgrammaticScroll = false
        var isHovered = false
        private var scrollMonitor: Any?

        func startMonitoring() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                guard event.scrollingDeltaY != 0 else { return event }
                guard self.isHovered, !self.isProgrammaticScroll else { return event }
                self.isAutoScrollPaused = true
                return event
            }
        }

        func stopMonitoring() {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
            }
            scrollMonitor = nil
        }

        func performProgrammaticScroll(_ animation: () -> Void) {
            isProgrammaticScroll = true
            animation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isProgrammaticScroll = false
            }
        }
    }
}
