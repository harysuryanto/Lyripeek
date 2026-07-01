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
    @Published private(set) var nextLineText: String = ""
    @Published private(set) var hasNoLyrics: Bool = false
    @Published private(set) var fetchFailed: Bool = false
    @Published private(set) var lastFetchURL: URL? = nil
    @Published private(set) var lyricsSource: String = ""

    // SWITCHABLE PROVIDER: Uncomment the provider you want to use.
    // private let provider: LyricsProvider = LRCLIBProvider()
    // private let provider: LyricsProvider = LyricaProvider()
    private let provider: LyricsProvider = LRCMuxProvider()

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

    /// Raw-LRC cache keyed by `artist - title - album`. The raw LRC is cached
    /// (not the parsed `[LyricLine]`) so that `LyricLine.id` (a `UUID`) stays
    /// stable only for the duration of a parse, and re-parse cost is
    /// negligible. Persisted to `~/Library/Caches/Lyripeek/lyrics-cache.json`
    /// so macOS can purge it under disk pressure.
    private var cache: [String: String] = [:]
    private var pendingKey: String?
    private var currentTrack: (title: String, artist: String, album: String, duration: TimeInterval)?

    /// True when there is an active track whose cache entry can be reset.
    var isResetAvailable: Bool { currentTrack != nil }

    #if DEBUG
    private static let cacheDirectoryName = "Lyripeek-Debug"
    #else
    private static let cacheDirectoryName = "Lyripeek"
    #endif
    private static let cacheFileName = "lyrics-cache.json"

    /// Loads lyrics for the given track. Results are cached on disk by
    /// `artist - title - album`.
    ///
    /// Fetches real synced lyrics from LRCLIB. If the request fails or returns
    /// no result, `lines` is left empty and nothing is cached, so a future
    /// fetch (or the reset button) can retry.
    func loadLyrics(title: String, artist: String, album: String, duration: TimeInterval) {
        let key = cacheKey(title: title, artist: artist, album: album)

        currentTrack = (title: title, artist: artist, album: album, duration: duration)
        lastFetchURL = provider.lyricsURL(title: title, artist: artist, album: album, duration: duration)

        guard key != pendingKey else { return }
        pendingKey = key

        if let cachedLRC = cache[key] {
            lines = parseLRC(cachedLRC)
            rawLRC = cachedLRC
            lyricsSource = extractSource(from: cachedLRC, fallback: "Cached")
            isLoading = false
            return
        }

        isLoading = true
        hasNoLyrics = false
        fetchFailed = false
        lyricsSource = ""
        lines = []
        rawLRC = ""

        Task { [weak self] in
            guard let provider = self?.provider else { return }
            do {
                if let result = try await provider.fetchLyrics(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                ) {
                    let (realLRC, source) = result
                    let parsed = parseLRC(realLRC)
                    await MainActor.run {
                        guard let self else { return }
                        let cachedLRCWithSource = "[re:\(source)]\n" + realLRC
                        self.cache[key] = cachedLRCWithSource
                        self.saveCacheToDisk()
                        self.lines = parsed
                        self.rawLRC = realLRC
                        self.lyricsSource = source.capitalized
                        self.isLoading = false
                        self.hasNoLyrics = parsed.isEmpty
                        self.fetchFailed = false
                        self.pendingKey = nil
                    }
                } else {
                    await MainActor.run {
                        self?.isLoading = false
                        self?.hasNoLyrics = true
                        self?.fetchFailed = false
                        self?.lyricsSource = ""
                        self?.pendingKey = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isLoading = false
                    self?.hasNoLyrics = false
                    self?.fetchFailed = true
                    self?.lyricsSource = ""
                    self?.pendingKey = nil
                }
            }
        }
    }

    /// Evicts the current track from both the in-memory and on-disk cache, then
    /// re-triggers a fresh fetch. No-op if no track is active.
    func resetCurrentLyrics() {
        guard let track = currentTrack else { return }
        let key = cacheKey(title: track.title, artist: track.artist, album: track.album)

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
            for: .cachesDirectory,
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

    // MARK: - Helper Methods

    /// Updates `currentLineText` to the lyric line active at `time`, taking
    /// the user-adjustable `offset` into account.
    func updateCurrentLine(at time: TimeInterval) {
        let index = currentLineIndex(lines: lines, currentTime: time - offset)
        guard lines.indices.contains(index) else {
            currentLineText = ""
            nextLineText = ""
            return
        }
        currentLineText = lines[index].text
        let nextIndex = index + 1
        nextLineText = lines.indices.contains(nextIndex) ? lines[nextIndex].text : ""
    }

    private func cacheKey(title: String, artist: String, album: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedAlbum = album.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(normalizedArtist) - \(normalizedTitle) - \(normalizedAlbum)"
    }

    private func extractSource(from lrc: String, fallback: String) -> String {
        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[re:") && line.hasSuffix("]") {
                let source = line.dropFirst(4).dropLast().trimmingCharacters(in: .whitespaces)
                if !source.isEmpty {
                    return source.capitalized
                }
            }
        }
        return fallback
    }
}

// MARK: - Lyrics Provider Architecture

protocol LyricsProvider {
    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> (lrc: String, source: String)?

    func lyricsURL(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> URL?
}

// MARK: - LRCLIB Provider

struct LRCLIBProvider: LyricsProvider {
    func lyricsURL(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> URL? {
        if duration > 0, !title.isEmpty || !artist.isEmpty {
            var components = URLComponents(string: "https://lrclib.net/api/get")!
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
            ]
            return components.url
        } else if !title.isEmpty || !artist.isEmpty {
            let query = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url
        }
        return nil
    }

    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> (lrc: String, source: String)? {
        if let exact = try await fetchExact(
            title: title,
            artist: artist,
            album: album,
            duration: duration
        ) {
            return (exact, "LRCLIB")
        }
        if let search = try await fetchSearch(title: title, artist: artist) {
            return (search, "LRCLIB")
        }
        return nil
    }

    private func fetchExact(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> String? {
        guard duration > 0 else { return nil }
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Lyripeek/0.1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(LRCLIBResult.self, from: data)
        return result.hasSyncedLyrics ? result.syncedLyrics : nil
    }

    private func fetchSearch(title: String, artist: String) async throws -> String? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let query = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Lyripeek/0.1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let results = try JSONDecoder().decode([LRCLIBResult].self, from: data)
        return results.first { $0.hasSyncedLyrics }?.syncedLyrics
    }

    private struct LRCLIBResult: Codable {
        let instrumental: Bool?
        let syncedLyrics: String?

        var hasSyncedLyrics: Bool {
            guard !(instrumental ?? false) else { return false }
            guard let syncedLyrics else { return false }
            return !syncedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Lyrica Provider

struct LyricaProvider: LyricsProvider {
    func lyricsURL(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> URL? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://test-0k.onrender.com/lyrics/")!
        components.queryItems = [
            URLQueryItem(name: "song", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "timestamps", value: "true")
        ]
        return components.url
    }

    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> (lrc: String, source: String)? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        var components = URLComponents(string: "https://test-0k.onrender.com/lyrics/")!
        components.queryItems = [
            URLQueryItem(name: "song", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "timestamps", value: "true")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Lyripeek/0.1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(LyricaResponse.self, from: data)
        guard let lyricaData = result.data,
              lyricaData.hasTimestamps == true,
              let lyrics = lyricaData.lyrics else {
            return nil
        }
        let source = result.source?.capitalized ?? "Lyrica"
        return (lyrics, source)
    }

    private struct LyricaResponse: Codable {
        let data: LyricaData?
        let status: String
        let source: String?
    }

    private struct LyricaData: Codable {
        let hasTimestamps: Bool?
        let lyrics: String?
    }
}

// MARK: - LRCMux Provider

struct LRCMuxProvider: LyricsProvider {
    func lyricsURL(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> URL? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrcmux.dev/api/get")!
        var queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "format", value: "lrc")
        ]
        if !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album", value: album))
        }
        if duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = queryItems
        return components.url
    }

    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> (lrc: String, source: String)? {
        guard let url = lyricsURL(title: title, artist: artist, album: album, duration: duration) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Lyripeek/0.1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let sourceHeader = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Source")
        let source = sourceHeader?.capitalized ?? "Lrcmux"
        return (text, source)
    }
}
