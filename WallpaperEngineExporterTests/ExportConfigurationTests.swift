import XCTest
@testable import WallpaperEngineExporter

final class ExportConfigurationTests: XCTestCase {
    func testDefaultConfig() {
        let config = ExportConfiguration()
        XCTAssertEqual(config.resolution, .original)
        XCTAssertEqual(config.fps, .fps30)
        XCTAssertEqual(config.codec, .h264)
        XCTAssertEqual(config.quality, .high)
    }

    func testResolutionSize() {
        let original = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(ExportResolution.p1080.size(for: original), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ExportResolution.original.size(for: original), original)
    }
}
