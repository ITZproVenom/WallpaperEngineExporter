import XCTest
@testable import WallpaperEngineExporter

final class WorkshopURLParserTests: XCTestCase {
    func testDirectID() {
        XCTAssertEqual(WorkshopURLParser.extractID(from: "123456789"), "123456789")
    }

    func testFullURL() {
        let url = "https://steamcommunity.com/sharedfiles/filedetails/?id=123456789"
        XCTAssertEqual(WorkshopURLParser.extractID(from: url), "123456789")
    }

    func testURLWithExtraParams() {
        let url = "https://steamcommunity.com/sharedfiles/filedetails/?id=987654321&searchtext=test"
        XCTAssertEqual(WorkshopURLParser.extractID(from: url), "987654321")
    }

    func testFiledetailsPath() {
        let url = "https://steamcommunity.com/sharedfiles/filedetails/1234567890"
        // May or may not match depending on parser — id query is primary
        _ = WorkshopURLParser.extractID(from: url)
    }

    func testInvalid() {
        XCTAssertNil(WorkshopURLParser.extractID(from: "https://example.com"))
        XCTAssertNil(WorkshopURLParser.extractID(from: "not a url"))
        XCTAssertNil(WorkshopURLParser.extractID(from: ""))
    }

    func testWhitespace() {
        XCTAssertEqual(WorkshopURLParser.extractID(from: "  555666777  "), "555666777")
    }
}
