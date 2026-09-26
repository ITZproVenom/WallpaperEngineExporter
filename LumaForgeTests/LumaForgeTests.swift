import XCTest
@testable import LumaForge

final class LumaForgeTests: XCTestCase {
    func testSteamIDValidation() {
        let u = URL(string: "lumaforge://steam-callback?state=test&openid.mode=id_res&openid.op_endpoint=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Flogin&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fprofiles%2F76561198000000000")!
        XCTAssertEqual(SteamOpenID.steamID(from: u, expectedState: "test"), "76561198000000000")
        XCTAssertNil(SteamOpenID.steamID(from: u, expectedState: "bad"))
    }

    func testHTMLDownloadCandidateExtraction() {
        let html = """
        <html>
          <a class="download" href="/files/scene.pkg">Download</a>
          <a href="https://example.com/landing">Other</a>
        </html>
        """
        let base = URL(string: "https://example.com/page")!
        let urls = DownloadManager.extractDownloadCandidates(from: html, baseURL: base)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/files/scene.pkg")
    }

    func testHTMLDownloadCandidateEntityDecoding() {
        let html = #"<a data-download-url="https://cdn.example.com/file.pkg?x=1&amp;y=2">Download</a>"#
        let base = URL(string: "https://example.com/page")!
        let urls = DownloadManager.extractDownloadCandidates(from: html, baseURL: base)
        XCTAssertEqual(urls.first?.absoluteString, "https://cdn.example.com/file.pkg?x=1&y=2")
    }
}
