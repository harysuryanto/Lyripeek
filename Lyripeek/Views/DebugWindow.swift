//
//  DebugWindow.swift
//  Lyripeek
//

import AppKit
import SwiftUI

/// Standalone window that displays the raw now-playing info, AppleScript
/// output, parsed times, and the raw LRC source.
///
/// Opened from the popover footer's info button. Lives in its own window
/// because presenting sheets from a popover is awkward on macOS.
struct DebugWindow: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService
    @EnvironmentObject private var lyricsService: LyricsService

    @State private var selectedTab: Tab = .nowPlaying

    enum Tab: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing"
        case appleScript = "AppleScript"
        case lrc = "Raw LRC"
        case about = "About"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Rectangle()
                                .fill(selectedTab == tab
                                      ? Color.accentColor.opacity(0.12)
                                      : Color.clear)
                        )
                        .overlay(alignment: .bottom) {
                            if selectedTab == tab {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .nowPlaying:
            ScrollView {
                Text(nowPlayingText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        case .appleScript:
            ScrollView {
                Text(appleScriptText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        case .lrc:
            ScrollView {
                Text(lyricsService.rawLRC.isEmpty
                     ? "<no LRC loaded>"
                     : lyricsService.rawLRC)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        case .about:
            AboutTab()
        }
    }

    // MARK: - Text builders

    private var nowPlayingText: String {
        var sections: [String] = []

        let info = nowPlayingService.rawNowPlayingInfo
        if info.isEmpty {
            sections.append("No now-playing info available.")
        } else {
            sections.append("MPNowPlayingInfoCenter:")
            sections += info
                .sorted { String(describing: $0.key) < String(describing: $1.key) }
                .map { "  \($0.key): \($0.value)" }
        }

        sections.append("")
        sections.append(String(format: "Parsed elapsed: %.2fs", nowPlayingService.lastParsedElapsedTime))
        sections.append(String(format: "Parsed duration: %.2fs", nowPlayingService.lastParsedDuration))

        return sections.joined(separator: "\n")
    }

    private var appleScriptText: String {
        var sections: [String] = []

        sections.append("Last AppleScript error:")
        sections.append(nowPlayingService.lastAppleScriptError.isEmpty
                        ? "  <none>"
                        : "  \(nowPlayingService.lastAppleScriptError)")

        sections.append("")
        sections.append("Spotify script output:")
        sections.append("  \(nowPlayingService.lastSpotifyOutput)")

        sections.append("")
        sections.append("Apple Music script output:")
        sections.append("  \(nowPlayingService.lastAppleMusicOutput)")

        sections.append("")
        sections.append("Kaset script output:")
        sections.append("  \(nowPlayingService.lastKasetOutput)")

        sections.append("")
        sections.append("Publisher detection:")
        sections.append("  \(MediaRemoteClient.shared.detectionPathDescription)")
        if let bundleID = nowPlayingService.sourceBundleIdentifier {
            sections.append("  Active publisher bundle id: \(bundleID)")
        } else {
            sections.append("  Active publisher bundle id: <unknown>")
        }

        return sections.joined(separator: "\n")
    }
}

// MARK: - About tab

/// First-party-style About panel: app icon, name, version, short
/// description, copyright, and links to the project and license.
struct AboutTab: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lyripeek"
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Hary Suryanto. All rights reserved."
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

            Text(appName)
                .font(.system(size: 20, weight: .semibold))

            Text("Version \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("A lightweight macOS menu-bar app that shows time-synced lyrics for the music you're currently playing.")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 4)

            Spacer(minLength: 4)

            VStack(spacing: 6) {
                Link("View on GitHub",
                     destination: URL(string: "https://github.com/harysuryanto/Lyripeek")!)
                    .font(.system(size: 12))

                Text("Licensed under the MIT License.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(copyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window host

/// Helper that materializes a dedicated `NSWindow` for the debug content.
///
/// Keeping this in SwiftUI makes the window resizable/full-size-content
/// style trivial while still using a real `NSWindow` (so it doesn't
/// disappear when the popover closes).
@MainActor
enum DebugWindowPresenter {
    private static var window: NSWindow?

    static func present(
        nowPlayingService: NowPlayingService,
        lyricsService: LyricsService
    ) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = DebugWindow()
            .environmentObject(nowPlayingService)
            .environmentObject(lyricsService)

        let host = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: host)
        newWindow.title = "Lyripeek — Debug Info"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.setContentSize(NSSize(width: 640, height: 480))
        newWindow.minSize = NSSize(width: 520, height: 360)
        newWindow.isReleasedWhenClosed = false
        newWindow.center()

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
