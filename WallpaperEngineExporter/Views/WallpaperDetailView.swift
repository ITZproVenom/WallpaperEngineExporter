import SwiftUI

struct WallpaperDetailView: View {
    let item: WorkshopItem
    @EnvironmentObject var workshop: SteamWorkshopService
    @State private var config = ExportConfiguration()
    @State private var showExport = false
    @State private var liveItem: WorkshopItem

    init(item: WorkshopItem) {
        self.item = item
        _liveItem = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                previewSection

                VStack(alignment: .leading, spacing: 6) {
                    Text(liveItem.title)
                        .font(.title2.bold())
                    if let author = liveItem.author {
                        Text("by \(author)")
                            .foregroundStyle(.secondary)
                    }
                    Label(liveItem.type.displayName, systemImage: typeIcon)
                        .font(.subheadline)
                }

                Group {
                    LabeledContent("Workshop ID", value: liveItem.id)
                    if let size = liveItem.fileSize {
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    LabeledContent("Availability", value: availabilityLabel)
                }
                .font(.subheadline)

                if let desc = liveItem.description, !desc.isEmpty {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                actionSection
            }
            .padding()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await enrichMetadataIfNeeded()
        }
        .sheet(isPresented: $showExport) {
            ExportSettingsView(item: liveItem, config: $config)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if liveItem.type == .video,
           let path = liveItem.localPath,
           ["mp4", "mov", "m4v"].contains(path.pathExtension.lowercased()) {
            VideoPreviewView(url: path)
        } else if liveItem.type == .web,
                  let path = liveItem.localPath {
            let root = path.hasDirectoryPath ? path : path.deletingLastPathComponent()
            let entry = path.hasDirectoryPath ? "index.html" : path.lastPathComponent
            WebWallpaperPreviewView(rootDirectory: root, entryFile: entry)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let preview = liveItem.previewURL {
            AsyncImage(url: preview) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    placeholderPreview
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            placeholderPreview
        }
    }

    private var placeholderPreview: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var actionSection: some View {
        let canExportVideo = liveItem.localPath != nil &&
            (liveItem.type == .video || isLikelyVideoFile(liveItem.localPath))

        if canExportVideo {
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
        }

        if liveItem.type == .scene {
            limitationCard(
                title: "Scene Wallpaper",
                body: "Wallpaper Engine scenes use a proprietary scene graph (scene.json), binary packages, and desktop-only shaders/particles. Full Metal reimplementation of the WE runtime is not available on iOS. Embedded video textures can still be exported as MP4 when present."
            )
        } else if liveItem.type == .web && !canExportVideo {
            limitationCard(
                title: "Web Wallpaper",
                body: "Local HTML/CSS/JS can be previewed in WKWebView. Continuous frame capture to MP4 from WKWebView is limited on iOS. Import any embedded video for a reliable export path."
            )
        } else if liveItem.type == .application && !canExportVideo {
            limitationCard(
                title: "Application Wallpaper",
                body: "Application wallpapers require a Windows executable/runtime that cannot run on iOS. Extractable video assets inside the package are offered for export when detected."
            )
        } else if liveItem.localPath == nil {
            limitationCard(
                title: "Wallpaper Content Unavailable",
                body: "Workshop metadata is available, but the actual files are not on this device. Import the wallpaper through Files (project folder, zip, or video)."
            )
        }
    }

    private func limitationCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var availabilityLabel: String {
        switch liveItem.availability {
        case .metadataOnly: return "Metadata only"
        case .imported: return "Imported"
        case .readyToExport: return "Ready to export"
        case .unsupported: return "Unsupported on iOS"
        case .missingAssets: return "Missing assets"
        }
    }

    private var typeIcon: String {
        switch liveItem.type {
        case .video: return "film"
        case .scene: return "cube"
        case .web: return "globe"
        case .application: return "app"
        case .unknown: return "questionmark"
        }
    }

    private func isLikelyVideoFile(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    private func enrichMetadataIfNeeded() async {
        if liveItem.previewURL == nil || liveItem.author == nil {
            if let enriched = await workshop.fetchItemMetadata(id: liveItem.id) {
                var merged = liveItem
                merged = WorkshopItem(
                    id: merged.id,
                    title: enriched.title.isEmpty ? merged.title : enriched.title,
                    author: enriched.author ?? merged.author,
                    previewURL: enriched.previewURL ?? merged.previewURL,
                    description: enriched.description ?? merged.description,
                    fileSize: merged.fileSize,
                    type: merged.type == .unknown ? enriched.type : merged.type,
                    tags: merged.tags.isEmpty ? enriched.tags : merged.tags,
                    timeCreated: merged.timeCreated,
                    timeUpdated: merged.timeUpdated,
                    isSubscribed: merged.isSubscribed,
                    localPath: merged.localPath,
                    availability: merged.availability
                )
                liveItem = merged
            }
        }
    }
}
