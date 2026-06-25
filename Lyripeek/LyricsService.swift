//
//  LyricsService.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Combine
import Foundation

/// Loads and caches time-synced lyrics.
///
/// Currently uses a hardcoded mock LRC for testing. The same structure can be
/// extended later to fetch real LRC from a remote API without changing callers.
final class LyricsService: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var isLoading: Bool = false

    private var cache: [String: [LyricLine]] = [:]
    private var pendingKey: String?

    /// Hardcoded mock LRC used while no real lyrics API is implemented.
    private static let mockLRC = """
    [00:05.00]Line one
    [00:10.00]Line two
    [00:15.00]Line three
    """

    /// Loads lyrics for the given track. Results are cached by `artist + title`.
    func loadLyrics(title: String, artist: String) {
        let key = cacheKey(title: title, artist: artist)

        guard key != pendingKey else { return }
        pendingKey = key

        if let cached = cache[key] {
            lines = cached
            isLoading = false
            return
        }

        isLoading = true
        lines = []

        // Simulate a small async fetch so the UI can show a loading state.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let parsed = parseLRC(LyricsService.mockLRC)
            DispatchQueue.main.async {
                self?.cache[key] = parsed
                self?.lines = parsed
                self?.isLoading = false
                self?.pendingKey = nil
            }
        }
    }

    private func cacheKey(title: String, artist: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(normalizedArtist) - \(normalizedTitle)"
    }
}
