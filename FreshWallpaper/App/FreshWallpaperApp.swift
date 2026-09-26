import SwiftUI

@main
struct FreshWallpaperApp: App {
    @StateObject private var store = WallpaperStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store) }
    }
}
