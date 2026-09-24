import SwiftUI

struct MyWallpapersView: View {
    @EnvironmentObject var auth: SteamAuthenticationService
    @EnvironmentObject var workshop: SteamWorkshopService
    @State private var pasteURL = ""
    @State private var showPasteSheet = false
    @State private var selectedItem: WorkshopItem?
    @State private var isResolving = false
    @State private var pasteError: String?

    var body: some View {
        NavigationStack {
            Group {
                if workshop.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                            ForEach(workshop.items) { item in
                                WallpaperCard(item: item)
                                    .onTapGesture { selectedItem = item }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            workshop.removeItem(id: item.id)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("My Wallpapers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showPasteSheet = true
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if let user = auth.currentUser {
                        HStack(spacing: 8) {
                            AsyncImage(url: user.avatarURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(.gray.opacity(0.3))
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                            Text(user.displayName ?? String(user.steamID.suffix(6)))
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .sheet(isPresented: $showPasteSheet) {
                pasteSheet
            }
            .navigationDestination(item: $selectedItem) { item in
                WallpaperDetailView(item: item)
            }
            .refreshable {
                if let id = auth.currentUser?.steamID {
                    await workshop.refreshLibrary(for: id)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Wallpapers Yet", systemImage: "photo.on.rectangle")
        } description: {
            Text("Import Wallpaper Engine projects via the Import tab, or paste a Workshop URL to load public metadata.")
        } actions: {
            Button("Paste Workshop URL") { showPasteSheet = true }
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section("Workshop URL or ID") {
                    TextField("https://steamcommunity.com/sharedfiles/filedetails/?id=…", text: $pasteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                if let pasteError {
                    Section {
                        Text(pasteError).foregroundStyle(.red).font(.footnote)
                    }
                }
                Section {
                    Button {
                        Task { await resolvePaste() }
                    } label: {
                        if isResolving {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(WorkshopURLParser.extractID(from: pasteURL) == nil || isResolving)
                }
            }
            .navigationTitle("Paste Workshop URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPasteSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func resolvePaste() async {
        isResolving = true
        pasteError = nil
        if let item = await workshop.item(fromWorkshopURL: pasteURL) {
            workshop.addImported(item)
            pasteURL = ""
            showPasteSheet = false
        } else {
            pasteError = "Could not resolve this Workshop item. Check the URL/ID or that the item is public."
        }
        isResolving = false
    }
}

struct WallpaperCard: View {
    let item: WorkshopItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let preview = item.previewURL {
                    AsyncImage(url: preview) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            HStack {
                Text(item.type.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.type.isExportable || item.availability == .readyToExport ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .clipShape(Capsule())
                Spacer()
                Text(item.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
    }
}
