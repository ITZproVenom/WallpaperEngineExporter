import Foundation
import AuthenticationServices
import Combine

@MainActor
final class SteamAuthenticationService: NSObject, ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: SteamUser?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let keychain = KeychainHelper()
    private let sessionKey = "steam_session"
    private let steamIDKey = "steam_id"

    // Steam OpenID realm / return URL scheme must match Info.plist URL Types
    private let realm = "https://steamcommunity.com/openid"
    private let returnURLScheme = "wallpaperexporter"

    override init() {
        super.init()
        restoreSession()
    }

    func signIn() {
        isLoading = true
        lastError = nil

        // Steam OpenID 2.0 endpoint
        var components = URLComponents(string: "https://steamcommunity.com/openid/login")!
        components.queryItems = [
            URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.return_to", value: "\(returnURLScheme)://steam-callback"),
            URLQueryItem(name: "openid.realm", value: "\(returnURLScheme)://steam-callback"),
            URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select")
        ]

        guard let url = components.url else {
            lastError = "Failed to construct Steam login URL"
            isLoading = false
            return
        }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: returnURLScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.handleCallback(callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }

    private func handleCallback(callbackURL: URL?, error: Error?) {
        defer { isLoading = false }

        if let error = error {
            lastError = "Steam Login Failed\n\nSteam authentication could not be completed.\n\(error.localizedDescription)"
            return
        }

        guard let callbackURL = callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            lastError = "Steam Login Failed\n\nInvalid callback from Steam."
            return
        }

        // Extract claimed_id which contains the SteamID64
        guard let claimedID = items.first(where: { $0.name == "openid.claimed_id" })?.value,
              let steamID = claimedID.split(separator: "/").last.map(String.init) else {
            lastError = "Steam Login Failed\n\nCould not extract SteamID from response."
            return
        }

        // Persist minimal session info
        keychain.set(steamID, forKey: steamIDKey)
        keychain.set(Date().timeIntervalSince1970.description, forKey: sessionKey)

        // Fetch basic profile (public endpoint)
        Task {
            await fetchProfile(steamID: steamID)
        }
    }

    private func fetchProfile(steamID: String) async {
        // Public Steam Community profile XML / JSON is limited; we use a lightweight approach.
        // For production you would use a Steam Web API key + GetPlayerSummaries.
        // Here we create a minimal user object and attempt a public avatar lookup.
        let user = SteamUser(
            steamID: steamID,
            displayName: "Steam User \(steamID.suffix(4))",
            avatarURL: URL(string: "https://avatars.steamstatic.com/fef49e7fa7e1997310d705b2a6158ff8dc1cdfeb_full.jpg"),
            profileURL: URL(string: "https://steamcommunity.com/profiles/\(steamID)")
        )
        self.currentUser = user
        self.isAuthenticated = true
    }

    func signOut() {
        keychain.delete(steamIDKey)
        keychain.delete(sessionKey)
        currentUser = nil
        isAuthenticated = false
    }

    private func restoreSession() {
        if let steamID = keychain.get(steamIDKey) {
            Task {
                await fetchProfile(steamID: steamID)
            }
        }
    }
}

extension SteamAuthenticationService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // On iOS this is typically the key window
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
