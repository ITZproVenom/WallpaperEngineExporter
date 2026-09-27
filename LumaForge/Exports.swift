import Foundation
import Photos

struct ExportRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var filename: String
    var createdAt: Date
    var workshopID: String
    var strategy: String
    var fidelity: String
    var reencoded: Bool

    init(id: UUID = UUID(), name: String, filename: String, createdAt: Date = Date(),
         workshopID: String, strategy: String, fidelity: String, reencoded: Bool) {
        self.id = id
        self.name = name
        self.filename = filename
        self.createdAt = createdAt
        self.workshopID = workshopID
        self.strategy = strategy
        self.fidelity = fidelity
        self.reencoded = reencoded
    }

    // Tolerant of manifests written by older builds.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Export"
        filename = try container.decode(String.self, forKey: .filename)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        workshopID = try container.decodeIfPresent(String.self, forKey: .workshopID) ?? ""
        strategy = try container.decodeIfPresent(String.self, forKey: .strategy) ?? "passthrough"
        fidelity = try container.decodeIfPresent(String.self, forKey: .fidelity) ?? "identical"
        reencoded = try container.decodeIfPresent(Bool.self, forKey: .reencoded) ?? false
    }

    var fidelityLabel: String {
        ExportFidelity(rawValue: fidelity)?.label ?? fidelity
    }

    var isVideoForPhotos: Bool {
        ["mp4", "m4v", "mov"].contains((filename as NSString).pathExtension.lowercased())
    }
}

/// Local library of finished exports, plus Photos saving.
@MainActor
final class ExportStore: ObservableObject {
    @Published private(set) var records: [ExportRecord] = []
    @Published var error: String?
    @Published var message: String?

    private let fileManager = FileManager.default

    init() { load() }

    // MARK: Storage locations

    private func baseDirectory() -> URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaForge", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exportsDirectory() -> URL {
        let url = baseDirectory().appendingPathComponent("Exports", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestURL() -> URL {
        baseDirectory().appendingPathComponent("exports.json")
    }

    func url(for record: ExportRecord) -> URL {
        exportsDirectory().appendingPathComponent(record.filename)
    }

    // MARK: Recording results

    /// Move a finished export into the library.
    @discardableResult
    func adopt(outcome: ExportOutcome, title: String, workshopID: String) -> ExportRecord? {
        let stem = workshopID.isEmpty ? "export" : workshopID
        let unique = "\(stem)-\(UUID().uuidString.prefix(8)).\(outcome.url.pathExtension)"
        let destination = exportsDirectory().appendingPathComponent(unique)

        do {
            try? fileManager.removeItem(at: destination)
            if outcome.url.path.hasPrefix(exportsDirectory().path) {
                try fileManager.moveItem(at: outcome.url, to: destination)
            } else {
                try fileManager.copyItem(at: outcome.url, to: destination)
            }
        } catch {
            self.error = "Could not save the export: \(error.localizedDescription)"
            return nil
        }

        let record = ExportRecord(
            name: title.isEmpty ? "Wallpaper \(stem)" : title,
            filename: unique, workshopID: workshopID,
            strategy: outcome.strategy.rawValue, fidelity: outcome.fidelity.rawValue,
            reencoded: outcome.reencoded
        )
        records.insert(record, at: 0)
        save()
        return record
    }

    func delete(_ record: ExportRecord) {
        try? fileManager.removeItem(at: url(for: record))
        records.removeAll { $0.id == record.id }
        save()
    }

    func rename(_ record: ExportRecord, to name: String) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].name = name
        save()
    }

    func fileSize(of record: ExportRecord) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: url(for: record).path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: Photos

    func saveToPhotos(_ record: ExportRecord) async {
        guard record.isVideoForPhotos else {
            error = "Photos accepts MP4 and MOV only. This export is a "
                + "\((record.filename as NSString).pathExtension.uppercased())"
                + " file; use Share to keep it."
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = "LumaForge needs permission to add videos to Photos. "
                + "Enable it in Settings › Photos."
            return
        }

        let fileURL = url(for: record)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .video, fileURL: fileURL, options: nil)
            }
            message = "Saved “\(record.name)” to Photos."
        } catch {
            self.error = "Could not save to Photos: \(error.localizedDescription)"
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL()),
              let decoded = try? JSONDecoder().decode([ExportRecord].self, from: data)
        else { return }
        records = decoded.filter { fileManager.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        try? JSONEncoder().encode(records).write(to: manifestURL(), options: .atomic)
    }
}
