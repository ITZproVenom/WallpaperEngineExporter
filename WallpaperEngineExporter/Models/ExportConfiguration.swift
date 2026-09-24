import Foundation
import CoreGraphics

enum ExportResolution: String, CaseIterable, Identifiable {
    case original
    case p1080
    case p1440
    case p2160
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .p1080: return "1920 × 1080"
        case .p1440: return "2560 × 1440"
        case .p2160: return "3840 × 2160"
        case .custom: return "Custom"
        }
    }

    func size(for original: CGSize) -> CGSize {
        switch self {
        case .original: return original
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p1440: return CGSize(width: 2560, height: 1440)
        case .p2160: return CGSize(width: 3840, height: 2160)
        case .custom: return original // overridden by custom values
        }
    }
}

enum ExportFPS: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
}

enum ExportDuration: Equatable {
    case seconds(Int)
    case custom(TimeInterval)

    var seconds: TimeInterval {
        switch self {
        case .seconds(let s): return TimeInterval(s)
        case .custom(let t): return t
        }
    }
}

enum ExportCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case low, medium, high, maximum

    var id: String { rawValue }

    var bitrateMultiplier: Double {
        switch self {
        case .low: return 0.4
        case .medium: return 0.7
        case .high: return 1.0
        case .maximum: return 1.4
        }
    }
}

struct ExportConfiguration: Equatable {
    var resolution: ExportResolution = .original
    var customWidth: Int = 1920
    var customHeight: Int = 1080
    var fps: ExportFPS = .fps30
    var duration: ExportDuration = .seconds(10)
    var codec: ExportCodec = .h264
    var quality: ExportQuality = .high
    var loop: Bool = true
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval? = nil
}
