//
//  PopoverFooter.swift
//  Lyripeek
//

import SwiftUI

/// Compact, single-row control strip at the bottom of the popover.
///
/// Holds the lyric timing offset stepper, refetch button, menu-bar
/// animation toggle, and a button that opens the standalone debug window.
struct PopoverFooter: View {
    @EnvironmentObject private var lyricsService: LyricsService

    @AppStorage("animateMenuBar") private var animateMenuBar = true

    let offsetStep: TimeInterval = 0.2
    var onOpenDebug: () -> Void
    var onQuit: () -> Void = { }

    private let millisFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private var offsetMillisBinding: Binding<Double> {
        Binding(
            get: { lyricsService.offset * 1000 },
            set: { lyricsService.offset = $0 / 1000 }
        )
    }

    private var hasLyrics: Bool {
        !lyricsService.lines.isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            offsetControl
            Spacer(minLength: 4)
            refetchButton
            animateToggle
            debugButton
            quitButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Controls

    private var offsetControl: some View {
        HStack(spacing: 4) {
            Text("Offset")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                lyricsService.offset -= offsetStep
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Delay lyrics by 200 ms")
            .disabled(!hasLyrics)

            TextField("Offset", value: offsetMillisBinding, formatter: millisFormatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .frame(width: 52)
                .controlSize(.small)
                .disabled(!hasLyrics)
                .help("Lyric timing offset in milliseconds")

            Button {
                lyricsService.offset += offsetStep
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Advance lyrics by 200 ms")
            .disabled(!hasLyrics)
        }
    }

    private var refetchButton: some View {
        Button {
            lyricsService.resetCurrentLyrics()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(lyricsService.isLoading || !lyricsService.isResetAvailable)
        .help("Refetch lyrics (clears cache for this track)")
    }

    private var animateToggle: some View {
        Button {
            animateMenuBar.toggle()
        } label: {
            Image(systemName: "rectangle.arrowtriangle.2.outward")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(animateMenuBar ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help("Animate menu-bar lyric transitions")
    }

    private var debugButton: some View {
        Button(action: onOpenDebug) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Show debug info")
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Quit Lyripeek (⌘Q)")
    }
}
