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
    @State private var hoveredLineId: UUID? = nil

    var body: some View {
        let currentIndex = currentLineIndex(
            lines: lyricsService.lines,
            currentTime: nowPlayingService.elapsedTime - lyricsService.offset
        )
        Group {
            if lyricsService.isLoading {
                loadingState
            } else if lyricsService.lines.isEmpty {
                emptyState
            } else {
                lyricsList(currentIndex: currentIndex)
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

    private func lyricsList(currentIndex: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: lyricsService.isSynced ? 4 : 8) {
                    // Spacer at the top so the first lines don't get cut off
                    // when scrolled to .center.
                    Color.clear.frame(height: lyricsService.isSynced ? 40 : 12).id("top-spacer")

                    ForEach(Array(lyricsService.lines.enumerated()), id: \.element.id) { index, line in
                        if lyricsService.isSynced {
                            lyricLineView(line: line, index: index, currentIndex: currentIndex)
                                .id(line.id)
                        } else {
                            unsyncedLyricLineView(line: line)
                                .id(line.id)
                        }
                    }

                    if !lyricsService.attributionText.isEmpty {
                        Text(lyricsService.attributionText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity)
                    }

                    Color.clear.frame(height: lyricsService.isSynced ? 40 : 12).id("bottom-spacer")
                }
                .padding(.horizontal, 24)
                .animation(lyricsService.isSynced ? .easeInOut(duration: 0.35) : nil, value: currentIndex)
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard lyricsService.isSynced else { return }
                guard !scrollCoordinator.isAutoScrollPaused else { return }
                guard lyricsService.lines.indices.contains(newIndex) else { return }
                scrollToLine(newIndex, using: proxy)
            }
            .onChange(of: nowPlayingService.title) { _, _ in
                scrollCoordinator.isAutoScrollPaused = false
            }
            .onHover { scrollCoordinator.isHovered = $0 }
            .onAppear {
                guard lyricsService.isSynced else { return }
                scrollCoordinator.isAutoScrollPaused = false
                scrollToLine(currentIndex, using: proxy)
                scrollCoordinator.startMonitoring()
            }
            .onDisappear {
                scrollCoordinator.stopMonitoring()
            }
            .overlay(alignment: .bottom) {
                if lyricsService.isSynced && scrollCoordinator.isAutoScrollPaused {
                    Button {
                        scrollCoordinator.isAutoScrollPaused = false
                        scrollToLine(currentIndex, using: proxy)
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
    private func lyricLineView(line: LyricLine, index: Int, currentIndex: Int) -> some View {
        let isCurrent = index == currentIndex
        let isHovered = hoveredLineId == line.id
        let distance = abs(index - currentIndex)
        let pastOpacity: Double = 0.45
        let futureOpacity: Double = index < currentIndex ? pastOpacity : (distance == 1 ? 0.7 : 0.45)
        let baseOpacity: Double = isCurrent ? 1.0 : futureOpacity
        let opacity: Double = isHovered ? min(1.0, baseOpacity + 0.25) : baseOpacity

        Group {
            if isCurrent && !line.words.isEmpty {
                CenterFlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(line.words) { word in
                        let isWordActive = nowPlayingService.elapsedTime >= word.startTime
                        Text(word.text)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(isWordActive ? Color.accentColor : Color.primary.opacity(0.45))
                            .animation(.easeOut(duration: 0.2), value: isWordActive)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            } else {
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(.system(size: 18, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(lineStyle(isCurrent: isCurrent, opacity: opacity))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
        }
        .scaleEffect(isCurrent ? 1.06 : (isHovered ? 0.98 : 0.94))
        .animation(.spring(response: 0.4, dampingFraction: 0.75, blendDuration: 0), value: isCurrent)
        .animation(.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0), value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            nowPlayingService.seek(to: line.time + lyricsService.offset)
        }
        .onHover { isHovering in
            if isHovering {
                hoveredLineId = line.id
            } else {
                if hoveredLineId == line.id {
                    hoveredLineId = nil
                }
            }
        }
    }

    @ViewBuilder
    private func unsyncedLyricLineView(line: LyricLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
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

// MARK: - CenterFlowLayout

struct CenterFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > width && currentLineWidth > 0 {
                totalHeight += currentLineHeight + lineSpacing
                currentLineWidth = size.width
                currentLineHeight = size.height
            } else {
                currentLineWidth += size.width + (currentLineWidth > 0 ? spacing : 0)
                currentLineHeight = max(currentLineHeight, size.height)
            }
        }
        totalHeight += currentLineHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var lines: [[(LayoutSubview, CGSize)]] = [[]]
        var lineWidths: [CGFloat] = [0]
        var lineHeights: [CGFloat] = [0]
        
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var lineIndex = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > width && currentLineWidth > 0 {
                lines.append([])
                lineWidths.append(0)
                lineHeights.append(0)
                lineIndex += 1
                currentLineWidth = 0
                currentLineHeight = 0
            }
            lines[lineIndex].append((subview, size))
            currentLineWidth += size.width + (lines[lineIndex].count > 1 ? spacing : 0)
            currentLineHeight = max(currentLineHeight, size.height)
            lineWidths[lineIndex] = currentLineWidth
            lineHeights[lineIndex] = currentLineHeight
        }
        
        var y = bounds.minY
        for i in 0..<lines.count {
            let line = lines[i]
            let lineWidth = lineWidths[i]
            let lineHeight = lineHeights[i]
            
            // Center alignment
            var x = bounds.minX + (width - lineWidth) / 2
            
            for (subview, size) in line {
                // Center vertically within the line height
                let subviewY = y + (lineHeight - size.height) / 2
                subview.place(at: CGPoint(x: x, y: subviewY), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
