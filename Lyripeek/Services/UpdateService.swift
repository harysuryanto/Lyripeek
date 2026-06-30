//
//  UpdateService.swift
//  Lyripeek
//

import AppKit
import Combine
import Foundation

/// Checks GitHub for a newer Lyripeek release and exposes a download URL.
///
/// The version source of truth is the repo's tags, read through the GitHub
/// `releases/latest` endpoint. A release's `tag_name` is a repo tag, and the
/// endpoint also returns the DMG asset's `browser_download_url`, so a single
/// request yields both the latest version and a download link. If no release
/// exists yet, the service falls back to the `tags` endpoint and constructs a
/// download URL from the highest semver tag.
///
/// The check runs once a day at 22:00 local time. A launch-time catch-up
/// checks immediately when the last check was more than 24 h ago (or never),
/// so a Mac that was asleep through 22:00 still gets checked. The result is
/// persisted to `UserDefaults` so the UI can render without a network round
/// trip on every popover open.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var releasePageURL: URL?
    @Published private(set) var isUpdateAvailable: Bool = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking: Bool = false

    private static let owner = "harysuryanto"
    private static let repo = "Lyripeek"

    private static let lastCheckedKey = "updateLastCheckedAt"
    private static let latestVersionKey = "updateLatestVersion"
    private static let downloadURLKey = "updateDownloadURL"
    private static let releasePageURLKey = "updateReleasePageURL"

    /// Minimum gap between checks. The daily 22:00 timer is the primary
    /// trigger; this guards the launch catch-up so a relaunch within the same
    /// day doesn't re-hit the API.
    private static let minCheckInterval: TimeInterval = 60 * 60 * 24 // 24 h

    /// The running app's marketing version (e.g. "0.1.0"), sourced from the
    /// `MARKETING_VERSION` build setting via `CFBundleShortVersionString`.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var dailyTimer: Timer?
    private var launchCatchUpTask: Task<Void, Never>?

    init() {
        loadPersistedState()
    }

    deinit {
        dailyTimer?.invalidate()
        launchCatchUpTask?.cancel()
    }

    /// Starts the daily 22:00 timer and performs the launch-time catch-up
    /// check when the last check is stale. Idempotent.
    func start() {
        scheduleNextDailyCheck()

        if let lastChecked {
            if Date().timeIntervalSince(lastChecked) >= Self.minCheckInterval {
                scheduleLaunchCatchUp()
            }
        } else {
            scheduleLaunchCatchUp()
        }
    }

    /// Forces a network check now, regardless of when the last check ran.
    func checkNow() {
        Task { [weak self] in
            await self?.performCheck()
        }
    }

    /// Opens the DMG download URL (or the release page, or the repo page) in
    /// the user's default browser.
    func openDownload() {
        let url = downloadURL ?? releasePageURL ?? Self.repositoryURL
        NSWorkspace.shared.open(url)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let defaults = UserDefaults.standard

        if let date = defaults.object(forKey: Self.lastCheckedKey) as? Date {
            lastChecked = date
        }
        latestVersion = defaults.string(forKey: Self.latestVersionKey)

        if let raw = defaults.string(forKey: Self.downloadURLKey) {
            downloadURL = URL(string: raw)
        }
        if let raw = defaults.string(forKey: Self.releasePageURLKey) {
            releasePageURL = URL(string: raw)
        }

        recomputeUpdateAvailable()
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(lastChecked, forKey: Self.lastCheckedKey)
        defaults.set(latestVersion, forKey: Self.latestVersionKey)
        defaults.set(downloadURL?.absoluteString, forKey: Self.downloadURLKey)
        defaults.set(releasePageURL?.absoluteString, forKey: Self.releasePageURLKey)
    }

    private func recomputeUpdateAvailable() {
        guard let latestVersion else {
            isUpdateAvailable = false
            return
        }
        isUpdateAvailable = Self.isNewer(latest: latestVersion, current: currentVersion)
    }

    // MARK: - Network

    private func performCheck() async {
        guard !isChecking else { return }
        isChecking = true

        let result = await Self.fetchLatestRelease()

        lastChecked = Date()

        if let result {
            latestVersion = result.version
            downloadURL = result.downloadURL
            releasePageURL = result.releasePageURL
        }

        recomputeUpdateAvailable()
        persistState()
        isChecking = false
    }

    /// Fetches the latest release from GitHub. Tries `releases/latest` (which
    /// returns the tag name and DMG asset URL in one request), falling back to
    /// the `tags` endpoint when no published release exists yet.
    nonisolated private static func fetchLatestRelease() async -> (version: String, downloadURL: URL?, releasePageURL: URL?)? {
        if let release = await fetchLatestReleaseEndpoint() {
            return release
        }
        return await fetchLatestTagEndpoint()
    }

    /// `GET /repos/{owner}/{repo}/releases/latest`. Returns the latest
    /// non-prerelease, non-draft release. Its `tag_name` is a repo tag.
    nonisolated private static func fetchLatestReleaseEndpoint() async -> (version: String, downloadURL: URL?, releasePageURL: URL?)? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            // 404 means no releases published yet — fall through to the tags
            // endpoint. Any other non-2xx is treated as a transient failure.
            guard (200..<300).contains(httpResponse.statusCode) else { return nil }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let version = parseVersion(from: release.tagName) else { return nil }

            let dmgAsset = release.assets?.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
            let downloadURL = dmgAsset.flatMap { URL(string: $0.browserDownloadURL) }
            let releasePageURL = URL(string: release.htmlURL)

            return (version, downloadURL, releasePageURL)
        } catch {
            return nil
        }
    }

    /// Fallback: `GET /repos/{owner}/{repo}/tags`. Picks the highest semver tag
    /// and constructs a download URL from the project's DMG naming convention
    /// (`Lyripeek-<version>.dmg`). The URL may 404 if a release/asset doesn't
    /// exist for that tag, in which case the browser will show GitHub's page.
    nonisolated private static func fetchLatestTagEndpoint() async -> (version: String, downloadURL: URL?, releasePageURL: URL?)? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/tags?per_page=100") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else { return nil }

            let tags = try JSONDecoder().decode([GitHubTag].self, from: data)
            let best = tags
                .compactMap { parseVersion(from: $0.name) }
                .max(by: { semverOrder($0, $1) == .orderedAscending })

            guard let best else { return nil }

            let downloadURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/download/v\(best)/Lyripeek-\(best).dmg")
            let releasePageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/v\(best)")
            return (best, downloadURL, releasePageURL)
        } catch {
            return nil
        }
    }

    // MARK: - Scheduling

    /// Arms a one-shot `Timer` for the next 22:00 local time. When it fires,
    /// it runs a check and re-arms for the following day. Re-arming on each
    /// fire (rather than a 24 h repeating timer) keeps the check aligned to
    /// 22:00 across daylight-saving boundaries.
    private func scheduleNextDailyCheck() {
        dailyTimer?.invalidate()

        let calendar = Calendar.current
        let components = DateComponents(hour: 22, minute: 0, second: 0)
        guard let fireDate = calendar.nextDate(
            after: Date(),
            matching: components,
            matchingPolicy: .nextTime
        ) else { return }

        let interval = max(1, fireDate.timeIntervalSinceNow)
        dailyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkNow()
                self?.scheduleNextDailyCheck()
            }
        }
        if let dailyTimer {
            RunLoop.main.add(dailyTimer, forMode: .common)
        }
    }

    /// Runs a check a few seconds after launch so the network call doesn't
    /// contend with cold-start work. Only triggers when the last check is
    /// stale (decided by the caller in `start`).
    private func scheduleLaunchCatchUp() {
        launchCatchUpTask?.cancel()
        launchCatchUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 s
            if Task.isCancelled { return }
            await MainActor.run {
                self?.checkNow()
            }
        }
    }

    // MARK: - Semver

    /// Returns the version string with a leading `v` stripped, or `nil` if the
    /// string isn't a plausible `X.Y[.Z]` version.
    nonisolated private static func parseVersion(from tag: String) -> String? {
        var trimmed = tag
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }), !parts.isEmpty, parts.count <= 3 else {
            return nil
        }
        return trimmed
    }

    /// True when `latest` is strictly newer than `current` per semver rules.
    /// Missing minor/patch components are treated as 0.
    nonisolated private static func isNewer(latest: String, current: String) -> Bool {
        semverOrder(latest, current) == .orderedDescending
    }

    /// Three-way semver comparison. Pads to three components so `1.2` == `1.2.0`.
    nonisolated private static func semverOrder(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(aParts.count, bParts.count, 3)
        for i in 0..<count {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai < bi { return .orderedAscending }
            if ai > bi { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Constants

    nonisolated private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Lyripeek/\(version)"
    }

    nonisolated private static var repositoryURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)")!
    }
}

// MARK: - GitHub Models

private struct GitHubRelease: Codable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct GitHubTag: Codable {
    let name: String
}
