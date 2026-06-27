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
/// Fetches real LRC from LRCLIB (https://lrclib.net). When the network
/// request fails or returns no synced lyrics, `lines` stays empty.
final class LyricsService: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var rawLRC: String = ""
    @Published private(set) var currentLineText: String = ""

    private static let offsetDefaultsKey = "lyricsOffset"

    /// Playback time offset applied when looking up the active lyric line.
    /// Positive values delay lyrics; negative values make them appear earlier.
    /// Stored in seconds; the UI presents the value in milliseconds.
    /// Persisted to `UserDefaults` so the value survives across app launches.
    @Published var offset: TimeInterval {
        didSet {
            UserDefaults.standard.set(offset, forKey: Self.offsetDefaultsKey)
        }
    }

    init() {
        self.offset = UserDefaults.standard.double(forKey: Self.offsetDefaultsKey)
        loadCacheFromDisk()
    }

    /// Raw-LRC cache keyed by `artist - title`. The raw LRC is cached (not the
    /// parsed `[LyricLine]`) so that `LyricLine.id` (a `UUID`) stays stable
    /// only for the duration of a parse, and re-parse cost is negligible.
    private var cache: [String: String] = [:]
    private var pendingKey: String?
    private var currentTrack: (title: String, artist: String, album: String, duration: TimeInterval)?

    /// True when there is an active track whose cache entry can be reset.
    var isResetAvailable: Bool { currentTrack != nil }

    private static let cacheDirectoryName = "Lyripeek"
    private static let cacheFileName = "lyrics-cache.json"

    /// Loads lyrics for the given track. Results are cached on disk by
    /// `artist + title`.
    ///
    /// Fetches real synced lyrics from LRCLIB. If the request fails or returns
    /// no result, `lines` is left empty and nothing is cached, so a future
    /// fetch (or the reset button) can retry.
    func loadLyrics(title: String, artist: String, album: String, duration: TimeInterval) {
        let key = cacheKey(title: title, artist: artist)

        currentTrack = (title: title, artist: artist, album: album, duration: duration)

        guard key != pendingKey else { return }
        pendingKey = key

        if let cachedLRC = cache[key] {
            lines = parseLRC(cachedLRC)
            rawLRC = cachedLRC
            isLoading = false
            return
        }

        isLoading = true
        lines = []
        rawLRC = ""

        Task { [weak self] in
            guard let realLRC = await Self.fetchLRCLIBLyrics(title: title, artist: artist) else {
                await MainActor.run {
                    self?.isLoading = false
                    self?.pendingKey = nil
                }
                return
            }

            let parsed = parseLRC(realLRC)

            await MainActor.run {
                guard let self else { return }
                self.cache[key] = realLRC
                self.saveCacheToDisk()
                self.lines = parsed
                self.rawLRC = realLRC
                self.isLoading = false
                self.pendingKey = nil
            }
        }
    }

    /// Evicts the current track from both the in-memory and on-disk cache, then
    /// re-triggers a fresh fetch. No-op if no track is active.
    func resetCurrentLyrics() {
        guard let track = currentTrack else { return }
        let key = cacheKey(title: track.title, artist: track.artist)

        cache.removeValue(forKey: key)
        saveCacheToDisk()

        pendingKey = nil
        loadLyrics(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration
        )
    }

    // MARK: - Disk cache

    private func cacheFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let directory = base.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func loadCacheFromDisk() {
        guard let url = cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func saveCacheToDisk() {
        guard let url = cacheFileURL(),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
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
        request.setValue("Lyripeek/0.1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")

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
