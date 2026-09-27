import Foundation

/// A Workshop item as listed from Steam. Export metadata lives in
/// `WorkshopMetadata`; finished exports live in `ExportRecord`.
struct WorkshopItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let previewURL: URL?
    let pageURL: URL
}

/// Parsing of Steam Workshop links and IDs.
enum WorkshopLink {
    static func isValidID(_ id: String) -> Bool {
        id.count >= 6 && id.count <= 20 && id.allSatisfy(\.isNumber)
    }

    static func id(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?
                .first(where: { $0.name.lowercased() == "id" })?.value,
              isValidID(id) else { return nil }
        return id
    }

    static func id(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let found = id(from: url) { return found }
        return isValidID(trimmed) ? trimmed : nil
    }
}
