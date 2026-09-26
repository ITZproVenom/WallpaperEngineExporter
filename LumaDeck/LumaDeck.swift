import SwiftUI
import AVFoundation
import UIKit
import SafariServices
import UniformTypeIdentifiers

struct Wallpaper: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: URL?
    let page: URL
}

struct ExportItem: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let file: String
    let date: Date
}

@MainActor final class Store: ObservableObject {
    @Published var wallpapers: [Wallpaper] = []
    @Published var query = ""
    @Published var loading = false
    @Published var error: String?
    @Published var imports: [URL] = []
    @Published var exports: [ExportItem] = []

    private let workshop = URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960&section=items")!
    private let fm = FileManager.default

    init() { loadFiles(); loadExports() }

    func search() async {
        loading = true
        defer { loading = false }
        do {
            var c = URLComponents(url: workshop, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "appid", value: "431960"), URLQueryItem(name: "section", value: "items")]
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                c.queryItems?.append(URLQueryItem(name: "searchtext", value: query))
            }
            var r = URLRequest(url: c.url!)
            r.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (d, _) = try await URLSession.shared.data(for: r)
            let html = String(decoding: d, as: UTF8.self)
            wallpapers = parse(html)
        } catch { self.error = error.localizedDescription }
    }

    private func parse(_ html: String) -> [Wallpaper] {
        let p = #"<a[^>]+href="([^"]*sharedfiles/filedetails/\?id=(\d+)[^"]*)"[^>]*>(.*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        var out: [Wallpaper] = [], seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let ir = Range(m.range(at: 2), in: html), let hr = Range(m.range(at: 1), in: html), let tr = Range(m.range(at: 3), in: html) else { continue }
            let id = String(html[ir]); if !seen.insert(id).inserted { continue }
            let href = String(html[hr]).replacingOccurrences(of: "&amp;", with: "&")
            guard let page = URL(string: href.hasPrefix("http") ? href : "https://steamcommunity.com\(href)") else { continue }
            let title = String(html[tr]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = html as NSString
            let start = max(0, m.range.location - 1400)
            let window = ns.substring(with: NSRange(location: start, length: min(ns.length - start, m.range.length + 2600)))
            let image = try? NSRegularExpression(pattern: #"https?://[^"' ]+\.(?:jpg|jpeg|png|webp)"#, options: .caseInsensitive)
            let preview = image.flatMap { rr in rr.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)).flatMap { Range($0.range, in: window) }.flatMap { URL(string: String(window[$0]).replacingOccurrences(of: "&amp;", with: "&")) } }
            out.append(Wallpaper(id:id, title:title.isEmpty ? "Untitled" : title, preview:preview, page:page))
            if out.count == 40 { break }
        }
        return out
    }

    func importURLs(_ urls: [URL]) {
        let dir = importDir()
        for u in urls {
            let access = u.startAccessingSecurityScopedResource(); defer { if access { u.stopAccessingSecurityScopedResource() } }
            let dst = dir.appendingPathComponent(u.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: u, to: dst)
        }
        loadFiles()
    }

    func loadFiles() {
        imports = (try? fm.contentsOfDirectory(at: importDir(), includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }) ?? []
    }

    func export(_ url: URL) async throws {
        let dir = exportDir()
        let dst = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).mp4")
        if ["mp4","mov","m4v"].contains(url.pathExtension.lowercased()) {
            let asset = AVAsset(url: url)
            guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw ExportError.failed }
            ex.outputURL = dst; ex.outputFileType = .mp4
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                ex.exportAsynchronously { ex.status == .completed ? c.resume() : c.resume(throwing: ex.error ?? ExportError.failed) }
            }
        } else {
            guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else { throw ExportError.failed }
            try await makeStillVideo(cg, width: max(2,cg.width), height: max(2,cg.height), to: dst)
        }
        exports.insert(ExportItem(id: UUID(), name: dst.deletingPathExtension().lastPathComponent, file: dst.lastPathComponent, date: Date()), at: 0)
        saveExports()
    }

    private func makeStillVideo(_ cg: CGImage, width: Int, height: Int, to url: URL) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pb)
        guard let pb else { throw ExportError.failed }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base=CVPixelBufferGetBaseAddress(pb) {
            let ctx=CGContext(data:base,width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pb),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        for i in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            a.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished(); await w.finishWriting()
        if w.status != .completed { throw w.error ?? ExportError.failed }
    }

    func exportURL(_ e: ExportItem) -> URL { exportDir().appendingPathComponent(e.file) }
    func deleteExport(_ e: ExportItem) { try? fm.removeItem(at: exportURL(e)); exports.removeAll{$0.id == e.id}; saveExports() }

    private func importDir() -> URL { let u=appSupport("Imports"); try? fm.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func exportDir() -> URL { let u=documents("Exports"); try? fm.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func documents(_ n:String)->URL { fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(n,isDirectory:true) }
    private func appSupport(_ n:String)->URL { fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(n,isDirectory:true) }
    private func manifest()->URL { documents("Exports").appendingPathComponent("index.json") }
    private func loadExports(){ guard let d=try? Data(contentsOf:manifest()), let x=try? JSONDecoder().decode([ExportItem].self,from:d) else{return}; exports=x }
    private func saveExports(){ try? JSONEncoder().encode(exports).write(to:manifest(),options:.atomic) }
}
enum ExportError: LocalizedError { case failed; var errorDescription:String? { "The export could not be completed." } }

struct ContentView: View {
    @StateObject private var s = Store()
    var body: some View {
        TabView {
            Discover(s:s).tabItem{Label("Discover",systemImage:"sparkles")}
            Library(s:s).tabItem{Label("Library",systemImage:"rectangle.stack.fill")}
            Exports(s:s).tabItem{Label("Exports",systemImage:"arrow.down.circle.fill")}
            Settings().tabItem{Label("Settings",systemImage:"gearshape.fill")}
        }.tint(.indigo).task { if s.wallpapers.isEmpty { await s.search() } }
        .alert("Error",isPresented:Binding(get:{s.error != nil},set:{if !$0{s.error=nil}})){Button("OK"){s.error=nil}}message:{Text(s.error ?? "")}
    }
}

struct Discover: View {
    @ObservedObject var s: Store
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment:.leading,spacing:16) {
                Text("LumaDeck").font(.largeTitle.bold())
                Text("Discover Wallpaper Engine Workshop content.").foregroundStyle(.secondary)
                HStack { TextField("Search Steam Workshop",text:$s.query).textFieldStyle(.roundedBorder).onSubmit{Task{await s.search()}}
                    Button{Task{await s.search()}}label:{Image(systemName:"magnifyingglass").frame(width:42,height:42)}.buttonStyle(.borderedProminent) }
                if s.loading { ProgressView().frame(maxWidth:.infinity).padding(40) }
                else { ForEach(s.wallpapers){ w in NavigationLink{Detail(w:w)}label:{Row(w:w)}.buttonStyle(.plain) } }
            }.padding() }.navigationTitle("Discover")
        }
    }
}
struct Row: View { let w: Wallpaper; var body: some View { HStack(spacing:12){
    AsyncImage(url:w.preview){x in x.resizable().scaledToFill()}placeholder:{Rectangle().fill(.quaternary)}
    .frame(width:110,height:72).clipShape(RoundedRectangle(cornerRadius:14))
    VStack(alignment:.leading){Text(w.title).font(.headline).lineLimit(2);Text("Workshop • \(w.id)").font(.caption).foregroundStyle(.secondary)}
    Spacer();Image(systemName:"chevron.right").foregroundStyle(.tertiary)
}.padding(10).background(.thinMaterial,in:RoundedRectangle(cornerRadius:18)) } }
struct Detail: View { let w:Wallpaper; @State private var open=false; var body: some View { ScrollView{VStack(alignment:.leading,spacing:18){
    AsyncImage(url:w.preview){x in x.resizable().scaledToFill()}placeholder:{Rectangle().fill(.quaternary)}.frame(maxWidth:.infinity).frame(height:240).clipShape(RoundedRectangle(cornerRadius:24))
    Text(w.title).font(.title.bold()); Text("Steam Workshop ID \(w.id)").foregroundStyle(.secondary)
    Text("Steam hosts the original Workshop package. LumaDeck uses public Workshop pages for discovery and opens the official item page for the actual Steam-controlled content flow.")
    Button{open=true}label:{Label("Open Steam Workshop",systemImage:"safari").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
}.padding()}.navigationTitle("Wallpaper").navigationBarTitleDisplayMode(.inline).sheet(isPresented:$open){SFSafari(url:w.page).ignoresSafeArea()} } }
struct SFSafari:UIViewControllerRepresentable { let url:URL; func makeUIViewController(context:Context)->SFSafariViewController{SFSafariViewController(url:url)};func updateUIViewController(_ c:SFSafariViewController,context:Context){} }

struct Library: View { @ObservedObject var s:Store; @State private var pick=false; @State private var busy=false; var body: some View { NavigationStack{List{
    Section{Button{pick=true}label:{Label("Import video or image",systemImage:"square.and.arrow.down")}
    Text("Bring media onto the device, then export it as MP4.").font(.footnote).foregroundStyle(.secondary)}
    Section("Imported"){if s.imports.isEmpty{ContentUnavailableView("Library empty",systemImage:"rectangle.stack")}else{ForEach(s.imports,id:\.self){u in HStack{Image(systemName:u.pathExtension.lowercased()=="mp4" ? "film":"photo");Text(u.lastPathComponent).lineLimit(1);Spacer();Button("MP4"){busy=true;Task{do{try await s.export(u)}catch{s.error=error.localizedDescription};busy=false}}.buttonStyle(.bordered)}}}}
}.navigationTitle("Library").fileImporter(isPresented:$pick,allowedContentTypes:[.movie,.image],allowsMultipleSelection:true){r in if case .success(let u)=r{s.importURLs(u)}}.overlay{if busy{ProgressView().padding(20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))}} } } }

struct Exports: View {
    @ObservedObject var s: Store
    var body: some View {
        NavigationStack {
            List {
                if s.exports.isEmpty {
                    ContentUnavailableView("No exports yet", systemImage: "arrow.down.circle")
                } else {
                    ForEach(s.exports) { e in
                        HStack {
                            Image(systemName: "film")
                            VStack(alignment: .leading) {
                                Text(e.name)
                                Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: s.exportURL(e)) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet { s.deleteExport(s.exports[index]) }
                    }
                }
            }
            .navigationTitle("Exports")
        }
    }
}

struct Settings: View {
    var body: some View {
        NavigationStack {
            List {
                Section("LumaDeck") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Steam App ID", value: "431960")
                }
                Section("About") {
                    Text("Clean-room rebuild from the original Wallpaper Engine mobile discovery/export idea. No previous project implementation is used.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
@main struct LumaDeckApp: App { var body:some Scene { WindowGroup { ContentView() } } }
