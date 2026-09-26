import SwiftUI

@main
struct LumaForgeApp: App {
    @StateObject private var steam=SteamSession()
    @StateObject private var workshop=WorkshopStore()
    @StateObject private var exports=ExportStore()
    @State private var importer=false

    var body: some Scene {
        WindowGroup {
            TabView {
                WorkshopView(steam:steam,store:workshop)
                    .tabItem { Label("Workshop",systemImage:"sparkles") }
                LibraryView(store:exports,showImporter:$importer)
                    .tabItem { Label("Library",systemImage:"square.stack.3d.up") }
                HistoryView(store:exports)
                    .tabItem { Label("Exports",systemImage:"arrow.down.circle") }
                SettingsView(steam:steam)
                    .tabItem { Label("Settings",systemImage:"gearshape") }
            }
            .tint(.indigo)
            .task { if workshop.items.isEmpty { await workshop.search() } }
            .alert("LumaForge",isPresented:Binding(get:{workshop.error != nil || exports.error != nil},set:{if !$0 {workshop.error=nil;exports.error=nil}})) {
                Button("OK") { workshop.error=nil; exports.error=nil }
            } message: { Text(workshop.error ?? exports.error ?? "") }
        }
    }
}

struct WorkshopView: View {
    @ObservedObject var steam:SteamSession
    @ObservedObject var store:WorkshopStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        VStack(alignment:.leading) {
                            Text("LumaForge").font(.largeTitle.bold())
                            Text(steam.steamID == nil ? "Wallpaper Engine Workshop" : "Steam account connected").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if steam.steamID == nil { Button("Sign in"){steam.signIn()}.buttonStyle(.borderedProminent) }
                    }
                    HStack {
                        TextField("Search Workshop",text:$store.query).textFieldStyle(.roundedBorder).onSubmit{Task{await store.search()}}
                        Button{Task{await store.search()}} label:{Image(systemName:"magnifyingglass")}.buttonStyle(.borderedProminent)
                    }
                    if store.loading { ProgressView().frame(maxWidth:.infinity).padding(30) }
                    else {
                        LazyVStack(spacing:12) {
                            ForEach(store.items) { item in
                                NavigationLink { WorkshopDetail(item:item) } label: { WorkshopRow(item:item) }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding()
            }.navigationTitle("Workshop").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct WorkshopRow: View {
    let item:WorkshopItem
    var body: some View {
        HStack(spacing:12) {
            AsyncImage(url:item.previewURL) { phase in
                if case .success(let image)=phase { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
            }.frame(width:110,height:72).clipShape(RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:4) { Text(item.title).font(.headline).lineLimit(2); Text("#\(item.id)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Image(systemName:"chevron.right").foregroundStyle(.tertiary)
        }.padding(10).background(.thinMaterial,in:RoundedRectangle(cornerRadius:18))
    }
}

struct WorkshopDetail: View {
    let item:WorkshopItem
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                AsyncImage(url:item.previewURL) { phase in
                    if case .success(let image)=phase { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                }.frame(maxWidth:.infinity).frame(height:260).clipShape(RoundedRectangle(cornerRadius:26))
                Text(item.title).font(.title.bold())
                Text("Workshop ID \(item.id)").font(.subheadline).foregroundStyle(.secondary)
                Text("Workshop package installation is controlled by Steam. Once the package is available in Files, LumaForge handles inspection and export locally.")
                    .foregroundStyle(.secondary)
                Button{openURL(item.pageURL)}label:{Label("Open Workshop",systemImage:"safari").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
            }.padding()
        }.navigationTitle("Wallpaper").navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryView: View {
    @ObservedObject var store:ExportStore
    @Binding var showImporter:Bool
    @State private var busy=false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button{showImporter=true}label:{Label("Import from Files",systemImage:"doc.badge.plus")}
                    Text("Import a Workshop package, project media, image, or video. Supported embedded media can then be exported to MP4.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Imported") {
                    let urls=store.importedURLs()
                    if urls.isEmpty { ContentUnavailableView("Library empty",systemImage:"square.stack.3d.up") }
                    else {
                        ForEach(urls,id:\.self) { url in
                            HStack {
                                Image(systemName:"doc")
                                VStack(alignment:.leading) { Text(url.lastPathComponent).lineLimit(1); Text(url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("Export") { busy=true; Task { await store.export(url); busy=false } }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .fileImporter(isPresented:$showImporter,allowedContentTypes:[.data,.image,.movie],allowsMultipleSelection:true) { result in
                if case .success(let urls)=result { store.importFiles(urls) }
            }
            .overlay { if busy { ProgressView().padding(20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)) } }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store:ExportStore
    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty { ContentUnavailableView("No exports",systemImage:"arrow.down.circle") }
                else {
                    ForEach(store.records) { record in
                        HStack {
                            Image(systemName:"film")
                            VStack(alignment:.leading) { Text(record.name).lineLimit(1); Text(record.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            ShareLink(item:store.url(for:record)){Image(systemName:"square.and.arrow.up")}.buttonStyle(.borderless)
                        }
                    }.onDelete { indexSet in indexSet.map { store.records[$0] }.forEach(store.delete) }
                }
            }.navigationTitle("Exports")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var steam:SteamSession
    var body: some View {
        NavigationStack {
            List {
                Section("Steam") {
                    if let id=steam.steamID {
                        LabeledContent("Steam ID",value:id)
                        Button("Sign out",role:.destructive){steam.signOut()}
                    } else { Button("Sign in with Steam"){steam.signIn()} }
                }
                Section("Export") {
                    Text("Video media is transcoded to MP4. Still images become a three-second H.264 MP4. Embedded image/video assets are extracted when their signatures are present.")
                }
                Section("About") {
                    LabeledContent("Version",value:"1.0.0")
                    LabeledContent("Workshop App ID",value:"431960")
                }
            }.navigationTitle("Settings")
        }
    }
}
