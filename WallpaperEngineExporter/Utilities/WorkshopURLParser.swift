import Foundation

enum WorkshopURLParser {
    /// Extracts a Workshop file ID from common Steam Community sharedfiles URLs.
    static func extractID(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct numeric ID
        if trimmed.range(of: "^[0-9]{5,}$", options: .regularExpression) != nil {
            return trimmed
        }

        // URL forms
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Query parameter id=
        if let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
           id.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return id
        }

        // Path style /filedetails/123456789 or /sharedfiles/filedetails/?id=
        let path = components.path
        let parts = path.split(separator: "/")
        if let last = parts.last, last.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return String(last)
        }

        return nil
    }
}
