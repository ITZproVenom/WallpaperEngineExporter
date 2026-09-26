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
    @State private var showSubscriptions = false

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
                            Button("My Subscribed") { showSubscriptions = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    HStack {
                        TextField("Paste Steam Workshop link or ID", text: $directLink)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Convert") {
                            guard let id = Self.workshopID(from: directLink) else {
                                downloader.error = "Paste a Steam Workshop item link or numeric Workshop ID."
                                return
                            }
                            startDownload(id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(downloader.downloading)
                    }

                    if let error = downloader.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if downloader.downloading {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: downloader.progress)
                            Text(downloader.status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
                                        startDownload(item.id)
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
            .sheet(isPresented: $showSubscriptions) {
                NavigationStack {
                    SteamSubscriptionsView(steamID: steam.steamID ?? "") { subscribed in
                        store.setSubscribed(subscribed)
                        showSubscriptions = false
                    }
                    .navigationTitle("Steam Subscriptions")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSubscriptions = false }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        Text("If Steam shows its login page, sign in there. Your Steam password is handled by Steam's web page, not LumaForge.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                    }
                }
            }
        }
    }

    private func startDownload(_ id: String) {
        downloadingID = id
        Task {
            await downloader.downloadWorkshopItem(id: id)
            if let url = downloader.downloadedURL {
                exports.importServerMP4(url, workshopID: id)
            }
            downloadingID = nil
        }
    }

    private static func workshopID(from text: String) -> String? {
        if let url = URL(string: text), let id = DownloadManager.workshopID(from: url) {
            return id
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 6 && trimmed.count <= 20 && trimmed.allSatisfy(\.isNumber) ? trimmed : nil
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
                    if case .success(let image) { image.resizable().scaledToFill() }
                    else { Rectangle().fill(.quaternary) }
                }
                .frame(maxWidth: .infinity).frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                Text(item.title).font(.title.bold())
                Text("Workshop ID \(item.id)").foregroundStyle(.secondary)
                Text("Conversion runs on the LumaForge server. The iPhone receives only the final MP4.")
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
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Server-completed MP4s are stored here.", systemImage: "server.rack")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Downloads") {
                    if store.records.isEmpty {
                        ContentUnavailableView("Library empty", systemImage: "square.stack.3d.up")
                    } else {
                        ForEach(store.records) { record in
                            HStack {
                                Image(systemName: "film")
                                VStack(alignment: .leading) {
                                    Text(record.name).lineLimit(1)
                                    Text("Workshop \(record.workshopID)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: store.url(for: record)) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(record)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: ExportStore
    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
                } else {
                    ForEach(store.records) { record in
                        HStack {
                            Image(systemName: "film")
                            VStack(alignment: .leading) {
                                Text(record.name).lineLimit(1)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: store.url(for: record)) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { store.records[$0] }.forEach(store.delete)
                    }
                }
            }
            .navigationTitle("Downloads")
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
                Section("Server") {
                    Text("Workshop packages, extraction, TEX decoding, and MP4 conversion run on the LumaForge server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("App") {
                    LabeledContent("Version", value: "2.0.0")
                    LabeledContent("Workshop App ID", value: "431960")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
