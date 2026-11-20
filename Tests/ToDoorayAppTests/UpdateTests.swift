import Foundation
import Testing
@testable import ToDoorayApp

private func version(_ text: String) throws -> AppVersion {
    try #require(AppVersion(text))
}

private func releaseFixture(_ name: String) throws -> Data {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "fixtures/releases/\(name)")
    return try Data(contentsOf: url)
}

private func latestFixture(replacing changes: [String: Any]) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: releaseFixture("latest.json")) as? [String: Any])
    object.merge(changes) { $1 }
    return try JSONSerialization.data(withJSONObject: object)
}

@Suite struct AppVersionTests {
    @Test func comparesEachPartAsANumber() throws {
        #expect(try version("1.10.0") > version("1.9.0"))
        #expect(try version("1.0.10") > version("1.0.9"))
        #expect(try version("2.0.0") > version("1.99.99"))
        #expect(try version("1.0.1") > version("1.0.0"))
        #expect(try !(version("1.0.1") > version("1.0.1")))
    }

    @Test func readsAReleaseTag() throws {
        #expect(try version("v1.0.1") == version("1.0.1"))
        #expect(try version("v1.10.0").description == "1.10.0")
    }

    @Test(arguments: ["", "1.0", "1.0.0.0", "v1", "1.0.0-beta", "V1.0.0", "vv1.0.0", " 1.0.0", "1.0.0\n", "a.b.c", "1..0", "99999999999999999999.0.0"])
    func rejectsAnythingElse(_ text: String) {
        #expect(AppVersion(text) == nil)
    }
}

@Suite struct ReleaseTests {
    @Test func picksTheDiskImage() throws {
        let release = try #require(Release(gitHubJSON: releaseFixture("latest.json")))
        #expect(release.version == (try version("9.9.9")))
        #expect(release.downloadURL.absoluteString == "https://github.com/megastudymobile/ToDooray/releases/download/v9.9.9/ToDooray-9.9.9.dmg")
        #expect(release.pageURL.absoluteString == "https://github.com/megastudymobile/ToDooray/releases/tag/v9.9.9")
    }

    @Test func fallsBackToTheReleasePageWithoutADiskImage() throws {
        let release = try #require(Release(gitHubJSON: releaseFixture("zip-only.json")))
        #expect(release.version == (try version("1.0.1")))
        #expect(release.downloadURL.absoluteString == "https://github.com/megastudymobile/ToDooray/releases/tag/v1.0.1")
    }

    @Test func ignoresADiskImageThatIsNotHTTPS() throws {
        let data = try latestFixture(replacing: ["assets": [
            ["name": "ToDooray-9.9.9.dmg", "browser_download_url": "file:///Applications/Calculator.app"],
        ]])
        let release = try #require(Release(gitHubJSON: data))
        #expect(release.downloadURL == release.pageURL)
    }

    @Test func refusesABadTagAPageThatIsNotHTTPSOrABodyThatIsNotARelease() throws {
        #expect(Release(gitHubJSON: try latestFixture(replacing: ["tag_name": "nightly"])) == nil)
        #expect(Release(gitHubJSON: try latestFixture(replacing: ["html_url": "http://example.com/release"])) == nil)
        #expect(Release(gitHubJSON: Data(#"{"message":"API rate limit exceeded"}"#.utf8)) == nil)
        #expect(Release(gitHubJSON: Data("<html>".utf8)) == nil)
    }
}

@Suite struct UpdateStatusTests {
    @Test func onlyANewerReleaseIsAnUpdate() throws {
        let release = try #require(Release(gitHubJSON: releaseFixture("latest.json")))
        #expect(UpdateStatus(latest: release, current: try version("9.8.10")) == .available(release))
        #expect(UpdateStatus(latest: release, current: try version("9.9.9")) == .upToDate)
        #expect(UpdateStatus(latest: release, current: try version("10.0.0")) == .upToDate)
    }
}

@Suite struct UpdatePolicyTests {
    private let launch = noon

    private func shouldCheck(secondsSinceLaunch: TimeInterval, secondsSinceLastAttempt: TimeInterval? = nil, inFlight: Bool = false) -> Bool {
        let now = launch.addingTimeInterval(secondsSinceLaunch)
        return UpdatePolicy.shouldCheck(
            inFlight: inFlight,
            launchedAt: launch,
            lastAttemptEnd: secondsSinceLastAttempt.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    @Test func firstChecksFiveSecondsAfterLaunch() {
        #expect(!shouldCheck(secondsSinceLaunch: 4))
        #expect(shouldCheck(secondsSinceLaunch: 5))
    }

    @Test func thenChecksEverySixHours() {
        let sixHours: TimeInterval = 6 * 60 * 60
        #expect(!shouldCheck(secondsSinceLaunch: 3 * sixHours, secondsSinceLastAttempt: sixHours - 1))
        #expect(shouldCheck(secondsSinceLaunch: 3 * sixHours, secondsSinceLastAttempt: sixHours))
    }

    @Test func neverStartsASecondCheck() {
        #expect(!shouldCheck(secondsSinceLaunch: 60, inFlight: true))
        #expect(!shouldCheck(secondsSinceLaunch: 3 * 24 * 60 * 60, secondsSinceLastAttempt: 2 * 24 * 60 * 60, inFlight: true))
    }
}

@Suite struct ReleaseFeedTests {
    private func config(_ json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "todooray-config-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    @Test func aHermeticRunWithoutAReleasesURLNeverChecks() throws {
        let path = try config(#"{"apiBase": "http://127.0.0.1:8765"}"#)
        #expect(ReleaseFeed(environment: ["TODOORAY_CONFIG": path, "TODOORAY_VERSION": "1.0.0"]) == nil)
    }

    @Test func theConfigFileCanPointAtTheMockServer() throws {
        let path = try config(#"{"releasesURL": "http://127.0.0.1:8765/releases/latest"}"#)
        let feed = try #require(ReleaseFeed(environment: ["TODOORAY_CONFIG": path, "TODOORAY_VERSION": "1.0.0"]))
        #expect(feed.url.absoluteString == "http://127.0.0.1:8765/releases/latest")
        #expect(feed.currentVersion == (try version("1.0.0")))
    }

    @Test func theEnvironmentWinsOverTheConfigFile() throws {
        let path = try config(#"{"releasesURL": "http://127.0.0.1:8765/releases/latest"}"#)
        let feed = try #require(ReleaseFeed(environment: [
            "TODOORAY_CONFIG": path,
            "TODOORAY_RELEASES_URL": "http://127.0.0.1:9/releases/latest",
            "TODOORAY_VERSION": "v2.3.4",
        ]))
        #expect(feed.url.absoluteString == "http://127.0.0.1:9/releases/latest")
        #expect(feed.currentVersion == (try version("2.3.4")))
    }

    @Test func anUnreadableVersionNeverChecks() {
        #expect(ReleaseFeed(environment: ["TODOORAY_RELEASES_URL": "http://127.0.0.1:9/", "TODOORAY_VERSION": "dev"]) == nil)
    }
}
