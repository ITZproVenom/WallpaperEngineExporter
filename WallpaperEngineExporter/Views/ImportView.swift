import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @EnvironmentObject var workshop: SteamWorkshopService
    @State private var showImporter = false
    @State private var importedItem: WorkshopItem?
    @State private var errorMessage: String?
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Import Wallpaper")
                    .font(.title2.bold())

                Text("Select a Wallpaper Engine project folder, .zip archive, or video file that you legitimately own.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button {
                    showImporter = true
                } label: {
                    Label("Choose from Files", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 40)
                .disabled(isProcessing)

                if isProcessing {
                    ProgressView("Analyzing…")
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                if let item = importedItem {
                    NavigationLink(value: item) {
                        WallpaperCard(item: item)
                            .padding()
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import")
            .navigationDestination(for: WorkshopItem.self) { item in
                WallpaperDetailView(item: item)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.folder, .zip, .movie, .mpeg4Movie, .quickTimeMovie, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        importedItem = nil
        isProcessing = true

        switch result {
        case .failure(let error):
            errorMessage = "Import failed: \(error.localizedDescription)"
            isProcessing = false
        case .success(let urls):
            guard let url = urls.first else {
                isProcessing = false
                return
            }
            Task {
                do {
                    let item = try await WallpaperImporter.shared.importFrom(url: url)
                    await MainActor.run {
                        importedItem = item
                        workshop.addImported(item)
                        isProcessing = false
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        isProcessing = false
                    }
                }
            }
        }
    }
}
