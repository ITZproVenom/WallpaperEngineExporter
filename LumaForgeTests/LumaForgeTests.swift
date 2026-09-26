import XCTest
@testable import LumaForge

final class LumaForgeTests: XCTestCase {
    func testSteamIDValidation() {
        XCTAssertTrue(SteamOpenIDValidator.isValidSteamID("76561198000000000"))
        XCTAssertFalse(SteamOpenIDValidator.isValidSteamID("123"))
        XCTAssertFalse(SteamOpenIDValidator.isValidSteamID("abc"))
    }

    func testBinaryAssetScannerFindsPNG() throws {
        let png = Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x01,0x02,0x03])
        let assets = BinaryAssetScanner.scan(png)
        XCTAssertEqual(assets.first?.kind, .png)
        XCTAssertEqual(assets.first?.data.count, png.count)
    }
}
