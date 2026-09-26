import Foundation

struct PackageAsset: Identifiable, Hashable {
    let id=UUID()
    let url: URL
    let kind: String
}

enum PackageInspector {
    static func assets(in url: URL) throws -> [PackageAsset] {
        let ext=url.pathExtension.lowercased()
        if ["png","jpg","jpeg","mp4","mov","m4v"].contains(ext) { return [PackageAsset(url:url,kind:ext.uppercased())] }
        let data=try Data(contentsOf:url)
        let bytes=[UInt8](data)
        var result:[PackageAsset]=[]
        if let i=bytes.firstIndex(of:0x89), i+8<=bytes.count, Array(bytes[i..<i+8]) == [0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A] {
            let out=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            try data.subdata(in:i..<bytes.count).write(to:out); result.append(.init(url:out,kind:"PNG"))
        }
        for i in 0..<max(0,bytes.count-3) where bytes[i]==0xFF && bytes[i+1]==0xD8 && bytes[i+2]==0xFF {
            let out=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
            try data.subdata(in:i..<bytes.count).write(to:out); result.append(.init(url:out,kind:"JPG")); break
        }
        if result.isEmpty { throw ExportError.unsupported }
        return result
    }
}
