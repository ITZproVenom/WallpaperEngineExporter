import XCTest
@testable import LumaForge

@MainActor
final class LumaForgeTests: XCTestCase {
    func testSteamIDValidation() {
        let u = URL(string: "lumaforge://steam-callback?state=test&openid.mode=id_res&openid.op_endpoint=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Flogin&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fprofiles%2F76561198000000000")!
        XCTAssertEqual(SteamOpenID.steamID(from: u, expectedState: "test"), "76561198000000000")
        XCTAssertNil(SteamOpenID.steamID(from: u, expectedState: "bad"))
    }

    func testWorkshopIDExtraction() {
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3547355412")!
        XCTAssertEqual(DownloadManager.workshopID(from: url), "3547355412")
    }

    func testWorkshopIDRejectsNonSteamURLs() {
        let url = URL(string: "https://example.com/sharedfiles/filedetails/?id=3547355412")!
        XCTAssertNil(DownloadManager.workshopID(from: url))
    }

    func testWorkshopIDRejectsMalformedIDs() {
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=abc")!
        XCTAssertNil(DownloadManager.workshopID(from: url))
    }
}
