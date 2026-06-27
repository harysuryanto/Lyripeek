//
//  ArtworkService.swift
//  Lyripeek
//

import AppKit
import Combine
import Foundation

/// Fetches album artwork from the public iTunes Search API and caches it
/// in memory for the lifetime of the app.
///
/// The API is unauthenticated and returns a 100×100 artwork URL that we
/// upgrade to 600×600 by string replacement. We fall back silently on
/// failure so the popover always renders.
@MainActor
final class ArtworkService: ObservableObject {
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String = ""

    private var cache: [String: NSImage] = [:]
    private var pendingKey: String?
    private var currentKey: String = ""

    func load(title: String, artist: String) {
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
            let image = await Self.fetchArtwork(title: title, artist: artist)

            await MainActor.run {
                guard let self else { return }
                self.isLoading = false
                self.pendingKey = nil
                if let image {
                    self.cache[key] = image
                    // Only publish if the track hasn't changed during fetch.
                    if self.currentKey == key {
                        self.artwork = image
                    }
                } else {
                    if self.currentKey == key {
                        self.artwork = nil
                    }
                }
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

    nonisolated private static func fetchArtwork(title: String, artist: String) async -> NSImage? {
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
                  let image = NSImage(data: imageData) else {
                return nil
            }
            return image
        } catch {
            return nil
        }
    }
}

private struct ITunesResult: Codable {
    let artworkUrl100: String?
}
