import Foundation

struct OrbitAvailableUpdateInfo: Equatable {
    let versionTag: String
    let releaseURL: URL
}

final class OrbitUpdateChecker {
    private struct GitHubLatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }

    private enum DefaultsKeys {
        static let lastCheckedAt = "orbit.update.lastCheckedAt"
        static let latestVersionTag = "orbit.update.latestVersionTag"
        static let latestReleaseURL = "orbit.update.latestReleaseURL"
        static let dismissedVersionTag = "orbit.update.dismissedVersionTag"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let repository: String
    private let minimumCheckInterval: TimeInterval

    init(
        repository: String = "nikitakavka/orbit",
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        minimumCheckInterval: TimeInterval = 60 * 60 * 12
    ) {
        self.repository = repository
        self.defaults = defaults
        self.session = session
        self.minimumCheckInterval = minimumCheckInterval
    }

    func currentAppVersion(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cachedAvailableUpdate(forCurrentVersion currentVersion: String) -> OrbitAvailableUpdateInfo? {
        guard let latestTag = defaults.string(forKey: DefaultsKeys.latestVersionTag),
              let latestURLRaw = defaults.string(forKey: DefaultsKeys.latestReleaseURL),
              let latestURL = URL(string: latestURLRaw),
              isVersion(latestTag, newerThan: currentVersion),
              !isDismissed(versionTag: latestTag) else {
            return nil
        }

        return OrbitAvailableUpdateInfo(versionTag: latestTag, releaseURL: latestURL)
    }

    func dismiss(versionTag: String) {
        defaults.set(versionTag, forKey: DefaultsKeys.dismissedVersionTag)
    }

    func checkForUpdate(currentVersion: String, force: Bool) async -> OrbitAvailableUpdateInfo? {
        guard shouldCheckNow(force: force) else {
            return cachedAvailableUpdate(forCurrentVersion: currentVersion)
        }

        defer {
            defaults.set(Date(), forKey: DefaultsKeys.lastCheckedAt)
        }

        guard let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return cachedAvailableUpdate(forCurrentVersion: currentVersion)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OrbitMenuBar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return cachedAvailableUpdate(forCurrentVersion: currentVersion)
            }

            let latest = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
            guard !latest.draft, !latest.prerelease else {
                return cachedAvailableUpdate(forCurrentVersion: currentVersion)
            }

            let latestTag = latest.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latestTag.isEmpty else {
                return cachedAvailableUpdate(forCurrentVersion: currentVersion)
            }

            let releaseURL = URL(string: latest.html_url)
                ?? URL(string: "https://github.com/\(repository)/releases")

            if let releaseURL {
                defaults.set(latestTag, forKey: DefaultsKeys.latestVersionTag)
                defaults.set(releaseURL.absoluteString, forKey: DefaultsKeys.latestReleaseURL)

                if isVersion(latestTag, newerThan: currentVersion), !isDismissed(versionTag: latestTag) {
                    return OrbitAvailableUpdateInfo(versionTag: latestTag, releaseURL: releaseURL)
                }
            }

            return nil
        } catch {
            return cachedAvailableUpdate(forCurrentVersion: currentVersion)
        }
    }

    private func shouldCheckNow(force: Bool) -> Bool {
        if force { return true }

        guard let lastCheckedAt = defaults.object(forKey: DefaultsKeys.lastCheckedAt) as? Date else {
            return true
        }

        return Date().timeIntervalSince(lastCheckedAt) >= minimumCheckInterval
    }

    private func isDismissed(versionTag: String) -> Bool {
        defaults.string(forKey: DefaultsKeys.dismissedVersionTag) == versionTag
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        compareVersions(lhs, rhs) == .orderedDescending
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let lhsComponents = versionComponents(from: lhs),
              let rhsComponents = versionComponents(from: rhs) else {
            return lhs.localizedStandardCompare(rhs)
        }

        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for idx in 0..<maxCount {
            let left = idx < lhsComponents.count ? lhsComponents[idx] : 0
            let right = idx < rhsComponents.count ? rhsComponents[idx] : 0

            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }

        return .orderedSame
    }

    private func versionComponents(from raw: String) -> [Int]? {
        guard let range = raw.range(of: #"\d+(?:\.\d+)*"#, options: .regularExpression) else {
            return nil
        }

        let token = raw[range]
        let components = token
            .split(separator: ".")
            .compactMap { Int($0) }

        return components.isEmpty ? nil : components
    }
}
