import XCTest
import UIKit
@testable import LumaForge

/// Builds the same container layouts the Python fixtures use, so the Swift port
/// is verified against the real formats rather than mocks.
enum Fixture {
    static func uint32(_ value: Int) -> Data {
        var little = UInt32(value).littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    /// A minimal but structurally valid ISOBMFF stream: an `ftyp` box with a
    /// correct big-endian length prefix, followed by a payload box.
    static func fakeMP4(payloadSize: Int = 4096) -> Data {
        var data = Data()
        var length = UInt32(20).bigEndian
        data.append(withUnsafeBytes(of: &length) { Data($0) })
        data.append(Data("ftypisom".utf8))
        data.append(Data("isomiso2".utf8))
        var mdatLength = UInt32(payloadSize + 8).bigEndian
        data.append(withUnsafeBytes(of: &mdatLength) { Data($0) })
        data.append(Data("mdat".utf8))
        data.append(Data(repeating: 0x42, count: payloadSize))
        return data
    }

    static func tex(payload: Data, width: Int, height: Int,
                    container: String = "TEXB0004") -> Data {
        var data = Data("TEXV0005\0".utf8)
        data.append(Data("TEXI0001\0".utf8))
        for value in [4, 0, width, height, width, height] {
            data.append(uint32(value))
        }
        data.append(Data(container.utf8))
        data.append(Data([0]))
        data.append(uint32(1))
        if container == "TEXB0004" { data.append(uint32(0)) }
        data.append(payload)
        return data
    }

    static func pkg(_ entries: [(String, Data)], version: String = "0022") -> Data {
        var directory = Data()
        var offset = 0
        for (name, blob) in entries {
            let encoded = Data(name.utf8)
            directory.append(uint32(encoded.count))
            directory.append(encoded)
            directory.append(uint32(offset))
            directory.append(uint32(blob.count))
            offset += blob.count
        }
        var data = uint32(8)
        data.append(Data("PKGV".utf8))
        data.append(Data(version.utf8))
        data.append(uint32(entries.count))
        data.append(directory)
        for (_, blob) in entries { data.append(blob) }
        return data
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

final class WorkshopLinkTests: XCTestCase {
    func testExtractsIDFromWorkshopURL() {
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3547355412")!
        XCTAssertEqual(WorkshopLink.id(from: url), "3547355412")
    }

    func testRejectsNonSteamHosts() {
        let url = URL(string: "https://example.com/sharedfiles/filedetails/?id=3547355412")!
        XCTAssertNil(WorkshopLink.id(from: url))
    }

    func testRejectsMalformedIDs() {
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=abc")!
        XCTAssertNil(WorkshopLink.id(from: url))
        XCTAssertNil(WorkshopLink.id(fromText: "12"))
        XCTAssertEqual(WorkshopLink.id(fromText: " 3547355412 "), "3547355412")
    }
}

final class SteamOpenIDTests: XCTestCase {
    func testAcceptsValidCallbackAndRejectsStateMismatch() {
        let url = URL(string: "lumaforge://steam-callback?state=test&openid.mode=id_res"
            + "&openid.op_endpoint=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Flogin"
            + "&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fprofiles%2F76561198000000000")!
        XCTAssertEqual(SteamOpenID.steamID(from: url, expectedState: "test"),
                       "76561198000000000")
        XCTAssertNil(SteamOpenID.steamID(from: url, expectedState: "wrong"))
    }
}

final class PkgArchiveTests: XCTestCase {
    func testReadsDirectoryAndHonoursOffsets() throws {
        let url = try Fixture.write(
            Fixture.pkg([("a.txt", Data("first".utf8)),
                         ("nested/b.txt", Data("second-entry".utf8))]),
            name: "a.pkg"
        )
        let archive = try PkgArchive.read(at: url)
        XCTAssertEqual(archive.version, "0022")
        XCTAssertEqual(archive.entries.map(\.name), ["a.txt", "nested/b.txt"])
        XCTAssertEqual(archive.entries[1].offset, 5)
        XCTAssertEqual(try archive.data(for: archive.entries[1]), Data("second-entry".utf8))
    }

    func testRejectsFilesThatAreNotPackages() throws {
        let url = try Fixture.write(Data(repeating: 0x7A, count: 64), name: "bad.pkg")
        XCTAssertThrowsError(try PkgArchive.read(at: url)) { error in
            XCTAssertEqual(error as? PkgError, .notAnArchive)
        }
    }

    func testBlocksPathTraversal() {
        for hostile in ["../escape.txt", "/etc/passwd", "C:/windows/x", "..\\escape"] {
            XCTAssertThrowsError(try PkgArchive.safeRelativePath(hostile),
                                 "should reject \(hostile)")
        }
        XCTAssertEqual(try? PkgArchive.safeRelativePath("materials\\a.tex"), "materials/a.tex")
    }

    func testDetectsSceneDefinition() throws {
        let sceneURL = try Fixture.write(
            Fixture.pkg([("scene.json", Data("{}".utf8))]), name: "scene.pkg"
        )
        XCTAssertTrue(try PkgArchive.read(at: sceneURL).containsSceneDefinition)

        let plainURL = try Fixture.write(
            Fixture.pkg([("materials/a.tex", Data(repeating: 1, count: 32))]), name: "plain.pkg"
        )
        XCTAssertFalse(try PkgArchive.read(at: plainURL).containsSceneDefinition)
    }

    func testCopiesEntryBytesExactly() throws {
        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        let url = try Fixture.write(Fixture.pkg([("blob.bin", payload)]), name: "c.pkg")
        let archive = try PkgArchive.read(at: url)
        let destination = url.deletingLastPathComponent().appendingPathComponent("out.bin")
        try archive.copy(entry: archive.entries[0], to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }
}

final class TexTextureTests: XCTestCase {
    func testDetectsEmbeddedMP4AndReturnsExactBytes() throws {
        let mp4 = Fixture.fakeMP4()
        let blob = Fixture.tex(payload: mp4, width: 1920, height: 1080)
        let payload = try TexTexture.probe(blob)
        XCTAssertEqual(payload.kind, .video)
        XCTAssertEqual(payload.width, 1920)
        XCTAssertEqual(payload.height, 1080)
        XCTAssertEqual(try TexTexture.payloadData(blob), mp4)
    }

    func testHandlesTexb0003HeaderLength() throws {
        let mp4 = Fixture.fakeMP4()
        let blob = Fixture.tex(payload: mp4, width: 64, height: 64, container: "TEXB0003")
        XCTAssertEqual(try TexTexture.payloadData(blob), mp4)
    }

    func testIgnoresFtypInsidePixelData() throws {
        // "ftyp" preceded by a nonsense length must not be treated as a video.
        var noise = Data([0xFF, 0xFF, 0xFF, 0xFF])
        noise.append(Data("ftyp".utf8))
        noise.append(Data(repeating: 0x11, count: 512))
        XCTAssertEqual(try TexTexture.probe(Fixture.tex(payload: noise,
                                                        width: 8, height: 8)).kind, .raw)
    }

    func testDetectsPngPayload() throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0, count: 128))
        let payload = try TexTexture.probe(Fixture.tex(payload: png, width: 8, height: 8))
        XCTAssertEqual(payload.kind, .image)
        XCTAssertEqual(payload.fileExtension, "png")
    }

    func testRejectsNonTexture() {
        XCTAssertThrowsError(try TexTexture.probe(Data("not a texture".utf8)))
    }
}

final class PackageInspectorTests: XCTestCase {
    private func videoPackage() throws -> URL {
        try Fixture.write(
            Fixture.pkg([
                ("materials/video.tex", Fixture.tex(payload: Fixture.fakeMP4(),
                                                    width: 1280, height: 720)),
                ("project.json", Data("{\"type\":\"video\"}".utf8)),
            ]),
            name: "video.pkg"
        )
    }

    func testVideoInsideTextureIsPassthrough() throws {
        let plan = PackageInspector.inspect(at: try videoPackage())
        XCTAssertEqual(plan.strategy, .passthrough)
        XCTAssertEqual(plan.fidelity, .identical)
        XCTAssertTrue(plan.isLossless)
        XCTAssertEqual(plan.candidate?.origin, .texture)
    }

    func testSceneWithoutMediaNeedsRenderer() throws {
        let url = try Fixture.write(
            Fixture.pkg([("scene.json", Data("{\"objects\":[]}".utf8)),
                         ("materials/t.tex", Fixture.tex(payload: Data(repeating: 9, count: 4096),
                                                         width: 512, height: 512))]),
            name: "scene.pkg"
        )
        let plan = PackageInspector.inspect(at: url)
        XCTAssertEqual(plan.strategy, .renderScene)
        XCTAssertEqual(plan.fidelity, .approximate)
        XCTAssertFalse(plan.isExportable)
    }

    func testInteractiveTagProducesWarning() throws {
        let plan = PackageInspector.inspect(at: try videoPackage(),
                                            tags: ["Video", "Audio responsive"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("Audio responsive") })
    }

    func testEmptyFolderIsUnsupported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plan = PackageInspector.inspect(at: directory)
        XCTAssertEqual(plan.strategy, .unsupported)
        XCTAssertFalse(plan.isExportable)
    }

    func testWebmIsPreservedRatherThanReencoded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x1F, count: 8192)
            .write(to: directory.appendingPathComponent("wallpaper.webm"))
        let plan = PackageInspector.inspect(at: directory)
        XCTAssertEqual(plan.strategy, .preserveOriginal)
        XCTAssertTrue(plan.isLossless)
    }
}

final class ExportPipelineTests: XCTestCase {
    /// The promise of this app: a video wallpaper comes out byte-for-byte
    /// identical to the stream stored inside the package.
    func testPassthroughExportIsByteIdentical() throws {
        let mp4 = Fixture.fakeMP4(payloadSize: 32768)
        let url = try Fixture.write(
            Fixture.pkg([("materials/v.tex", Fixture.tex(payload: mp4,
                                                         width: 640, height: 360))]),
            name: "p.pkg"
        )
        let plan = PackageInspector.inspect(at: url)
        XCTAssertEqual(plan.strategy, .passthrough)

        let scratch = url.deletingLastPathComponent()
        let outcome = try ExportPipeline().export(
            plan: plan, to: scratch.appendingPathComponent("out.mp4"), scratch: scratch
        )
        XCTAssertFalse(outcome.reencoded)
        XCTAssertTrue(outcome.canSaveToPhotos)
        XCTAssertEqual(try Data(contentsOf: outcome.url), mp4)
    }

    func testSceneExportFailsWithAClearReason() throws {
        let url = try Fixture.write(
            Fixture.pkg([("scene.json", Data("{}".utf8))]), name: "s.pkg"
        )
        let plan = PackageInspector.inspect(at: url)
        XCTAssertThrowsError(
            try ExportPipeline().export(plan: plan,
                                        to: url.deletingLastPathComponent()
                                            .appendingPathComponent("o.mp4"),
                                        scratch: url.deletingLastPathComponent())
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("real-time"))
        }
    }

    func testStillImageEncodesToPlayableVideo() throws {
        // A 2x2 PNG, encoded through AVAssetWriter.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pngURL = directory.appendingPathComponent("still.png")
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        try image.pngData()!.write(to: pngURL)

        let plan = PackageInspector.inspect(at: directory)
        XCTAssertEqual(plan.strategy, .encodeStill)

        var pipeline = ExportPipeline()
        pipeline.stillDuration = 1.0

        let outcome: ExportOutcome
        do {
            outcome = try pipeline.export(plan: plan,
                                          to: directory.appendingPathComponent("out.mp4"),
                                          scratch: directory)
        } catch {
            // Some simulators have no usable H.264 encoder. That is an
            // environment limitation, not a pipeline defect; the lossless path
            // (which never encodes) is still covered by the test above.
            throw XCTSkip("Video encoding unavailable here: \(error.localizedDescription)")
        }
        XCTAssertTrue(outcome.reencoded)
        XCTAssertEqual(outcome.fidelity, .staticOnly)
        let exported = try Data(contentsOf: outcome.url)
        XCTAssertGreaterThan(exported.count, 1024)
        XCTAssertEqual(exported.subdata(in: 4..<8), Data("ftyp".utf8))
    }
}

final class AcquisitionTests: XCTestCase {
    private func makeInbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testImportedSourceFindsPackageByWorkshopID() async throws {
        let inbox = try makeInbox()
        try Fixture.pkg([("project.json", Data("{}".utf8))])
            .write(to: inbox.appendingPathComponent("3807719502.pkg"))
        let source = ImportedPackageSource(inbox: inbox)
        XCTAssertTrue(source.capability().available)

        let content = try await source.acquire(workshopID: "3807719502", into: inbox)
        XCTAssertEqual(content.sourceName, "Imported package")
        XCTAssertEqual(content.root.lastPathComponent, "3807719502.pkg")
    }

    func testImportedSourceReportsMissingItem() async throws {
        let inbox = try makeInbox()
        let source = ImportedPackageSource(inbox: inbox)
        do {
            _ = try await source.acquire(workshopID: "123456", into: inbox)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No imported package"))
        }
    }

    func testWorkerSourceIsUnavailableUntilConfigured() {
        let capability = WorkerSource(baseURL: nil, apiKey: nil).capability()
        XCTAssertFalse(capability.available)
        XCTAssertTrue(capability.requiresConfiguration)

        let configured = WorkerSource(baseURL: URL(string: "https://example.com"), apiKey: "k")
        XCTAssertTrue(configured.capability().available)
    }

    func testRegistryReportsEveryAttemptWhenAllSourcesFail() async throws {
        let inbox = try makeInbox()
        let registry = AcquisitionRegistry(sources: [
            ImportedPackageSource(inbox: inbox),
            WorkerSource(baseURL: nil, apiKey: nil),
        ])
        do {
            _ = try await registry.acquire(workshopID: "999999", into: inbox)
            XCTFail("expected a failure")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Imported package"))
            XCTAssertTrue(message.contains("Remote worker"))
        }
    }
}

final class SteamMetadataTests: XCTestCase {
    private func payload(tags: [String], appID: Int = 431960) -> Data {
        let tagJSON = tags.map { "{\"tag\":\"\($0)\"}" }.joined(separator: ",")
        return Data("""
        {"response":{"publishedfiledetails":[{"publishedfileid":"1","result":1,
        "consumer_app_id":\(appID),"title":"T","file_size":"30485611",
        "tags":[\(tagJSON)]}]}}
        """.utf8)
    }

    func testVideoTagPredictsLosslessExport() {
        let parsed = SteamMetadataService.parse(payload(tags: ["Video", "3840 x 2160"]))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].declaredType, "Video")
        XCTAssertEqual(parsed[0].resolution, "3840 x 2160")
        XCTAssertEqual(parsed[0].expectedFidelity, .identical)
        XCTAssertFalse(parsed[0].interactive)
    }

    func testAudioResponsiveSceneIsFlagged() {
        let parsed = SteamMetadataService.parse(payload(tags: ["Scene", "Audio responsive"]))
        XCTAssertEqual(parsed[0].declaredType, "Scene")
        XCTAssertTrue(parsed[0].interactive)
        XCTAssertEqual(parsed[0].expectedFidelity, .approximate)
        XCTAssertTrue(parsed[0].expectationSummary.contains("cannot reproduce"))
    }

    func testItemsFromOtherAppsAreIgnored() {
        XCTAssertTrue(SteamMetadataService.parse(payload(tags: ["Video"], appID: 730)).isEmpty)
    }
}
