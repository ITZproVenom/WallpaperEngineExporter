import SwiftUI
import UniformTypeIdentifiers

@main
struct LumaForgeApp: App {
    @StateObject private var downloader = DownloadManager()
    @StateObject private var exports = ExportStore()

    var body: some Scene {
        WindowGroup {
            HomeView(downloader: downloader, exports: exports)
        }
    }
}

struct HomeView: View {
    @ObservedObject var downloader: DownloadManager
    @ObservedObject var exports: ExportStore
    @State private var link = ""
    @State private var showImporter = false
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LumaForge")
                            .font(.largeTitle.bold())
                        Text("Paste a wallpaper download link, download it, then export it as MP4.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Download")
                            .font(.title2.bold())

                        TextField("Paste download link", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            downloader.download(link)
                        } label: {
                            Label(downloader.downloading ? "Downloading…" : "Download Wallpaper",
                                  systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(downloader.downloading || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if downloader.downloading {
                            ProgressView(value: downloader.progress)
                            Text("(Int(downloader.progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))

                    if let file = downloader.downloadedURL {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Download complete", systemImage: "checkmark.circle.fill")
                                .font(.headline)

                            Text(file.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(2)

                            Button {
                                exporting = true
                                Task {
                                    await exports.export(file)
                                    exporting = false
                                }
                            } label: {
                                Label(exporting ? "Exporting…" : "Export as MP4",
                                      systemImage: "film")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(exporting)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Or import a downloaded wallpaper")
                            .font(.headline)

                        Button {
                            showImporter = true
                        } label: {
                            Label("Import from Files", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !exports.records.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent exports")
                                .font(.headline)

                            ForEach(exports.records.prefix(5)) { record in
                                HStack {
                                    Image(systemName: "film")
                                    Text(record.name).lineLimit(1)
                                    Spacer()
                                    ShareLink(item: exports.url(for: record)) {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("LumaForge")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data, .image, .movie],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    exports.importFiles(urls)
                }
            }
            .alert("LumaForge", isPresented: Binding(
                get: { downloader.error != nil || exports.error != nil },
                set: { if !$0 { downloader.error = nil; exports.error = nil } }
            )) {
                Button("OK") { downloader.error = nil; exports.error = nil }
            } message: {
                Text(downloader.error ?? exports.error ?? "")
            }
        }
    }
}
