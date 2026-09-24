import XCTest
@testable import WallpaperEngineExporter

final class WallpaperTypeTests: XCTestCase {
    func testExportable() {
        XCTAssertTrue(WallpaperType.video.isExportable)
        XCTAssertFalse(WallpaperType.scene.isExportable)
        XCTAssertFalse(WallpaperType.web.isExportable)
        XCTAssertFalse(WallpaperType.application.isExportable)
    }

    func testDisplayNames() {
        XCTAssertEqual(WallpaperType.video.displayName, "Video")
        XCTAssertEqual(WallpaperType.scene.displayName, "Scene")
    }
}
