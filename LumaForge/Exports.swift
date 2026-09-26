import Foundation
import AVFoundation
import UIKit

@MainActor
final class ExportStore: ObservableObject {
    @Published private(set) var records:[ExportRecord]=[]
    @Published var error:String?
    private let fm=FileManager.default

    init(){ load() }

    func importFiles(_ urls:[URL]) {
        let dir=importsDirectory()
        for url in urls {
            let access=url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dst=dir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at:dst); try? fm.copyItem(at:url,to:dst)
        }
    }

    func importedURLs()->[URL] {
        (try? fm.contentsOfDirectory(at:importsDirectory(),includingPropertiesForKeys:nil).filter{ !$0.lastPathComponent.hasPrefix(".") }) ?? []
    }

    func export(_ source:URL) async {
        do {
            let asset=try PackageInspector.assets(in:source).first ?? { throw ExportError.unsupported }()
            let output=exportsDirectory().appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).mp4")
            switch asset.kind {
            case "MP4","MOV","M4V": try await transcode(asset.url,to:output)
            default: try await still(asset.url,to:output)
            }
            records.insert(.init(id:UUID(),name:output.deletingPathExtension().lastPathComponent,filename:output.lastPathComponent,createdAt:Date()),at:0)
            save()
        } catch { error=error.localizedDescription }
    }

    func url(for record:ExportRecord)->URL { exportsDirectory().appendingPathComponent(record.filename) }
    func delete(_ record:ExportRecord){ try? fm.removeItem(at:url(for:record)); records.removeAll{$0.id==record.id}; save() }

    private func transcode(_ input:URL,to output:URL) async throws {
        let asset=AVAsset(url:input)
        guard let ex=AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetHighestQuality) else { throw ExportError.failed }
        ex.outputURL=output; ex.outputFileType=.mp4
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            ex.exportAsynchronously { ex.status == .completed ? c.resume() : c.resume(throwing:ex.error ?? ExportError.failed) }
        }
    }

    private func still(_ input:URL,to output:URL) async throws {
        guard let image=UIImage(contentsOfFile:input.path),let cg=image.cgImage else { throw ExportError.failed }
        let w=min(max(cg.width,2),4096), h=min(max(cg.height,2),4096)
        let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        let inputWriter=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:w,AVVideoHeightKey:h])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:inputWriter)
        writer.add(inputWriter); writer.startWriting(); writer.startSession(atSourceTime:.zero)
        var pixel:CVPixelBuffer?
        CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel)
        guard let pixel else { throw ExportError.failed }
        CVPixelBufferLockBaseAddress(pixel,[])
        if let base=CVPixelBufferGetBaseAddress(pixel) {
            let ctx=CGContext(data:base,width:w,height:h,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
        }
        CVPixelBufferUnlockBaseAddress(pixel,[])
        for frame in 0..<90 {
            while !inputWriter.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            adaptor.append(pixel,withPresentationTime:CMTime(value:CMTimeValue(frame),timescale:30))
        }
        inputWriter.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.failed }
    }

    private func base()->URL { let u=fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LumaForge",isDirectory:true); try? fm.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func importsDirectory()->URL { let u=base().appendingPathComponent("Imports",isDirectory:true); try? fm.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func exportsDirectory()->URL { let u=base().appendingPathComponent("Exports",isDirectory:true); try? fm.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func manifest()->URL { base().appendingPathComponent("exports.json") }
    private func load(){ guard let d=try? Data(contentsOf:manifest()),let r=try? JSONDecoder().decode([ExportRecord].self,from:d) else{return}; records=r }
    private func save(){ try? JSONEncoder().encode(records).write(to:manifest(),options:.atomic) }
}
