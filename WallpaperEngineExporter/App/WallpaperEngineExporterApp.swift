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
                .preferredColorScheme(nil)
                .onOpenURL { url in
                    // Custom scheme callback (wallpaperexporter://steam-callback?…)
                    if SteamAuthenticationService.isOpenIDReturnURL(url)
                        || SteamAuthenticationService.isFinishedOpenIDAssertion(url) {
                        authService.handleOpenIDCallbackURL(url)
                    }
                }
        }
    }
}
