import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: WallpaperStore
    var body: some View {
        TabView {
            NavigationStack { DiscoverView() }.tabItem { Label("Discover", systemImage: "sparkles") }
            NavigationStack { LibraryView() }.tabItem { Label("Library", systemImage: "square.stack.3d.up") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.primary)
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var store: WallpaperStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                HStack { Text("AetherWall").font(.largeTitle.bold()); Spacer() }
                TextField("Search Steam Workshop", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.search() } }
                if store.isLoading { ProgressView().padding() }
                ForEach(store.wallpapers) { wallpaper in
                    NavigationLink { WallpaperDetailView(wallpaper: wallpaper) } label: { WallpaperRow(wallpaper: wallpaper) }
                }
            }.padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.wallpapers.isEmpty { await store.search() } }
        .alert("Something went wrong", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") {} } message: { Text(store.error ?? "") }
    }
}

struct WallpaperRow: View {
    let wallpaper: Wallpaper
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary).frame(width: 82, height: 82).overlay(Image(systemName: "play.rectangle.fill").font(.title2))
            VStack(alignment: .leading, spacing: 5) { Text(wallpaper.title).font(.headline).foregroundStyle(.primary); Text(wallpaper.author).font(.subheadline).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct WallpaperDetailView: View {
    let wallpaper: Wallpaper
    var body: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 28).fill(.quaternary).aspectRatio(16/9, contentMode: .fit).overlay(Image(systemName: "play.fill").font(.largeTitle))
            Text(wallpaper.title).font(.title.bold()).frame(maxWidth: .infinity, alignment: .leading)
            Text("Steam Workshop • (wallpaper.author)").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: wallpaper.workshopURL) { Label("Open in Steam Workshop", systemImage: "safari").frame(maxWidth: .infinity).padding().background(.primary, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.background) }
            Spacer()
        }.padding()
        .navigationTitle("Wallpaper")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryView: View {
    var body: some View { ContentUnavailableView("Your Library", systemImage: "square.stack.3d.up", description: Text("Saved wallpapers will appear here.")) .navigationTitle("Library") }
}

struct SettingsView: View {
    var body: some View { List { Section("About") { Label("AetherWall", systemImage: "sparkles"); Text("A fresh Steam Workshop wallpaper browser for iPhone.").foregroundStyle(.secondary) } } .navigationTitle("Settings") }
}
