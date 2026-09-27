import Foundation

/// Runs the whole local flow: inspect the package, choose a strategy, export.
///
/// Inspection and export happen off the main actor because both touch the file
/// system and can encode video.
@MainActor
final class ExportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case inspecting
        case exporting(String)
        case finished(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .inspecting, .exporting: return true
            case .idle, .finished, .failed: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastPlan: ExportPlan?
    @Published private(set) var lastOutcome: ExportOutcome?

    private let pipeline = ExportPipeline()

    func reset() {
        phase = .idle
        lastPlan = nil
        lastOutcome = nil
    }

    /// Inspect without exporting, so the UI can show the strategy first.
    func inspect(packageURL: URL, tags: [String] = []) async -> ExportPlan {
        phase = .inspecting
        let plan = await Task.detached(priority: .userInitiated) {
            PackageInspector.inspect(at: packageURL, tags: tags)
        }.value
        lastPlan = plan
        phase = plan.isExportable ? .idle : .failed(plan.reason)
        return plan
    }

    /// Inspect and export in one step, adopting the result into the library.
    func export(packageURL: URL, into store: ExportStore, title: String,
                workshopID: String, tags: [String] = []) async {
        let plan = await inspect(packageURL: packageURL, tags: tags)
        guard plan.isExportable else { return }

        phase = .exporting(plan.fidelity == .identical
                           ? "Extracting the original video…"
                           : "Encoding…")

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumaforge-\(UUID().uuidString)", isDirectory: true)
        let destination = scratch.appendingPathComponent("export.mp4")

        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let pipeline = self.pipeline
            let outcome = try await Task.detached(priority: .userInitiated) {
                try pipeline.export(plan: plan, to: destination, scratch: scratch)
            }.value

            lastOutcome = outcome
            if let record = store.adopt(outcome: outcome, title: title, workshopID: workshopID) {
                phase = .finished(record.name)
            } else {
                phase = .failed("The export could not be saved.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: scratch)
    }
}
