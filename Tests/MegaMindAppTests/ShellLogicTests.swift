import CoreGraphics
import DooraySync
import Foundation
import Testing
@testable import MegaMindApp

@Suite struct PanelPlacementTests {
    private let size = CGSize(width: 344, height: 400)
    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1415)

    private func frame(anchorMidX: CGFloat?, size: CGSize? = nil, screen: CGRect? = nil) -> CGRect {
        let screen = screen ?? self.screen
        let anchor = anchorMidX.map { CGRect(x: $0 - 30, y: screen.maxY, width: 60, height: 25) }
        return PanelPlacement.frame(contentSize: size ?? self.size, anchor: anchor, visibleFrame: screen)
    }

    @Test func hangsCenteredBelowTheStatusItem() {
        #expect(frame(anchorMidX: 1000) == CGRect(x: 828, y: 1009, width: 344, height: 400))
    }

    @Test func staysInsideTheScreenEdges() {
        #expect(frame(anchorMidX: 2550).minX == 2208)
        #expect(frame(anchorMidX: 20).minX == 8)
    }

    @Test func capsItsHeightToTheScreen() {
        #expect(frame(anchorMidX: 1000, size: CGSize(width: 344, height: 2000)) == CGRect(x: 828, y: 10, width: 344, height: 1399))
    }

    @Test func goesTopRightWhenTheStatusItemIsHidden() {
        #expect(frame(anchorMidX: nil) == CGRect(x: 2208, y: 1009, width: 344, height: 400))
    }

    @Test func worksOnADisplayWithANegativeOrigin() {
        let secondary = CGRect(x: -1049, y: 956, width: 2560, height: 1415)
        #expect(frame(anchorMidX: -70, screen: secondary) == CGRect(x: -242, y: 1965, width: 344, height: 400))
        #expect(frame(anchorMidX: nil, screen: secondary).maxX == secondary.maxX - 8)
    }
}

@Suite struct TitleLadderTests {
    @Test func startsWithTheFullTitle() {
        var ladder = TitleLadder()
        ladder.titleChanged(fullWidth: 180)
        #expect(ladder.form == .full)
    }

    @Test func stepsDownEachTimeTheItemIsHidden() {
        var ladder = TitleLadder()
        ladder.titleChanged(fullWidth: 180)
        ladder.itemWasHidden()
        #expect(ladder.form == .compact)
        ladder.itemWasHidden()
        #expect(ladder.form == .iconOnly)
        ladder.itemWasHidden()
        #expect(ladder.form == .iconOnly)
    }

    @Test func doesNotRetryATitleAsWideAsOneThatFailed() {
        var ladder = TitleLadder()
        ladder.titleChanged(fullWidth: 180)
        ladder.itemWasHidden()

        ladder.titleChanged(fullWidth: 200)
        #expect(ladder.form == .compact)
        ladder.titleChanged(fullWidth: 180)
        #expect(ladder.form == .compact)
        ladder.titleChanged(fullWidth: 120)
        #expect(ladder.form == .full)
    }

    @Test func remembersTheNarrowestFailure() {
        var ladder = TitleLadder()
        ladder.titleChanged(fullWidth: 180)
        ladder.itemWasHidden()
        ladder.titleChanged(fullWidth: 120)
        ladder.itemWasHidden()

        ladder.titleChanged(fullWidth: 150)
        #expect(ladder.form == .compact)
    }

    @Test func triesEveryFormAgainWhenTheMenuBarChanges() {
        var ladder = TitleLadder()
        ladder.titleChanged(fullWidth: 180)
        ladder.itemWasHidden()
        ladder.itemWasHidden()

        ladder.environmentChanged()
        #expect(ladder.form == .full)
        ladder.itemWasHidden()
        #expect(ladder.form == .compact)
    }
}

@Suite struct SettingsDraftTests {
    private let stored = Settings(
        apiBase: Settings.defaultAPIBase,
        webBase: URL(string: "https://old.dooray.com"),
        token: APIToken("stored-token")
    )

    private func validated(
        token: String = "",
        web: String = "acme",
        api: String = "https://api.dooray.com",
        keeping current: Settings? = nil
    ) -> Result<Settings, SettingsDraft.Problem> {
        SettingsDraft(token: token, webAddress: web, apiBase: api).validated(keeping: current ?? stored)
    }

    @Test(arguments: ["acme", "acme.dooray.com", "https://acme.dooray.com", " https://acme.dooray.com/project/1?x=1#top "])
    func webAddressNormalizesToTheTenantOrigin(_ typed: String) throws {
        #expect(try validated(web: typed).get().webBase?.absoluteString == "https://acme.dooray.com")
    }

    @Test func webAddressKeepsOtherDomains() throws {
        #expect(try validated(web: "work.gov-dooray.com").get().webBase?.absoluteString == "https://work.gov-dooray.com")
    }

    @Test(arguments: ["", "http://acme.dooray.com", "ftp://acme.dooray.com", "acme dooray"])
    func webAddressRejectsWhatIsNotAnHTTPSHost(_ typed: String) {
        #expect(validated(web: typed) == .failure(.webAddressInvalid))
    }

    @Test func apiBaseDropsTheTrailingSlashAndKeepsAPathPrefix() throws {
        #expect(try validated(api: "https://api.dooray.com/").get().apiBase.absoluteString == "https://api.dooray.com")
        #expect(try validated(api: "https://proxy.example.com/dooray/").get().apiBase.absoluteString == "https://proxy.example.com/dooray")
    }

    @Test(arguments: ["http://127.0.0.1:8765", "http://localhost:8765", "http://[::1]:8765"])
    func apiBaseAllowsPlainHTTPOnLoopback(_ typed: String) throws {
        #expect(try validated(api: typed).get().apiBase.absoluteString == typed)
    }

    @Test(arguments: ["http://api.dooray.com", "http://127.0.0.1.example.com", "api.dooray.com", ""])
    func apiBaseRejectsPlainHTTPElsewhere(_ typed: String) {
        #expect(validated(api: typed) == .failure(.apiBaseInvalid))
    }

    @Test func anEmptyTokenFieldKeepsTheStoredToken() throws {
        #expect(try validated(token: "").get().token == stored.token)
        #expect(try validated(token: " new-token ").get().token == APIToken("new-token"))
    }

    @Test func aTokenIsRequiredAndMustBeOneWord() {
        #expect(validated(token: "", keeping: .empty) == .failure(.tokenMissing))
        #expect(validated(token: "two words") == .failure(.tokenMalformed))
    }

    @Test func aValidDraftIsAlwaysComplete() throws {
        #expect(try validated(token: "new-token", keeping: .empty).get().isComplete)
    }
}
