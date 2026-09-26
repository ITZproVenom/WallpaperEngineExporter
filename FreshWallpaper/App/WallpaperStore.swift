import Foundation
import SwiftUI

@MainActor
final class WallpaperStore: ObservableObject {
    @Published var wallpapers: [Wallpaper] = []
    @Published var query = ""
    @Published var isLoading = false
    @Published var error: String?
    private let service = SteamService()

    func search() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { wallpapers = try await service.search(query: query.isEmpty ? "wallpaper" : query) }
        catch { error = error.localizedDescription }
    }
}
