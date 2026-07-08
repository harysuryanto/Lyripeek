//
//  TransportControls.swift
//  Lyripeek
//

import SwiftUI

/// Previous / Play-Pause / Next transport buttons shown beneath the Now
/// Playing progress bar.
///
/// Routing of the command to the active player is handled by
/// `NowPlayingService.sendPlaybackCommand`; this view only reflects state and
/// fires commands. All three buttons are disabled when no track is active —
/// the app has no queue visibility, so we can't tell whether a prev/next track
/// exists and instead let the source app no-op when there's nothing to skip
/// to.
struct TransportControls: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService

    var body: some View {
        HStack(spacing: 16) {
            Button {
                nowPlayingService.sendPlaybackCommand(.previousTrack)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.borderless)
            .disabled(!nowPlayingService.hasActiveTrack)
            .help("Previous track")

            Button {
                nowPlayingService.sendPlaybackCommand(.playPause)
            } label: {
                Image(systemName: nowPlayingService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(!nowPlayingService.hasActiveTrack)
            .help(nowPlayingService.isPlaying ? "Pause" : "Play")

            Button {
                nowPlayingService.sendPlaybackCommand(.nextTrack)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.borderless)
            .disabled(!nowPlayingService.hasActiveTrack)
            .help("Next track")

            Button {
                nowPlayingService.rewind5Seconds()
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.borderless)
            .disabled(!nowPlayingService.hasActiveTrack)
            .help("Rewind 5 seconds")
        }
        .animation(.easeInOut(duration: 0.2), value: nowPlayingService.isPlaying)
    }
}
