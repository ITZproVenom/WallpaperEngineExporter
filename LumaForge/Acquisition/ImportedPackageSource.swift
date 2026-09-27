import Foundation

/// Packages the user supplied themselves, from Files, AirDrop, or a share sheet.
///
/// This is the only source that needs no Steam access, no credentials, no
/// server, and no Wallpaper Engine licence, so it has the highest priority.
struct ImportedPackageSource: AcquisitionSource {
    let name = "Imported package"
    let priority = 10
    let inbox: URL

    init(inbox: URL = ImportedPackageSource.defaultInbox) {
        self.inbox = inbox
    }

    static var defaultInbox: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("LumaForge/Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func capability() -> AcquisitionCapability {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path).count) ?? 0
        return AcquisitionCapability(
            name: name, available: true,
            detail: items == 0
                ? "Import a .pkg or wallpaper folder to export it"
                : "\(items) imported package\(items == 1 ? "" : "s") ready",
            requiresUserAction: true
        )
    }

    /// Copy a user-picked file or folder into the app's own storage, so it stays
    /// readable after the security-scoped URL is released.
    @discardableResult
    func store(pickedURL: URL, named preferredName: String? = nil) throws -> URL {
        let needsScope = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)

        let name = preferredName ?? pickedURL.lastPathComponent
        var destination = inbox.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            let stem = destination.deletingPathExtension().lastPathComponent
            let extensionPart = destination.pathExtension
            let unique = "\(stem)-\(UUID().uuidString.prefix(6))"
            destination = inbox.appendingPathComponent(unique)
                .appendingPathExtension(extensionPart)
        }
        try fileManager.copyItem(at: pickedURL, to: destination)
        return destination
    }

    func storedPackages() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return left > right
        }
    }

    func acquire(workshopID: String, into directory: URL) async throws -> AcquiredContent {
        let matches = storedPackages().filter {
            $0.deletingPathExtension().lastPathComponent == workshopID
                || $0.lastPathComponent.contains(workshopID)
        }
        guard let match = matches.first else {
            throw AcquisitionError.notFound(
                "No imported package for \(workshopID). Import its .pkg to export it."
            )
        }
        return AcquiredContent(workshopID: workshopID, root: match, sourceName: name,
                               notes: ["Imported from \(match.lastPathComponent)"])
    }
}
