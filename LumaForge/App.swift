import SwiftUI

@main
struct LumaForgeApp: App {
    @StateObject private var steam = SteamSession()
    @StateObject private var workshop = WorkshopStore()
    @StateObject private var exports = ExportStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                WorkshopView(steam: steam, store: workshop, exports: exports)
                    .tabItem { Label("Workshop", systemImage: "sparkles") }
                LibraryView(store: exports)
                    .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                HistoryView(store: exports)
                    .tabItem { Label("Exports", systemImage: "arrow.down.circle") }
                SettingsView(steam: steam)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(.indigo)
            .task { await workshop.search() }
            .alert("LumaForge", isPresented: Binding(
                get: { workshop.error != nil || exports.error != nil },
                set: { if !$0 { workshop.error = nil; exports.error = nil } }
            )) {
                Button("OK") { workshop.error = nil; exports.error = nil }
            } message: {
                Text(workshop.error ?? exports.error ?? "")
            }
        }
    }
}

struct WorkshopView: View {
    @ObservedObject var steam: SteamSession
    @ObservedObject var store: WorkshopStore
    @ObservedObject var exports: ExportStore
    @StateObject private var downloader = DownloadManager()
    @State private var directLink = ""
    @State private var downloadingID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("LumaForge").font(.largeTitle.bold())
                            Text(steam.steamID == nil ? "Paste a Workshop link or browse" : "Steam connected")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if steam.steamID == nil {
                            Button("Sign in") { steam.signIn() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("My Subscribed") { Task { await store.subscribed(steamID: steam.steamID!) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    HStack {
                        TextField("Paste Steam Workshop link", text: $directLink)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Download") {
                            guard let id = Self.workshopID(from: directLink) else {
                                downloader.error = "Paste a Steam Workshop item link with an ?id= number."
                                return
                            }
                            downloadingID = id
                            Task {
                                await downloader.downloadWorkshopItem(id: id)
                                if let url = downloader.downloadedURL {
                                    exports.importFiles([url])
                                }
                                downloadingID = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(downloader.downloading)
                    }

                    if let error = downloader.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if downloader.downloading {
                        ProgressView("Downloading…")
                    }

                    HStack {
                        TextField("Search Workshop", text: $store.query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await store.search() } }
                        Button { Task { await store.search() } } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if store.loading {
                        ProgressView().frame(maxWidth: .infinity).padding(30)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(store.items) { item in
                                HStack(spacing: 10) {
                                    NavigationLink {
                                        WorkshopDetail(item: item)
                                    } label: {
                                        WorkshopRow(item: item)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        downloadingID = item.id
                                        Task {
                                            await downloader.downloadWorkshopItem(id: item.id)
                                            if let url = downloader.downloadedURL { exports.importFiles([url]) }
                                            downloadingID = nil
                                        }
                                    } label: {
                                        Image(systemName: downloadingID == item.id ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    }
                                    .disabled(downloader.downloading)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Workshop")
        }
    }

    private static func workshopID(from text: String) -> String? {
        if let url = URL(string: text),
           let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           query.allSatisfy(\.isNumber) { return query }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.allSatisfy(\.isNumber) && trimmed.count > 5 ? trimmed : nil
    }
}

struct WorkshopRow: View {
    let item: WorkshopItem
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.previewURL) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 110, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(2)
                Text("#\(item.id)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct WorkshopDetail: View {
    let item: WorkshopItem
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AsyncImage(url: item.previewURL) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { Rectangle().fill(.quaternary) }
                }
                .frame(maxWidth: .infinity).frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                Text(item.title).font(.title.bold())
                Text("Workshop ID \(item.id)").foregroundStyle(.secondary)
                Text("Paste the Workshop link on the Workshop screen to download when Steam exposes a direct file.")
                    .foregroundStyle(.secondary)
                Button { openURL(item.pageURL) } label: {
                    Label("Open Workshop", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }.padding()
        }
        .navigationTitle("Wallpaper")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryView: View {
    @ObservedObject var store: ExportStore
    @State private var pick = false
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { pick = true } label: { Label("Import from Files", systemImage: "doc.badge.plus") }
                    Text("Downloaded Workshop files and manually imported media appear here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Imported") {
                    let urls = store.importedURLs()
                    if urls.isEmpty { ContentUnavailableView("Library empty", systemImage: "square.stack.3d.up") }
                    else {
                        ForEach(urls, id: \.self) { url in
                            HStack {
                                Image(systemName: "doc")
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Text(url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Export") {
                                    busy = true
                                    Task { await store.export(url); busy = false }
                                }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .fileImporter(isPresented: $pick, allowedContentTypes: [.data, .image, .movie], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { store.importFiles(urls) }
            }
            .overlay { if busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: ExportStore
    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty { ContentUnavailableView("No exports", systemImage: "arrow.down.circle") }
                else {
                    ForEach(store.records) { record in
                        HStack {
                            Image(systemName: "film")
                            VStack(alignment: .leading) {
                                Text(record.name).lineLimit(1)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: store.url(for: record)) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                    .onDelete { offsets in offsets.map { store.records[$0] }.forEach(store.delete) }
                }
            }.navigationTitle("Exports")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var steam: SteamSession
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
                Section("App") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Workshop App ID", value: "431960")
                }
            }.navigationTitle("Settings")
        }
    }
}
