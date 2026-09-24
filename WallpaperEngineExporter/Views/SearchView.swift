import SwiftUI

struct SearchView: View {
    @EnvironmentObject var workshop: SteamWorkshopService
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if workshop.searchResults.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(workshop.searchResults) { item in
                        NavigationLink(value: item) {
                            WallpaperCard(item: item)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search Workshop")
            .onSubmit(of: .search) {
                Task { await workshop.search(query: query) }
            }
            .navigationDestination(for: WorkshopItem.self) { item in
                WallpaperDetailView(item: item)
            }
            .overlay {
                if workshop.isLoading {
                    ProgressView("Searching…")
                }
            }
        }
    }
}
