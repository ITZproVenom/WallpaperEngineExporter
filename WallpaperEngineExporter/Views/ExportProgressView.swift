import SwiftUI

struct ExportProgress: Equatable {
    enum Stage: String {
        case rendering = "Rendering wallpaper…"
        case encoding = "Encoding video…"
        case finishing = "Finishing…"
    }
    var stage: Stage
    var fraction: Double
    var currentFrame: Int?
    var fps: Double?
    var estimatedRemaining: TimeInterval?
    var outputSize: Int64?
}

struct ExportProgressView: View {
    let progress: ExportProgress

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 240)

            Text(progress.stage.rawValue)
                .font(.headline)

            Text("\(Int(progress.fraction * 100))%")
                .font(.title.monospacedDigit())

            if let frame = progress.currentFrame {
                Text("Frame \(frame)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fps = progress.fps {
                Text(String(format: "%.1f fps", fps))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let remaining = progress.estimatedRemaining {
                Text("~\(Int(remaining))s remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 20)
    }
}
