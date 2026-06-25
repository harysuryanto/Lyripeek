//
//  ContentView.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService
    @EnvironmentObject private var lyricsService: LyricsService

    @State private var demoMode = false
    @State private var demoElapsedTime: TimeInterval = 0
    @State private var demoTimer: AnyCancellable?

    private var effectiveElapsedTime: TimeInterval {
        demoMode ? demoElapsedTime : nowPlayingService.elapsedTime
    }

    private var currentIndex: Int {
        currentLineIndex(lines: lyricsService.lines, currentTime: effectiveElapsedTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.vertical, 8)
            lyricsSection
            Divider()
                .padding(.vertical, 8)
            debugSection
            quitButton
        }
        .padding()
        .frame(minWidth: 360, minHeight: 480)
        .onAppear(perform: loadLyricsForCurrentTrack)
        .onReceive(nowPlayingService.trackChangedPublisher) { track in
            lyricsService.loadLyrics(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration
            )
        }
        .onChange(of: demoMode) { _, isDemo in
            isDemo ? startDemoTimer() : stopDemoTimer()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(1)

                Text(displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !sourceDescription.isEmpty {
                    Text(sourceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("Demo", isOn: $demoMode)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Simulate playback when no music is detected")
        }
    }

    private var displayTitle: String {
        let title = nowPlayingService.title
        return title.isEmpty ? "No song detected" : title
    }

    private var displayArtist: String {
        let artist = nowPlayingService.artist
        return artist.isEmpty ? "Start playback or enable Demo" : artist
    }

    private var sourceDescription: String {
        if demoMode { return "Demo source" }
        return nowPlayingService.sourceDescription
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsSection: some View {
        VStack(spacing: 8) {
            lyricsStatusLabel
                .padding(.bottom, 4)

            if lyricsService.isLoading {
                Spacer()
                ProgressView("Loading lyrics…")
                Spacer()
            } else if lyricsService.lines.isEmpty {
                Spacer()
                Text("No lyrics available")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                lyricsList
            }
        }
    }

    private var lyricsStatusLabel: some View {
        Group {
            if lyricsService.isLoading {
                Text("Fetching lyrics…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if lyricsService.fallbackToMock {
                Text("Real lyrics unavailable — showing test lyrics")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !lyricsService.lines.isEmpty {
                Text("Synced lyrics loaded")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                EmptyView()
            }
        }
    }

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(lyricsService.lines.enumerated()), id: \.element.id) { index, line in
                        lyricLineView(line: line, index: index)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard lyricsService.lines.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lyricsService.lines[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private func lyricLineView(line: LyricLine, index: Int) -> some View {
        Text(line.text)
            .font(.system(size: 15, weight: weight(for: index)))
            .foregroundStyle(color(for: index))
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
    }

    private func weight(for index: Int) -> Font.Weight {
        index == currentIndex ? .bold : .regular
    }

    private func color(for index: Int) -> Color {
        if index == currentIndex {
            return .accentColor
        } else if index < currentIndex {
            return .secondary.opacity(0.55)
        } else {
            return .primary.opacity(0.85)
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        DisclosureGroup("Debug raw info") {
            ScrollView {
                Text(debugText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 100)
        }
        .controlSize(.small)
    }

    private var quitButton: some View {
        Button("Quit Lyripeek") {
            NSApplication.shared.terminate(nil)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private var debugText: String {
        var sections: [String] = []

        let info = nowPlayingService.rawNowPlayingInfo
        if info.isEmpty {
            sections.append("No now-playing info available.")
        } else {
            sections.append("NowPlayingInfoCenter:")
            sections += info
                .sorted { String(describing: $0.key) < String(describing: $1.key) }
                .map { "  \($0.key): \($0.value)" }
        }

        sections.append("")
        sections.append("AppleScript error:")
        if nowPlayingService.lastAppleScriptError.isEmpty {
            sections.append("  <none>")
        } else {
            sections.append("  \(nowPlayingService.lastAppleScriptError)")
        }

        sections.append("")
        sections.append("Parsed elapsed: \(String(format: "%.2f", nowPlayingService.lastParsedElapsedTime))s")
        sections.append("Parsed duration: \(String(format: "%.2f", nowPlayingService.lastParsedDuration))s")

        sections.append("")
        sections.append("Spotify script output: \(nowPlayingService.lastSpotifyOutput)")
        sections.append("Apple Music script output: \(nowPlayingService.lastAppleMusicOutput)")

        sections.append("")
        sections.append("Raw LRC source:")
        if lyricsService.rawLRC.isEmpty {
            sections.append("  <empty>")
        } else {
            sections.append("  \(lyricsService.rawLRC)")
        }

        return sections.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func loadLyricsForCurrentTrack() {
        lyricsService.loadLyrics(
            title: nowPlayingService.title,
            artist: nowPlayingService.artist,
            album: nowPlayingService.album,
            duration: nowPlayingService.duration
        )
    }

    private func startDemoTimer() {
        demoElapsedTime = 0
        demoTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                demoElapsedTime += 1.0
                // Loop the demo so it stays interesting.
                if demoElapsedTime > 25 {
                    demoElapsedTime = 0
                }
            }
    }

    private func stopDemoTimer() {
        demoTimer?.cancel()
        demoTimer = nil
        demoElapsedTime = 0
    }
}

#Preview {
    ContentView()
        .environmentObject(NowPlayingService())
        .environmentObject(LyricsService())
}
