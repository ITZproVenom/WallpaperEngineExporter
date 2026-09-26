import SwiftUI

struct ExportSettingsView: View {
    let item: WorkshopItem
    @Binding var config: ExportConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var exportProgress: ExportProgress?
    @State private var exportedURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Resolution") {
                    Picker("Resolution", selection: $config.resolution) {
                        ForEach(ExportResolution.allCases) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                    if config.resolution == .custom {
                        HStack {
                            TextField("Width", value: $config.customWidth, format: .number)
                                .keyboardType(.numberPad)
                            Text("×")
                            TextField("Height", value: $config.customHeight, format: .number)
                                .keyboardType(.numberPad)
                        }
                    }
                }

                Section("Frame Rate") {
                    Picker("FPS", selection: $config.fps) {
                        ForEach(ExportFPS.allCases) { f in
                            Text("\(f.rawValue) fps").tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Duration") {
                    Picker("Duration", selection: Binding(
                        get: {
                            if case .seconds(let s) = config.duration { return s }
                            return 10
                        },
                        set: { config.duration = .seconds($0) }
                    )) {
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                        Text("15 s").tag(15)
                        Text("30 s").tag(30)
                        Text("60 s").tag(60)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Codec & Quality") {
                    Picker("Codec", selection: $config.codec) {
                        ForEach(ExportCodec.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    Picker("Quality", selection: $config.quality) {
                        ForEach(ExportQuality.allCases) { q in
                            Text(q.rawValue.capitalized).tag(q)
                        }
                    }
                }

                Section {
                    Toggle("Loop source", isOn: $config.loop)
                }
            }
            .navigationTitle("Export Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        startExport()
                    }
                    .disabled(isExporting)
                }
            }
            .overlay {
                if isExporting, let progress = exportProgress {
                    ExportProgressView(progress: progress)
                }
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .sheet(item: Binding(
                get: { exportedURL.map { IdentifiableURL(url: $0) } },
                set: { exportedURL = $0?.url }
            )) { identifiable in
                ExportCompleteView(url: identifiable.url) {
                    dismiss()
                }
            }
        }
    }

    private func startExport() {
        guard let path = item.localPath else {
            exportError = "No local wallpaper file available."
            return
        }
        isExporting = true
        exportProgress = ExportProgress(stage: .rendering, fraction: 0)

        Task {
            do {
                let url = try await VideoExporter.shared.export(
                    source: path,
                    configuration: config,
                    progress: { p in
                        Task { @MainActor in
                            exportProgress = p
                        }
                    }
                )
                let savedRecord: ExportRecord
                do {
                    savedRecord = try ExportHistoryStore.save(tempURL: url, title: item.title)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                await MainActor.run {
                    isExporting = false
                    exportedURL = savedRecord.path
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
