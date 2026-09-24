import SwiftUI

struct WallpaperDetailView: View {
    let item: WorkshopItem
    @State private var config = ExportConfiguration()
    @State private var showExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Preview
                AsyncImage(url: item.previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Rectangle()
                            .fill(.quaternary)
                            .aspectRatio(16/9, contentMode: .fit)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.title2.bold())
                    if let author = item.author {
                        Text("by \(author)")
                            .foregroundStyle(.secondary)
                    }
                    Label(item.type.displayName, systemImage: typeIcon)
                        .font(.subheadline)
                }

                Group {
                    LabeledContent("Workshop ID", value: item.id)
                    if let size = item.fileSize {
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    LabeledContent("Availability", value: item.availability.rawValue.capitalized)
                }
                .font(.subheadline)

                if item.type.isExportable && item.localPath != nil {
                    Button {
                        showExport = true
                    } label: {
                        Label("Export to MP4", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else if item.type != .video {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Unsupported Wallpaper", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("This Wallpaper Engine type (\(item.type.displayName)) requires functionality that isn't available on iOS. Only video wallpapers can be fully exported.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if item.localPath == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Wallpaper Content Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.headline)
                        Text("The Workshop information is available, but the actual wallpaper files aren't available to this device. Import the wallpaper through Files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            ExportSettingsView(item: item, config: $config)
        }
    }

    private var typeIcon: String {
        switch item.type {
        case .video: return "film"
        case .scene: return "cube"
        case .web: return "globe"
        case .application: return "app"
        case .unknown: return "questionmark"
        }
    }
}
