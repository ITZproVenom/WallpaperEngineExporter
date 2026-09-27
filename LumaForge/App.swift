import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LumaForgeApp: App {
    @StateObject private var steam = SteamSession()
    @StateObject private var workshop = WorkshopStore()
    @StateObject private var exports = ExportStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            TabView {
                WallpapersView(steam: steam, store: workshop)
                    .tabItem { Label("Wallpapers", systemImage: "sparkles") }
                ImportView(exports: exports)
                    .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
                LibraryView(store: exports)
                    .tabItem { Label("Library", systemImage: "film.stack") }
                SettingsView(steam: steam, settings: settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(.indigo)
            .alert("LumaForge", isPresented: Binding(
                get: { workshop.error != nil || exports.error != nil },
                set: { if !$0 { workshop.error = nil; exports.error = nil } }
            )) {
                Button("OK") { workshop.error = nil; exports.error = nil }
            } message: {
                Text(workshop.error ?? exports.error ?? "")
            }
            .alert("LumaForge", isPresented: Binding(
                get: { exports.message != nil },
                set: { if !$0 { exports.message = nil } }
            )) {
                Button("OK") { exports.message = nil }
            } message: {
                Text(exports.message ?? "")
            }
        }
    }
}

// MARK: - Wallpapers (Steam subscriptions)

struct WallpapersView: View {
    @ObservedObject var steam: SteamSession
    @ObservedObject var store: WorkshopStore
    @State private var showSubscriptions = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if steam.steamID == nil {
                        Button {
                            steam.signIn()
                        } label: {
                            Label("Sign in with Steam", systemImage: "person.badge.key")
                        }
                        Text("Signing in lets LumaForge list the wallpapers you are "
                             + "subscribed to and show what each one can export to.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            showSubscriptions = true
                        } label: {
                            Label("Load my subscribed wallpapers", systemImage: "tray.full")
                        }
                    }
                }

                if store.loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }

                if !store.items.isEmpty {
                    Section("Subscribed") {
                        ForEach(store.items) { item in
                            NavigationLink {
                                WallpaperDetailView(item: item,
                                                    metadata: store.metadata[item.id])
                            } label: {
                                WallpaperRow(item: item, metadata: store.metadata[item.id])
                            }
                        }
                    }
                }

                Section {
                    Text("Steam only hands Workshop files to accounts that own Wallpaper "
                         + "Engine, so LumaForge cannot download them for you. Export a "
                         + "wallpaper by importing its .pkg on the Import tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Wallpapers")
            .sheet(isPresented: $showSubscriptions) {
                NavigationStack {
                    SteamSubscriptionsView(steamID: steam.steamID ?? "") { subscribed in
                        store.setSubscribed(subscribed)
                        showSubscriptions = false
                        Task { await store.loadMetadata() }
                    }
                    .navigationTitle("Steam")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSubscriptions = false }
                        }
                    }
                }
            }
        }
    }
}

struct WallpaperRow: View {
    let item: WorkshopItem
    let metadata: WorkshopMetadata?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: metadata?.previewURL ?? item.previewURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 84, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(metadata?.title.isEmpty == false ? metadata!.title : item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let type = metadata?.declaredType {
                        Text(type)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(type == "Video" ? Color.green.opacity(0.2)
                                                        : Color.orange.opacity(0.2),
                                        in: Capsule())
                    }
                    if let size = metadata?.formattedSize, !size.isEmpty {
                        Text(size).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct WallpaperDetailView: View {
    let item: WorkshopItem
    let metadata: WorkshopMetadata?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: metadata?.previewURL ?? item.previewURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Text(metadata?.title.isEmpty == false ? metadata!.title : item.title)
                    .font(.title2.bold())

                if let metadata {
                    LabeledContent("Type", value: metadata.declaredType ?? "Unknown")
                    if !metadata.resolution.isEmpty {
                        LabeledContent("Resolution", value: metadata.resolution)
                    }
                    if !metadata.formattedSize.isEmpty {
                        LabeledContent("Size", value: metadata.formattedSize)
                    }
                    Text(metadata.expectationSummary)
                        .font(.callout)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Text("To export this wallpaper, import its .pkg on the Import tab. "
                     + "LumaForge then inspects the package and picks the best strategy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    openURL(item.pageURL)
                } label: {
                    Label("Open on Steam", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("Wallpaper")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Import and export

struct ImportView: View {
    @ObservedObject var exports: ExportStore
    @StateObject private var coordinator = ExportCoordinator()
    @State private var packages: [URL] = []
    @State private var showPicker = false

    private let source = ImportedPackageSource()

    private var packageTypes: [UTType] {
        [UTType(filenameExtension: "pkg") ?? .data, .zip, .folder, .movie, .gif, .image]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Import wallpaper package", systemImage: "plus.circle")
                    }
                    Text("Choose a scene.pkg, a wallpaper folder, or a video file. "
                         + "LumaForge inspects it and keeps the original quality "
                         + "wherever the package already contains a video.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if coordinator.phase.isBusy {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(statusText).font(.footnote)
                        }
                    }
                }

                if case .failed(let reason) = coordinator.phase {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if let plan = coordinator.lastPlan {
                    Section("Inspection") {
                        LabeledContent("Strategy", value: plan.strategy.rawValue)
                        LabeledContent("Fidelity", value: plan.fidelity.label)
                        LabeledContent("Re-encoded", value: plan.isLossless ? "No" : "Yes")
                        Text(plan.reason).font(.footnote).foregroundStyle(.secondary)
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Imported packages") {
                    if packages.isEmpty {
                        Text("Nothing imported yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(packages, id: \.absoluteString) { url in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(url.lastPathComponent)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                HStack {
                                    Button("Inspect") {
                                        Task { _ = await coordinator.inspect(packageURL: url) }
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Export") {
                                        Task {
                                            await coordinator.export(
                                                packageURL: url, into: exports,
                                                title: url.deletingPathExtension()
                                                    .lastPathComponent,
                                                workshopID: url.deletingPathExtension()
                                                    .lastPathComponent
                                            )
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .disabled(coordinator.phase.isBusy)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    try? FileManager.default.removeItem(at: url)
                                    packages = source.storedPackages()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import")
            .task { packages = source.storedPackages() }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: packageTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        do {
                            _ = try source.store(pickedURL: url)
                        } catch {
                            exports.error = "Could not import \(url.lastPathComponent): "
                                + error.localizedDescription
                        }
                    }
                    packages = source.storedPackages()
                case .failure(let error):
                    exports.error = error.localizedDescription
                }
            }
        }
    }

    private var statusText: String {
        switch coordinator.phase {
        case .inspecting: return "Inspecting package…"
        case .exporting(let detail): return detail
        case .finished(let name): return "Exported \(name)"
        default: return ""
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @ObservedObject var store: ExportStore
    @State private var playing: ExportRecord?

    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "No exports yet",
                        systemImage: "film.stack",
                        description: Text("Import a wallpaper package to create one.")
                    )
                } else {
                    ForEach(store.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            HStack(spacing: 8) {
                                Text(record.fidelityLabel)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(record.reencoded ? Color.orange.opacity(0.2)
                                                                 : Color.green.opacity(0.2),
                                                in: Capsule())
                                Text(store.fileSize(of: record))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(record.createdAt, style: .date)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                if record.isVideoForPhotos {
                                    Button {
                                        playing = record
                                    } label: {
                                        Label("Preview", systemImage: "play.circle")
                                    }
                                    Button {
                                        Task { await store.saveToPhotos(record) }
                                    } label: {
                                        Label("Save", systemImage: "photo.badge.arrow.down")
                                    }
                                }
                                ShareLink(item: store.url(for: record)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.delete(record)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .sheet(item: $playing) { record in
                PlayerSheet(url: store.url(for: record), title: record.name)
            }
        }
    }
}

struct PlayerSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var steam: SteamSession
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            List {
                Section("Steam") {
                    if let id = steam.steamID {
                        LabeledContent("Steam ID", value: id)
                        Button("Sign out", role: .destructive) { steam.signOut() }
                    } else {
                        Button("Sign in with Steam") { steam.signIn() }
                    }
                }

                Section("Sources") {
                    ForEach(settings.registry().capabilities()) { capability in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: capability.available
                                  ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(capability.available ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capability.name).font(.subheadline)
                                Text(capability.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Optional worker") {
                    TextField("https://your-worker.example.com", text: $settings.workerURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if settings.workerURLIsInvalid {
                        Label("That is not a valid http(s) URL.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    SecureField("API key (optional)", text: $settings.apiKey)
                    Text("A worker is only needed for real-time scene wallpapers, which "
                         + "have to be recorded by a renderer. Everything else is handled "
                         + "on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: "3.0.0")
                    LabeledContent("Workshop app", value: "431960")
                    Text("Video wallpapers are exported by copying the original stream, "
                         + "so they are byte-for-byte identical to what Wallpaper Engine "
                         + "plays. Nothing is re-encoded unless the package has no video.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
