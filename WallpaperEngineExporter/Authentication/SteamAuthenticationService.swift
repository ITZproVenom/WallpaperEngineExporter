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
    private let steamIDKey = "steam_id"
    private let sessionTimestampKey = "steam_session_ts"
    private let returnURLScheme = "wallpaperexporter"
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        restoreSession()
    }

    func signIn() {
        isLoading = true
        lastError = nil

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
            lastError = "Steam Login Failed\n\nCould not construct the Steam login URL."
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
        authSession = session
        if !session.start() {
            lastError = "Steam Login Failed\n\nCould not start the authentication session."
            isLoading = false
        }
    }

    private func handleCallback(callbackURL: URL?, error: Error?) {
        defer {
            isLoading = false
            authSession = nil
        }

        if let error = error as? ASWebAuthenticationSessionError,
           error.code == .canceledLogin {
            lastError = nil
            return
        }

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

        // Mode should be id_res for success
        if let mode = items.first(where: { $0.name == "openid.mode" })?.value, mode == "error" {
            lastError = "Steam Login Failed\n\nSteam returned an error response."
            return
        }

        guard let claimedID = items.first(where: { $0.name == "openid.claimed_id" })?.value,
              let steamID = claimedID.split(separator: "/").last.map(String.init),
              steamID.count >= 15 else {
            lastError = "Steam Login Failed\n\nCould not extract SteamID from the response."
            return
        }

        keychain.set(steamID, forKey: steamIDKey)
        keychain.set(String(Date().timeIntervalSince1970), forKey: sessionTimestampKey)

        Task {
            await fetchAndApplyProfile(steamID: steamID)
        }
    }

    private func fetchAndApplyProfile(steamID: String) async {
        // Public profile XML — no API key required
        let xmlURL = URL(string: "https://steamcommunity.com/profiles/\(steamID)/?xml=1")!
        var user = SteamUser(
            steamID: steamID,
            displayName: nil,
            avatarURL: nil,
            profileURL: URL(string: "https://steamcommunity.com/profiles/\(steamID)")
        )

        do {
            let (data, response) = try await URLSession.shared.data(from: xmlURL)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let xml = String(data: data, encoding: .utf8) {
                let name = Self.extractXMLTag("steamID", from: xml)
                    ?? Self.extractXMLTag("steamID64", from: xml)
                let avatar = Self.extractXMLTag("avatarFull", from: xml)
                    ?? Self.extractXMLTag("avatarMedium", from: xml)
                user = SteamUser(
                    steamID: steamID,
                    displayName: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                    avatarURL: avatar.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                    profileURL: URL(string: "https://steamcommunity.com/profiles/\(steamID)")
                )
            }
        } catch {
            // Profile fetch is best-effort; auth still succeeds with SteamID
        }

        self.currentUser = user
        self.isAuthenticated = true
        self.lastError = nil
    }

    func signOut() {
        keychain.delete(steamIDKey)
        keychain.delete(sessionTimestampKey)
        currentUser = nil
        isAuthenticated = false
        lastError = nil
    }

    private func restoreSession() {
        guard let steamID = keychain.get(steamIDKey) else { return }
        // Optional: expire after 30 days of no use
        if let tsStr = keychain.get(sessionTimestampKey),
           let ts = Double(tsStr),
           Date().timeIntervalSince1970 - ts > 30 * 24 * 3600 {
            signOut()
            return
        }
        Task {
            await fetchAndApplyProfile(steamID: steamID)
        }
    }

    private static func extractXMLTag(_ tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)><!\\[CDATA\\[(.*?)\\]\\]></\(tag)>|<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range) else { return nil }
        for i in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: xml), !r.isEmpty {
                return String(xml[r])
            }
        }
        return nil
    }
}

extension SteamAuthenticationService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return key
        }
        return scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}
