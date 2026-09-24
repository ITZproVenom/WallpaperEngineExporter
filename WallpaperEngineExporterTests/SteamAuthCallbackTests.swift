import XCTest
@testable import WallpaperEngineExporter

@MainActor
final class SteamAuthCallbackTests: XCTestCase {
    func testClaimedIDExtraction() {
        let claimed = "https://steamcommunity.com/openid/id/76561198000000000"
        let steamID = SteamAuthenticationService.steamID(fromClaimedID: claimed)
        XCTAssertEqual(steamID, "76561198000000000")
    }

    func testShortClaimedIDRejected() {
        let claimed = "https://steamcommunity.com/openid/id/123"
        XCTAssertNil(SteamAuthenticationService.steamID(fromClaimedID: claimed))
    }

    func testNonNumericClaimedIDRejected() {
        let claimed = "https://steamcommunity.com/openid/id/notasteamid"
        XCTAssertNil(SteamAuthenticationService.steamID(fromClaimedID: claimed))
    }

    func testCallbackSchemeConstant() {
        XCTAssertEqual(SteamAuthenticationService.callbackScheme, "wallpaperexporter")
    }

    func testReturnToIsHTTPS() {
        XCTAssertTrue(SteamAuthenticationService.httpsReturnTo.hasPrefix("https://"))
        XCTAssertFalse(SteamAuthenticationService.httpsReturnTo.contains("jsdelivr"))
    }

    func testFinishedAssertionDetection() {
        var c = URLComponents(string: SteamAuthenticationService.httpsReturnTo)!
        c.queryItems = [
            URLQueryItem(name: "openid.mode", value: "id_res"),
            URLQueryItem(name: "openid.claimed_id", value: "https://steamcommunity.com/openid/id/76561198000000000")
        ]
        let url = c.url!
        XCTAssertTrue(SteamAuthenticationService.isFinishedOpenIDAssertion(url))
        XCTAssertTrue(SteamAuthenticationService.isOpenIDReturnURL(url))
    }

    func testIntermediateURLNotFinished() {
        var c = URLComponents(string: "https://steamcommunity.com/openid/login")!
        c.queryItems = [URLQueryItem(name: "openid.mode", value: "checkid_setup")]
        XCTAssertFalse(SteamAuthenticationService.isFinishedOpenIDAssertion(c.url!))
    }
}
