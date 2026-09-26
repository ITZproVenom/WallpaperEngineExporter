import XCTest
@testable import LumaForge

final class LumaForgeTests: XCTestCase {
    func testSteamIDValidation() {
        let callback=URL(string:"lumaforge://steam-callback?state=test&openid.mode=id_res&openid.op_endpoint=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Flogin&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fprofiles%2F76561198000000000")!
        XCTAssertEqual(SteamOpenID.steamID(from:callback,expectedState:"test"),"76561198000000000")
        XCTAssertNil(SteamOpenID.steamID(from:callback,expectedState:"wrong"))
    }
}
