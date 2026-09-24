import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: SteamAuthenticationService

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Wallpaper Engine Exporter")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("Access your Wallpaper Engine wallpapers and export them as video.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let error = auth.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
            }

            Button {
                auth.signIn()
            } label: {
                HStack {
                    if auth.isLoading && !auth.showLoginWebView {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Sign in with Steam")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(auth.isLoading)
            .padding(.horizontal, 40)

            Spacer()

            Text("No Steam password is ever entered or stored in this app.\nAuthentication uses the official Steam web flow.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .padding()
        .sheet(isPresented: $auth.showLoginWebView) {
            SteamLoginWebView()
                .environmentObject(auth)
                .presentationDetents([.large])
                .interactiveDismissDisabled(false)
        }
    }
}
