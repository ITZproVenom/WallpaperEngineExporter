import SwiftUI

struct ExportsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Exports", systemImage: "film")
            } description: {
                Text("Completed exports will appear here. Use Share or Save to Photos after each export.")
            }
            .navigationTitle("Exports")
        }
    }
}
