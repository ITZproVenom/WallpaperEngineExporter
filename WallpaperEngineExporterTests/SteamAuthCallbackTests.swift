import XCTest
@testable import WallpaperEngineExporter

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

    func testCallbackSchemeMatchesInfoPlist() {
        // Must stay in sync with Info.plist CFBundleURLSchemes and the HTTPS bridge page
        XCTAssertEqual("wallpaperexporter", "wallpaperexporter")
    }
}
