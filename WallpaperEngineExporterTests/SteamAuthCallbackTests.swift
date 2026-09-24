import XCTest
@testable import WallpaperEngineExporter

final class SteamAuthCallbackTests: XCTestCase {
    func testClaimedIDExtraction() {
        let claimed = "https://steamcommunity.com/openid/id/76561198000000000"
        let steamID = claimed.split(separator: "/").last.map(String.init)
        XCTAssertEqual(steamID, "76561198000000000")
    }

    func testShortClaimedIDRejected() {
        let claimed = "https://steamcommunity.com/openid/id/123"
        let steamID = claimed.split(separator: "/").last.map(String.init) ?? ""
        XCTAssertTrue(steamID.count < 15)
    }
}
