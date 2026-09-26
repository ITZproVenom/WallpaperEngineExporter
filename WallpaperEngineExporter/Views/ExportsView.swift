import SwiftUI

struct ExportRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let filename: String
    let date: Date
    let size: Int64
    let path: URL

    var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }
}

enum ExportHistoryStore {
    private static let key = "export_history_v1"

    static func records() -> [ExportRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([ExportRecord].self, from: data) else {
            return []
        }
        return records
            .filter { $0.exists }
            .sorted { $0.date > $1.date }
    }

    static func save(tempURL: URL, title: String) throws -> ExportRecord {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exports = documents.appendingPathComponent("Exports", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeTitle.isEmpty ? "Wallpaper" : String(safeTitle.prefix(80))
        let filename = "\(base)_\(Self.timestamp()).mp4"
        let destination = exports.appendingPathComponent(filename)

        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tempURL, to: destination)

        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let record = ExportRecord(
            id: UUID(),
            title: title,
            filename: filename,
            date: Date(),
            size: size,
            path: destination
        )

        var records = records()
        records.insert(record, at: 0)
        records = Array(records.prefix(100))
        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: key)
        return record
    }

    static func delete(_ record: ExportRecord) {
        try? FileManager.default.removeItem(at: record.path)
        var records = records()
        records.removeAll { $0.id == record.id }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: key)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

struct ExportsView: View {
    @State private var records: [ExportRecord] = []

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView {
                        Label("No Exports", systemImage: "film")
                    } description: {
                        Text("Completed MP4 exports will appear here.")
                    }
                } else {
                    List {
                        ForEach(records) { record in
                            ShareLink(item: record.path) {
                                HStack(spacing: 12) {
                                    Image(systemName: "film")
                                        .font(.title3)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Text(record.date, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundStyle(.tint)
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    ExportHistoryStore.delete(record)
                                    records = ExportHistoryStore.records()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Exports")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !records.isEmpty {
                        Button("Clear") {
                            for record in records { ExportHistoryStore.delete(record) }
                            records = ExportHistoryStore.records()
                        }
                    }
                }
            }
            .onAppear {
                records = ExportHistoryStore.records()
            }
        }
    }
}
