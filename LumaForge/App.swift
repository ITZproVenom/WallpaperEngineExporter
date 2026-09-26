import SwiftUI
import AVFoundation
import AuthenticationServices
import CryptoKit
import PhotosUI
import UniformTypeIdentifiers
import WebKit

struct WorkshopItem: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let previewURL: URL?
    let pageURL: URL
}

struct ImportedAsset: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String
    let kind: String
}

struct ExportRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let filename: String
    let createdAt: Date
}

enum AppError: LocalizedError {
    case invalidPackage
    case unsupportedAsset
    case exportFailed
    case invalidSteamResponse
    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "That file is not a readable Wallpaper Engine package."
        case .unsupportedAsset: return "This wallpaper format does not contain an exportable asset LumaForge can decode on iOS."
        case .exportFailed: return "The export failed."
        case .invalidSteamResponse: return "Steam did not return a valid identity response."
        }
    }
}

struct SteamOpenIDValidator {
    static func isValidSteamID(_ value: String) -> Bool {
        guard value.count == 17, value.allSatisfy(\.isNumber) else { return false }
        return value.hasPrefix("7656119")
    }
    static func steamID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
        guard values["openid.op_endpoint"] == "https://steamcommunity.com/openid/login" else { return nil }
        guard values["openid.mode"] == "id_res" else { return nil }
        let claimed = values["openid.claimed_id"] ?? ""
        guard let id = claimed.split(separator: "/").last.map(String.init), isValidSteamID(id) else { return nil }
        return id
    }
}

final class KeychainStore {
    private let service = "com.itzprovenom.lumaforge"
    func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"steamID",kSecValueData as String:data]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary,nil)
    }
    func load() -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"steamID",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess, let data=item as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    func clear() {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"steamID"]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class SteamSession: NSObject, ObservableObject {
    @Published private(set) var steamID: String?
    @Published var isSigningIn = false
    private let keychain = KeychainStore()
    private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
        steamID = keychain.load()
    }

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        let state = UUID().uuidString
        var components = URLComponents(string:"https://steamcommunity.com/openid/login")!
        components.queryItems = [
            URLQueryItem(name:"openid.ns",value:"http://specs.openid.net/auth/2.0"),
            URLQueryItem(name:"openid.mode",value:"checkid_setup"),
            URLQueryItem(name:"openid.return_to",value:"lumaforge://steam-callback?state=\(state)"),
            URLQueryItem(name:"openid.realm",value:"lumaforge://"),
            URLQueryItem(name:"openid.identity",value:"http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name:"openid.claimed_id",value:"http://specs.openid.net/auth/2.0/identifier_select")
        ]
        guard let url=components.url else { isSigningIn=false; return }
        let auth = ASWebAuthenticationSession(url:url,callbackURLScheme:"lumaforge") { [weak self] callback,error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isSigningIn=false }
                guard error == nil, let callback, let id=SteamOpenIDValidator.steamID(from:callback) else { return }
                self.steamID=id
                self.keychain.save(id)
            }
        }
        auth.presentationContextProvider = self
        auth.prefersEphemeralWebBrowserSession = false
        session = auth
        auth.start()
    }

    func signOut() {
        steamID=nil
        keychain.clear()
    }
}

extension SteamSession: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

@MainActor
final class WorkshopStore: ObservableObject {
    @Published var items:[WorkshopItem]=[]
    @Published var query=""
    @Published var loading=false
    @Published var error:String?
    private let appID="431960"

    func search() async {
        loading=true
        defer { loading=false }
        do {
            var c=URLComponents(string:"https://steamcommunity.com/workshop/browse/")!
            c.queryItems=[URLQueryItem(name:"appid",value:appID),URLQueryItem(name:"section",value:"items")]
            if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                c.queryItems?.append(URLQueryItem(name:"searchtext",value:query))
            }
            var req=URLRequest(url:c.url!)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",forHTTPHeaderField:"User-Agent")
            let (data,_)=try await URLSession.shared.data(for:req)
            items=parseHTML(String(decoding:data,as:UTF8.self))
        } catch { error=error.localizedDescription }
    }

    private func parseHTML(_ html:String)->[WorkshopItem] {
        guard let re=try? NSRegularExpression(pattern:#"<a[^>]+href="([^"]*sharedfiles/filedetails/\?id=(\d+)[^"]*)"[^>]*>(.*?)</a>"#,options:[.caseInsensitive,.dotMatchesLineSeparators]) else { return [] }
        var result:[WorkshopItem]=[], seen=Set<String>()
        for match in re.matches(in:html,range:NSRange(html.startIndex...,in:html)) {
            guard let idRange=Range(match.range(at:2),in:html),let hrefRange=Range(match.range(at:1),in:html),let titleRange=Range(match.range(at:3),in:html) else { continue }
            let id=String(html[idRange]); guard seen.insert(id).inserted else { continue }
            let raw=String(html[hrefRange]).replacingOccurrences(of:"&amp;",with:"&")
            let page=URL(string:raw.hasPrefix("http") ? raw : "https://steamcommunity.com\(raw)")!
            let title=String(html[titleRange]).replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
            let ns=html as NSString
            let start=max(0,match.range.location-1800)
            let window=ns.substring(with:NSRange(location:start,length:min(ns.length-start,match.range.length+3200)))
            let preview=try? NSRegularExpression(pattern:#"https?://[^"' ]+\.(?:jpg|jpeg|png|webp)"#,options:.caseInsensitive)
            let previewURL=preview?.firstMatch(in:window,range:NSRange(window.startIndex...,in:window)).flatMap { Range($0.range,in:window) }.flatMap { URL(string:String(window[$0]).replacingOccurrences(of:"&amp;",with:"&")) }
            result.append(WorkshopItem(id:id,title:title.isEmpty ? "Untitled" : title,previewURL:previewURL,pageURL:page))
            if result.count >= 50 { break }
        }
        return result
    }
}

enum BinaryAssetKind: String, Codable {
    case png,jpeg,mp4,webm
}
struct BinaryAsset {
    let kind: BinaryAssetKind
    let data: Data
}
struct BinaryAssetScanner {
    static func scan(_ data:Data)->[BinaryAsset] {
        var out:[BinaryAsset]=[]
        let bytes=[UInt8](data)
        func append(_ kind:BinaryAssetKind,_ index:Int) {
            guard index < bytes.count else { return }
            out.append(BinaryAsset(kind:kind,data:data.subdata(in:index..<bytes.count)))
        }
        if let i=bytes.firstIndex(of:0x89), i+8<=bytes.count, Array(bytes[i..<i+8]) == [0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A] { append(.png,i) }
        if bytes.count>3 {
            for i in 0..<(bytes.count-3) where bytes[i]==0xFF && bytes[i+1]==0xD8 && bytes[i+2]==0xFF { append(.jpeg,i); break }
        }
        if let i=bytes.firstIndex(of:0x66), i+4<=bytes.count, Array(bytes[i..<i+4]) == [0x66,0x74,0x79,0x70] { append(.mp4,max(0,i-4)) }
        if bytes.count>=4 {
            for i in 0...(bytes.count-4) where Array(bytes[i..<i+4]) == [0x1A,0x45,0xDF,0xA3] { append(.webm,i); break }
        }
        return out
    }
}

struct PackageInspector {
    static func inspect(url:URL) throws -> [ImportedAsset] {
        let ext=url.pathExtension.lowercased()
        if ["mp4","mov","m4v","webm","png","jpg","jpeg"].contains(ext) {
            return [ImportedAsset(url:url,title:url.deletingPathExtension().lastPathComponent,kind:ext.uppercased())]
        }
        let data=try Data(contentsOf:url)
        var results:[ImportedAsset]=[]
        for asset in BinaryAssetScanner.scan(data) {
            let ext=asset.kind.rawValue
            let out=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try asset.data.write(to:out)
            results.append(ImportedAsset(url:out,title:"Extracted (ext.uppercased())",kind:ext.uppercased()))
        }
        guard !results.isEmpty else { throw AppError.unsupportedAsset }
        return results
    }
}

@MainActor
final class ExportStore: ObservableObject {
    @Published private(set) var records:[ExportRecord]=[]
    @Published var error:String?
    private let fm=FileManager.default

    init(){ load() }

    func importFiles(_ urls:[URL]) {
        for url in urls {
            let access=url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let ext=url.pathExtension.lowercased()
            let target=importsDirectory().appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at:target)
            try? fm.copyItem(at:url,to:target)
        }
    }

    func importedURLs()->[URL] {
        (try? fm.contentsOfDirectory(at:importsDirectory(),includingPropertiesForKeys:nil).filter{!$0.lastPathComponent.hasPrefix(".")}) ?? []
    }

    func export(url:URL) async {
        do {
            let output=exportsDirectory().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).mp4")
            let ext=url.pathExtension.lowercased()
            if ["mp4","mov","m4v"].contains(ext) {
                try await transcodeVideo(url,to:output)
            } else if ["png","jpg","jpeg"].contains(ext) {
                try await stillVideo(url,to:output)
            } else {
                let extracted=try PackageInspector.inspect(url:url)
                guard let media=extracted.first(where:{$0.kind=="MP4" || $0.kind=="PNG" || $0.kind=="JPEG"}) else { throw AppError.unsupportedAsset }
                if media.kind=="MP4" { try await transcodeVideo(media.url,to:output) }
                else { try await stillVideo(media.url,to:output) }
            }
            records.insert(ExportRecord(id:UUID(),name:output.deletingPathExtension().lastPathComponent,filename:output.lastPathComponent,createdAt:Date()),at:0)
            save()
        } catch { error=error.localizedDescription }
    }

    func url(for record:ExportRecord)->URL { exportsDirectory().appendingPathComponent(record.filename) }
    func delete(_ record:ExportRecord){ try? fm.removeItem(at:url(for:record)); records.removeAll{$0.id==record.id}; save() }

    private func transcodeVideo(_ input:URL,to output:URL) async throws {
        let asset=AVAsset(url:input)
        guard let exporter=AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetHighestQuality) else { throw AppError.exportFailed }
        exporter.outputURL=output
        exporter.outputFileType=.mp4
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed { c.resume() } else { c.resume(throwing: exporter.error ?? AppError.exportFailed) }
            }
        }
    }

    private func stillVideo(_ input:URL,to output:URL) async throws {
        guard let image=UIImage(contentsOfFile:input.path),let cg=image.cgImage else { throw AppError.exportFailed }
        let width=min(max(cg.width,2),4096),height=min(max(cg.height,2),4096)
        let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        let inputWriter=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:inputWriter)
        writer.add(inputWriter); writer.startWriting(); writer.startSession(atSourceTime:.zero)
        var pixel:CVPixelBuffer?
        CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel)
        guard let pixel else { throw AppError.exportFailed }
        CVPixelBufferLockBaseAddress(pixel,[])
        if let base=CVPixelBufferGetBaseAddress(pixel) {
            let ctx=CGContext(data:base,width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        }
        CVPixelBufferUnlockBaseAddress(pixel,[])
        for frame in 0..<90 {
            while !inputWriter.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            adaptor.append(pixel,withPresentationTime:CMTime(value:CMTimeValue(frame),timescale:30))
        }
        inputWriter.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppError.exportFailed }
    }

    private func importsDirectory()->URL { let u=base().appendingPathComponent("Imports",isDirectory:true);try? fm.createDirectory(at:u,withIntermediateDirectories:true);return u }
    private func exportsDirectory()->URL { let u=base().appendingPathComponent("Exports",isDirectory:true);try? fm.createDirectory(at:u,withIntermediateDirectories:true);return u }
    private func base()->URL { fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LumaForge",isDirectory:true) }
    private func manifest()->URL { base().appendingPathComponent("exports.json") }
    private func load(){ guard let data=try? Data(contentsOf:manifest()),let value=try? JSONDecoder().decode([ExportRecord].self,from:data) else{return};records=value }
    private func save(){ try? JSONEncoder().encode(records).write(to:manifest(),options:.atomic) }
}

struct RootView: View {
    @StateObject private var workshop=WorkshopStore()
    @StateObject private var exports=ExportStore()
    @StateObject private var steam=SteamSession()
    @State private var showImporter=false
    var body: some View {
        TabView {
            DiscoverView(store:workshop,steam:steam)
                .tabItem{Label("Workshop",systemImage:"sparkles")}
            LibraryView(exports:exports,showImporter:$showImporter)
                .tabItem{Label("Library",systemImage:"square.stack.3d.up")}
            ExportHistoryView(store:exports)
                .tabItem{Label("Exports",systemImage:"arrow.down.circle")}
            SettingsView(steam:steam)
                .tabItem{Label("Settings",systemImage:"gearshape")}
        }
        .task { await workshop.search() }
        .alert("LumaForge",isPresented:Binding(get:{exports.error != nil || workshop.error != nil},set:{if !$0{exports.error=nil;workshop.error=nil}})){Button("OK"){exports.error=nil;workshop.error=nil}}message:{Text(exports.error ?? workshop.error ?? "")}
    }
}

struct DiscoverView: View {
    @ObservedObject var store:WorkshopStore
    @ObservedObject var steam:SteamSession
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        VStack(alignment:.leading,spacing:4){Text("LumaForge").font(.largeTitle.bold());Text(steam.steamID == nil ? "Browse Wallpaper Engine" : "Steam \(steam.steamID!.suffix(6))").foregroundStyle(.secondary)}
                        Spacer()
                        if steam.steamID == nil { Button("Sign in"){steam.signIn()}.buttonStyle(.borderedProminent) }
                    }
                    HStack {
                        TextField("Search Workshop",text:$store.query).textFieldStyle(.roundedBorder).onSubmit{Task{await store.search()}}
                        Button{Task{await store.search()}}label:{Image(systemName:"magnifyingglass")}.buttonStyle(.borderedProminent)
                    }
                    LazyVStack(spacing:12) {
                        ForEach(store.items) { item in
                            NavigationLink{WorkshopDetail(item:item)}label{WorkshopRow(item:item)}.buttonStyle(.plain)
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
            AsyncImage(url:item.previewURL){phase in
                switch phase { case .success(let image): image.resizable().scaledToFill(); default: Rectangle().fill(.quaternary) }
            }.frame(width:110,height:72).clipShape(RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:4){Text(item.title).font(.headline).lineLimit(2);Text("#\(item.id)").font(.caption).foregroundStyle(.secondary)}
            Spacer();Image(systemName:"chevron.right").foregroundStyle(.tertiary)
        }.padding(10).background(.thinMaterial,in:RoundedRectangle(cornerRadius:18))
    }
}

struct WorkshopDetail: View {
    let item:WorkshopItem
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                AsyncImage(url:item.previewURL){phase in
                    switch phase { case .success(let image): image.resizable().scaledToFill(); default: Rectangle().fill(.quaternary) }
                }.frame(maxWidth:.infinity).frame(height:260).clipShape(RoundedRectangle(cornerRadius:26))
                Text(item.title).font(.title.bold())
                Text("Workshop ID \(item.id)").font(.subheadline).foregroundStyle(.secondary)
                Text("Steam controls Workshop installation through the Steam Client. LumaForge keeps the export pipeline local and opens the official Workshop item when the original package needs to be obtained.")
                    .foregroundStyle(.secondary)
                Button{openURL(item.pageURL)}label:{Label("Open in Steam",systemImage:"safari").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
            }.padding()
        }.navigationTitle("Wallpaper").navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryView: View {
    @ObservedObject var exports:ExportStore
    @Binding var showImporter:Bool
    @State private var busy=false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button{showImporter=true}label:{Label("Import Workshop file",systemImage:"doc.badge.plus")}
                    Text("Import a .pkg, image, video, or project folder from Files. LumaForge extracts supported assets and converts them to MP4 locally.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Imported files") {
                    let files=exports.importedURLs()
                    if files.isEmpty { ContentUnavailableView("Library empty",systemImage:"square.stack.3d.up") }
                    else {
                        ForEach(files,id:\.self) { url in
                            HStack {
                                Image(systemName:"doc")
                                VStack(alignment:.leading){Text(url.lastPathComponent).lineLimit(1);Text(url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)}
                                Spacer()
                                Button("Export"){busy=true;Task{await exports.export(url:url);busy=false}}.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }.navigationTitle("Library")
            .fileImporter(isPresented:$showImporter,allowedContentTypes:[.data,.image,.movie],allowsMultipleSelection:true){result in
                if case .success(let urls)=result { exports.importFiles(urls) }
            }
            .overlay{if busy{ProgressView().padding(20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))}}
        }
    }
}

struct ExportHistoryView: View {
    @ObservedObject var store:ExportStore
    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty { ContentUnavailableView("No exports",systemImage:"arrow.down.circle") }
                else {
                    ForEach(store.records){record in
                        HStack {
                            Image(systemName:"film")
                            VStack(alignment:.leading){Text(record.name).lineLimit(1);Text(record.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)}
                            Spacer()
                            ShareLink(item:store.url(for:record)){Image(systemName:"square.and.arrow.up")}.buttonStyle(.borderless)
                        }
                    }.onDelete{indices in indices.map{store.records[$0]}.forEach(store.delete)}
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
                    } else {
                        Button("Sign in with Steam"){steam.signIn()}
                    }
                }
                Section("App") {
                    LabeledContent("Version",value:"1.0.0")
                    LabeledContent("Wallpaper Engine",value:"431960")
                }
                Section("Export") {
                    Text("Video wallpapers are transcoded to MP4. Still images become a 3-second H.264 MP4. Scene packages are scanned for embedded media assets.")
                }
            }.navigationTitle("Settings")
        }
    }
}

@main struct LumaForgeApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}
