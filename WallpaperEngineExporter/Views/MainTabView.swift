import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var auth: SteamAuthenticationService

    var body: some View {
        TabView {
            MyWallpapersView()
                .tabItem {
                    Label("My Wallpapers", systemImage: "square.grid.2x2")
                }

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            ImportView()
                .tabItem {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

            ExportsView()
                .tabItem {
                    Label("Exports", systemImage: "film")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
