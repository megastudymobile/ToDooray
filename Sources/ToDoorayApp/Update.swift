import Foundation

/// `MAJOR.MINOR.PATCH`, compared numerically, so 1.10.0 is newer than 1.9.0.
struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Accepts a release tag's leading `v` and nothing else around the three numbers.
    init?(_ text: String) {
        guard let match = text.wholeMatch(of: /v?([0-9]+)\.([0-9]+)\.([0-9]+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

struct Release: Equatable {
    let version: AppVersion
    /// The `.dmg` asset, or the release page when the release has none.
    let downloadURL: URL
    let pageURL: URL

    /// Parses GitHub's latest-release JSON. These URLs are later opened with NSWorkspace, so
    /// anything but https is refused.
    init?(gitHubJSON data: Data) {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        struct Payload: Decodable {
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data),
              let version = AppVersion(payload.tagName),
              payload.htmlUrl.scheme == "https" else { return nil }
        let dmg = payload.assets.first { $0.name.hasSuffix(".dmg") && $0.browserDownloadUrl.scheme == "https" }
        self.version = version
        pageURL = payload.htmlUrl
        downloadURL = dmg?.browserDownloadUrl ?? payload.htmlUrl
    }
}

enum UpdateStatus: Equatable {
    /// No check has succeeded yet. A failed check leaves any status as it was.
    case unknown
    case upToDate
    case available(Release)

    init(latest: Release, current: AppVersion) {
        self = latest.version > current ? .available(latest) : .upToDate
    }

    var release: Release? {
        if case .available(let release) = self { release } else { nil }
    }
}

enum UpdatePolicy {
    static let launchDelay: TimeInterval = 5
    /// GitHub allows 60 unauthenticated requests an hour per IP address, and teammates on
    /// one office network share that address.
    static let interval: TimeInterval = 6 * 60 * 60

    /// Level-triggered like `RefreshPolicy.shouldSync`: the minute heartbeat asks, so a long
    /// sleep delays a check but never loses it. A failed check counts as an attempt.
    static func shouldCheck(inFlight: Bool, launchedAt: Date, lastAttemptEnd: Date?, now: Date) -> Bool {
        if inFlight { return false }
        guard let lastAttemptEnd else { return now.timeIntervalSince(launchedAt) >= launchDelay }
        return now.timeIntervalSince(lastAttemptEnd) >= interval
    }
}

/// Where the latest release is asked for, and which version is running.
struct ReleaseFeed {
    static let gitHubLatest = URL(string: "https://api.github.com/repos/megastudymobile/ToDooray/releases/latest")!

    let url: URL
    let currentVersion: AppVersion

    /// nil means no check ever runs. In Debug, `TODOORAY_RELEASES_URL` or the `releasesURL`
    /// key of the `TODOORAY_CONFIG` file replaces GitHub, and a config file without either
    /// turns checks off so a hermetic run never leaves the machine. `TODOORAY_VERSION` pins
    /// the running version.
    init?(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        var url = Self.gitHubLatest
        var versionText = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #if DEBUG
        if let pinned = environment["TODOORAY_VERSION"] {
            versionText = pinned
        }
        if let override = environment["TODOORAY_RELEASES_URL"] {
            guard let parsed = URL(string: override) else { return nil }
            url = parsed
        } else if let path = environment["TODOORAY_CONFIG"] {
            struct ConfigFile: Decodable { let releasesURL: URL? }
            guard let data = FileManager.default.contents(atPath: path),
                  let configured = (try? JSONDecoder().decode(ConfigFile.self, from: data))?.releasesURL else { return nil }
            url = configured
        }
        #endif
        guard let currentVersion = versionText.flatMap(AppVersion.init) else { return nil }
        self.url = url
        self.currentVersion = currentVersion
    }

    /// nil for any failure: no network, a non-200 answer, or a body that is not a release.
    func latest() async -> Release? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("ToDooray/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Release(gitHubJSON: data)
    }
}
