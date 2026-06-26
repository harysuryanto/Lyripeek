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
/// Fetches real LRC from LRCLIB (https://lrclib.net) when possible, and falls
/// back to a hardcoded mock LRC when the network request fails or returns no
/// results.
final class LyricsService: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var fallbackToMock: Bool = false
    @Published private(set) var rawLRC: String = ""
    @Published private(set) var currentLineText: String = ""

    /// Playback time offset applied when looking up the active lyric line.
    /// Positive values delay lyrics; negative values make them appear earlier.
    /// Stored in seconds; the UI presents the value in milliseconds.
    @Published var offset: TimeInterval = 0

    private var cache: [String: [LyricLine]] = [:]
    private var pendingKey: String?

    /// Hardcoded mock LRC used as a fallback.
    private static let mockLRC = """
    [00:05.00]Line one
    [00:10.00]Line two
    [00:15.00]Line three
    """

    /// Loads lyrics for the given track. Results are cached by `artist + title`.
    ///
    /// First attempts to fetch real synced lyrics from LRCLIB. If that fails or
    /// returns nothing, the mock LRC is used and `fallbackToMock` is set.
    func loadLyrics(title: String, artist: String, album: String, duration: TimeInterval) {
        let key = cacheKey(title: title, artist: artist)

        guard key != pendingKey else { return }
        pendingKey = key

        if let cached = cache[key] {
            lines = cached
            isLoading = false
            fallbackToMock = false
            return
        }

        isLoading = true
        lines = []
        fallbackToMock = false
        rawLRC = ""

        Task { [weak self] in
            let realLRC = await Self.fetchLRCLIBLyrics(title: title, artist: artist)
            let sourceLRC = realLRC ?? LyricsService.mockLRC
            let parsed = parseLRC(sourceLRC)

            await MainActor.run {
                self?.cache[key] = parsed
                self?.lines = parsed
                self?.rawLRC = sourceLRC
                self?.isLoading = false
                self?.fallbackToMock = (realLRC == nil)
                self?.pendingKey = nil
            }
        }
    }

    // MARK: - LRCLIB API

    /// Searches LRCLIB for the track and returns the synced LRC text, or `nil`
    /// if nothing is found or the request fails.
    nonisolated private static func fetchLRCLIBLyrics(title: String, artist: String) async -> String? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let query = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Lyripeek/1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let results = try JSONDecoder().decode([LRCLIBResult].self, from: data)
            return results.first { $0.hasSyncedLyrics }?.syncedLyrics
        } catch {
            return nil
        }
    }

    /// Updates `currentLineText` to the lyric line active at `time`, taking
    /// the user-adjustable `offset` into account.
    func updateCurrentLine(at time: TimeInterval) {
        let index = currentLineIndex(lines: lines, currentTime: time - offset)
        guard lines.indices.contains(index) else {
            currentLineText = ""
            return
        }
        currentLineText = lines[index].text
    }

    private func cacheKey(title: String, artist: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(normalizedArtist) - \(normalizedTitle)"
    }
}

// MARK: - LRCLIB Models

private struct LRCLIBResult: Codable {
    let id: Int
    let name: String?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    nonisolated var hasSyncedLyrics: Bool {
        guard !(instrumental ?? false) else { return false }
        guard let syncedLyrics else { return false }
        return !syncedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
