import Foundation
import AuthenticationServices
import Combine
import UIKit

/// Real Steam OpenID 2.0 authentication via ASWebAuthenticationSession.
///
/// Steam rejects custom URL schemes as `openid.return_to` ("Invalid return protocol").
/// Flow:
/// 1. Open Steam OpenID with HTTPS return_to (jsDelivr-hosted bridge page in this repo).
/// 2. Bridge page redirects to `wallpaperexporter://steam-callback?...`.
/// 3. ASWebAuthenticationSession delivers the callback to the app.
/// 4. App validates OpenID with Steam (`check_authentication`).
/// 5. SteamID is extracted, profile is fetched, session is stored in Keychain.
@MainActor
final class SteamAuthenticationService: NSObject, ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: SteamUser?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let keychain = KeychainHelper()
    private let steamIDKey = "steam_id"
    private let sessionTimestampKey = "steam_session_ts"
    private let callbackScheme = "wallpaperexporter"
    private let callbackHost = "steam-callback"

    /// HTTPS bridge hosted from this repository (jsDelivr CDN). Steam requires http(s) return_to.
    private let httpsReturnTo =
        "https://cdn.jsdelivr.net/gh/ITZproVenom/WallpaperEngineExporter@main/docs/steam-callback.html"
    private let httpsRealm = "https://cdn.jsdelivr.net"

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
            URLQueryItem(name: "openid.return_to", value: httpsReturnTo),
            URLQueryItem(name: "openid.realm", value: httpsRealm),
            URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select")
        ]

        guard let url = components.url else {
            lastError = "Steam Login Failed\n\nCould not construct the Steam OpenID login URL."
            isLoading = false
            return
        }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.handleCallback(callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        // Keep cookies so Steam Guard / remembered login works across attempts
        session.prefersEphemeralWebBrowserSession = false
        authSession = session

        if !session.start() {
            lastError = "Steam Login Failed\n\nCould not start ASWebAuthenticationSession."
            isLoading = false
        }
    }

    private func handleCallback(callbackURL: URL?, error: Error?) {
        if let error = error as? ASWebAuthenticationSessionError,
           error.code == .canceledLogin {
            lastError = nil
            isLoading = false
            authSession = nil
            return
        }

        if let error = error {
            lastError = "Steam Login Failed\n\nAuthentication session error.\n\(error.localizedDescription)"
            isLoading = false
            authSession = nil
            return
        }

        guard let callbackURL = callbackURL else {
            lastError = "Steam Login Failed\n\nNo callback URL received from the authentication session."
            isLoading = false
            authSession = nil
            return
        }

        guard callbackURL.scheme?.lowercased() == callbackScheme else {
            lastError = "Steam Login Failed\n\nUnexpected callback scheme: \(callbackURL.scheme ?? "nil"). Expected \(callbackScheme)."
            isLoading = false
            authSession = nil
            return
        }

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              !items.isEmpty else {
            lastError = "Steam Login Failed\n\nCallback URL had no OpenID parameters.\n\(callbackURL.absoluteString)"
            isLoading = false
            authSession = nil
            return
        }

        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        if params["openid.mode"] == "error" {
            let msg = params["openid.error"] ?? "Steam returned an OpenID error."
            lastError = "Steam Login Failed\n\n\(msg)"
            isLoading = false
            authSession = nil
            return
        }

        guard params["openid.mode"] == "id_res" else {
            lastError = "Steam Login Failed\n\nUnexpected OpenID mode: \(params["openid.mode"] ?? "missing")."
            isLoading = false
            authSession = nil
            return
        }

        guard let claimedID = params["openid.claimed_id"],
              let steamID = Self.steamID(fromClaimedID: claimedID) else {
            lastError = "Steam Login Failed\n\nCould not extract a valid SteamID64 from openid.claimed_id."
            isLoading = false
            authSession = nil
            return
        }

        // Validate assertion with Steam (required for real auth)
        Task {
            do {
                let valid = try await Self.verifyOpenIDResponse(params: params)
                guard valid else {
                    await MainActor.run {
                        self.lastError = "Steam Login Failed\n\nOpenID validation failed (Steam did not confirm is_valid:true)."
                        self.isLoading = false
                        self.authSession = nil
                    }
                    return
                }

                self.keychain.set(steamID, forKey: self.steamIDKey)
                self.keychain.set(String(Date().timeIntervalSince1970), forKey: self.sessionTimestampKey)

                await self.fetchAndApplyProfile(steamID: steamID)
                await MainActor.run {
                    self.isLoading = false
                    self.authSession = nil
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Steam Login Failed\n\nOpenID validation request failed.\n\(error.localizedDescription)"
                    self.isLoading = false
                    self.authSession = nil
                }
            }
        }
    }

    /// POST openid.mode=check_authentication to Steam.
    nonisolated private static func verifyOpenIDResponse(params: [String: String]) async throws -> Bool {
        var bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "openid.mode", value: "check_authentication")
        ]
        for (key, value) in params where key.hasPrefix("openid.") && key != "openid.mode" {
            bodyItems.append(URLQueryItem(name: key, value: value))
        }

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = bodyItems
        guard let body = bodyComponents.percentEncodedQuery?.data(using: .utf8) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: URL(string: "https://steamcommunity.com/openid/login")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        // Steam responds with key:value lines; success is "is_valid:true"
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.lowercased() == "is_valid:true" }
    }

    nonisolated static func steamID(fromClaimedID claimedID: String) -> String? {
        // https://steamcommunity.com/openid/id/7656119...
        guard let last = claimedID.split(separator: "/").last.map(String.init),
              last.count >= 15,
              last.allSatisfy(\Character.isNumber) else {
            return nil
        }
        return last
    }

    private func fetchAndApplyProfile(steamID: String) async {
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
                let avatar = Self.extractXMLTag("avatarFull", from: xml)
                    ?? Self.extractXMLTag("avatarMedium", from: xml)
                let customURL = Self.extractXMLTag("customURL", from: xml)
                var profileURL = URL(string: "https://steamcommunity.com/profiles/\(steamID)")
                if let custom = customURL, !custom.isEmpty {
                    profileURL = URL(string: "https://steamcommunity.com/id/\(custom)")
                }
                user = SteamUser(
                    steamID: steamID,
                    displayName: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                    avatarURL: avatar.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                    profileURL: profileURL
                )
            }
        } catch {
            // Profile is best-effort; authenticated identity is the validated SteamID
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
