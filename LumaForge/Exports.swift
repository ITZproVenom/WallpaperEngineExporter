import Foundation

@MainActor
final class ExportStore: ObservableObject {
    @Published private(set) var records: [ExportRecord] = []
    @Published var error: String?
    private let fm = FileManager.default

    init() { load() }

    func importServerMP4(_ url: URL, workshopID: String) {
        do {
            let destination = exportsDirectory().appendingPathComponent(
                "\(workshopID)-\(UUID().uuidString.prefix(8)).mp4"
            )
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: url, to: destination)

            let record = ExportRecord(
                id: UUID(),
                name: "Workshop \(workshopID)",
                filename: destination.lastPathComponent,
                createdAt: Date(),
                workshopID: workshopID
            )
            records.insert(record, at: 0)
            save()
        } catch {
            self.error = "Could not save the finished MP4: \(error.localizedDescription)"
        }
    }

    func url(for record: ExportRecord) -> URL {
        exportsDirectory().appendingPathComponent(record.filename)
    }

    func delete(_ record: ExportRecord) {
        try? fm.removeItem(at: url(for: record))
        records.removeAll { $0.id == record.id }
        save()
    }

    private func baseDirectory() -> URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaForge", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exportsDirectory() -> URL {
        let url = baseDirectory().appendingPathComponent("Exports", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifest() -> URL {
        baseDirectory().appendingPathComponent("exports.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifest()),
              let value = try? JSONDecoder().decode([ExportRecord].self, from: data) else { return }
        records = value.filter { fm.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        try? JSONEncoder().encode(records).write(to: manifest(), options: .atomic)
    }
}
