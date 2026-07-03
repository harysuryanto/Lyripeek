//
//  ArtworkService.swift
//  Lyripeek
//

import AppKit
import Combine
import Foundation

/// Fetches album artwork from the public iTunes Search API and caches it
/// in memory and on disk.
///
/// The API is unauthenticated and returns a 100×100 artwork URL that we
/// upgrade to 600×600 by string replacement. We fall back silently on
/// failure so the popover always renders.
///
/// Disk cache lives under `~/Library/Caches/Lyripeek/Artwork/` so macOS can
/// purge it under disk pressure. A 200-image LRU cap (tracked via file
/// modification date) bounds steady-state disk usage. The in-memory cache
/// stays the fast path; disk is checked only on a memory miss.
@MainActor
final class ArtworkService: ObservableObject {
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String = ""

    private var cache: [String: NSImage] = [:]
    private var pendingKey: String?
    private var currentKey: String = ""

    func load(title: String, artist: String, artworkURL: String? = nil) {
        let key = cacheKey(title: title, artist: artist)
        currentKey = key

        if let cached = cache[key] {
            artwork = cached
            isLoading = false
            return
        }

        if key == pendingKey { return }
        pendingKey = key

        artwork = nil
        isLoading = true

        Task { [weak self] in
            // Disk hit: load bytes, decode, populate memory + publish.
            if let diskData = await Self.readFromDisk(key: key),
               let image = NSImage(data: diskData) {
                await MainActor.run {
                    guard let self else { return }
                    self.cache[key] = image
                    self.isLoading = false
                    self.pendingKey = nil
                    if self.currentKey == key {
                        self.artwork = image
                    }
                }
                // LRU: mark as recently accessed.
                await Self.touchDiskFile(key: key)
                return
            }

            // Disk miss (or corrupt file): fetch.
            let data: Data?
            if let artworkURL {
                let upgraded = Self.upgradeArtworkURL(artworkURL)
                if let url = URL(string: upgraded) {
                    data = await Self.fetchArtworkFromURL(url)
                } else {
                    data = nil
                }
            } else {
                data = await Self.fetchArtworkData(title: title, artist: artist)
            }

            await MainActor.run {
                guard let self else { return }
                self.isLoading = false
                self.pendingKey = nil
                if let data, let image = NSImage(data: data) {
                    self.cache[key] = image
                    if self.currentKey == key {
                        self.artwork = image
                    }
                } else if self.currentKey == key {
                    self.artwork = nil
                }
            }

            // Persist to disk + evict oldest if over cap.
            if let data {
                await Self.writeToDisk(data: data, key: key)
            }
        }
    }

    func clear() {
        artwork = nil
        isLoading = false
        currentKey = ""
    }

    private func cacheKey(title: String, artist: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(normalizedArtist) - \(normalizedTitle)"
    }

    // MARK: - Disk cache

    #if DEBUG
    nonisolated private static let cacheDirectoryName = "Lyripeek-Debug"
    #else
    nonisolated private static let cacheDirectoryName = "Lyripeek"
    #endif
    nonisolated private static let artworkDirectoryName = "Artwork"
    nonisolated private static let maxDiskImages = 200

    /// Returns the on-disk artwork cache directory, creating it if needed.
    /// `nonisolated` because `FileManager` is thread-safe and this is called
    /// from background `Task` paths.
    nonisolated private static var artworkCacheDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent(cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(artworkDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Filesystem-safe, stable slug for a cache key. Unlike
    /// `String.hashValue` (randomized per launch), this is deterministic so
    /// the same track always maps to the same file across launches.
    nonisolated private static func slugify(_ key: String) -> String {
        var slug = ""
        var count = 0
        let maxLength = 80
        for char in key.lowercased() {
            if char.isLetter || char.isNumber {
                slug.append(char)
            } else if slug.last != "_" {
                slug.append("_")
            }
            count += 1
            if count >= maxLength { break }
        }
        if slug.hasSuffix("_") { slug.removeLast() }
        return slug.isEmpty ? "unknown" : slug
    }

    nonisolated private static func diskFileURL(for key: String) -> URL? {
        guard let dir = artworkCacheDirectory else { return nil }
        return dir.appendingPathComponent("\(slugify(key)).dat")
    }

    nonisolated private static func readFromDisk(key: String) async -> Data? {
        guard let url = diskFileURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Updates the file's modification date so the LRU eviction order reflects
    /// recent access, not just write order.
    nonisolated private static func touchDiskFile(key: String) async {
        guard let url = diskFileURL(for: key) else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    nonisolated private static func writeToDisk(data: Data, key: String) async {
        guard let url = diskFileURL(for: key) else { return }
        try? data.write(to: url, options: [.atomic])
        evictIfNeeded()
    }

    /// Deletes the oldest files (by modification date) until the directory
    /// holds at most `maxDiskImages` entries. Called only after a network
    /// write, so the hot path (memory/disk hit) pays no enumeration cost.
    nonisolated private static func evictIfNeeded() {
        guard let dir = artworkCacheDirectory else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        guard files.count > maxDiskImages else { return }

        let sorted = files.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate < bDate
        }

        for url in sorted.prefix(files.count - maxDiskImages) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - iTunes API

    nonisolated private static func fetchArtworkData(title: String, artist: String) async -> Data? {
        let query = "\(artist) \(title)"
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Lyripeek/0.1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let results = try JSONDecoder().decode([ITunesResult].self, from: data)
            guard let raw = results.first?.artworkUrl100,
                  let upgraded = raw.replacingOccurrences(
                    of: "100x100",
                    with: "600x600"
                  ) as String?,
                  let imageURL = URL(string: upgraded) else {
                return nil
            }

            let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
            guard let imageResponse = imageResponse as? HTTPURLResponse,
                  (200..<300).contains(imageResponse.statusCode),
                  !imageData.isEmpty else {
                return nil
            }
            return imageData
        } catch {
            return nil
        }
    }

    nonisolated private static func upgradeArtworkURL(_ urlString: String) -> String {
        var upgraded = urlString
        // Upgrade Google/YouTube usercontent artwork URLs to higher resolution if possible.
        // E.g., "=w60-h60-l90-rj" -> "=w600-h600-l90-rj"
        // or "=w120-h120" -> "=w600-h600"
        // or "=s90-c" -> "=s600-c"
        if upgraded.contains("googleusercontent.com") || upgraded.contains("ytimg.com") {
            // Replace =w\d+-h\d+ with =w600-h600
            if let regex = try? NSRegularExpression(pattern: "([?&]|=)w\\d+-h\\d+", options: []) {
                let range = NSRange(upgraded.startIndex..., in: upgraded)
                upgraded = regex.stringByReplacingMatches(in: upgraded, options: [], range: range, withTemplate: "$1w600-h600")
            }
            // Also handle =s\d+ (e.g. =s90) -> =s600
            if let regex = try? NSRegularExpression(pattern: "([?&]|=)s\\d+", options: []) {
                let range = NSRange(upgraded.startIndex..., in: upgraded)
                upgraded = regex.stringByReplacingMatches(in: upgraded, options: [], range: range, withTemplate: "$1s600")
            }
        }
        return upgraded
    }

    nonisolated private static func fetchArtworkFromURL(_ url: URL) async -> Data? {
        var urlsToTry: [URL] = [url]
        let urlString = url.absoluteString
        if urlString.contains("ytimg.com") && urlString.contains("/default.jpg") {
            if let maxresURL = URL(string: urlString.replacingOccurrences(of: "/default.jpg", with: "/maxresdefault.jpg")) {
                urlsToTry.insert(maxresURL, at: 0)
            }
            if let hqURL = URL(string: urlString.replacingOccurrences(of: "/default.jpg", with: "/hqdefault.jpg")) {
                if urlsToTry.count > 1 {
                    urlsToTry.insert(hqURL, at: 1)
                } else {
                    urlsToTry.insert(hqURL, at: 0)
                }
            }
        }

        for candidateURL in urlsToTry {
            var request = URLRequest(url: candidateURL)
            request.setValue("Lyripeek/0.1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 6
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode),
                   !data.isEmpty {
                    return data
                }
            } catch {
                // Continue to next candidate
            }
        }
        return nil
    }
}

private struct ITunesResult: Codable {
    let artworkUrl100: String?
}
