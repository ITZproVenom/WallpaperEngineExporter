import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: SteamAuthenticationService

    var body: some View {
        NavigationStack {
            Form {
                if let user = auth.currentUser {
                    Section("Steam Account") {
                        HStack {
                            AsyncImage(url: user.avatarURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(.gray.opacity(0.3))
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())

                            VStack(alignment: .leading) {
                                Text(user.displayName ?? "Steam User")
                                    .font(.headline)
                                Text(user.steamID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button("Sign Out", role: .destructive) {
                            auth.signOut()
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.1.0")
                    LabeledContent("Build", value: "GitHub Actions")
                }

                Section("Limitations") {
                    Text("Only video wallpapers can be fully exported on iOS. Scene, Web and Application wallpapers are detected but not rendered.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
