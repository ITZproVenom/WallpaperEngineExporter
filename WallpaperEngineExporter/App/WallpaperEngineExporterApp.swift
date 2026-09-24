import SwiftUI

@main
struct WallpaperEngineExporterApp: App {
    @StateObject private var authService = SteamAuthenticationService()
    @StateObject private var workshopService = SteamWorkshopService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(workshopService)
                .preferredColorScheme(nil) // support system light/dark
        }
    }
}
