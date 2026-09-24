import Foundation
import Combine
import UIKit

/// Real Steam OpenID 2.0 authentication.
///
/// Steam rejects custom URL schemes as `openid.return_to` ("Invalid return protocol").
/// ASWebAuthenticationSession + custom-scheme callbacks are unreliable inside LiveContainer
/// and when intermediate HTML is served as text/plain.
///
/// Flow (WKWebView):
/// 1. Present Steam OpenID login with HTTPS `return_to`.
/// 2. After Steam Guard, Steam redirects to that HTTPS URL with OpenID query params.
/// 3. WKNavigationDelegate intercepts that navigation and reads the params (no custom scheme needed).
/// 4. App validates with Steam `check_authentication`, then loads profile.
@MainActor
final class SteamAuthenticationService: NSObject, ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: SteamUser?
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    @Published var showLoginWebView = false

    private let keychain = KeychainHelper()
    private let steamIDKey = "steam_id"
    private let sessionTimestampKey = "steam_session_ts"

    /// HTTPS return_to required by Steam. The page itself need not render;
    /// WKWebView intercepts the navigation URL and its query string.
    static let httpsReturnTo =
        "https://cdn.jsdelivr.net/gh/ITZproVenom/WallpaperEngineExporter@main/docs/steam-callback.html"
    static let httpsRealm = "https://cdn.jsdelivr.net"

    override init() {
        super.init()
        restoreSession()
    }

    /// Builds the Steam OpenID login URL (HTTPS return_to).
    func makeOpenIDLoginURL() -> URL? {
        var components = URLComponents(string: "https://steamcommunity.com/openid/login")!
        components.queryItems = [
            URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.return_to", value: Self.httpsReturnTo),
            URLQueryItem(name: "openid.realm", value: Self.httpsRealm),
            URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select")
        ]
        return components.url
    }

    func signIn() {
        lastError = nil
        guard makeOpenIDLoginURL() != nil else {
            lastError = "Steam Login Failed\n\nCould not construct the Steam OpenID login URL."
            return
        }
        isLoading = true
        showLoginWebView = true
    }

    func cancelLoginWebView() {
        showLoginWebView = false
        isLoading = false
    }

    /// Called when WKWebView navigates to the HTTPS return_to (or any URL with OpenID id_res params).
    func handleOpenIDCallbackURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              !items.isEmpty else {
            lastError = "Steam Login Failed\n\nCallback URL had no OpenID parameters.\n\(url.absoluteString)"
            isLoading = false
            showLoginWebView = false
            return
        }

        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        processOpenIDParams(params)
    }

    private func processOpenIDParams(_ params: [String: String]) {
        if params["openid.mode"] == "error" {
            let msg = params["openid.error"] ?? "Steam returned an OpenID error."
            lastError = "Steam Login Failed\n\n\(msg)"
            isLoading = false
            showLoginWebView = false
            return
        }

        guard params["openid.mode"] == "id_res" else {
            // Not the final assertion yet (e.g. intermediate page) — keep web view open
            return
        }

        guard let claimedID = params["openid.claimed_id"],
              let steamID = Self.steamID(fromClaimedID: claimedID) else {
            lastError = "Steam Login Failed\n\nCould not extract a valid SteamID64 from openid.claimed_id."
            isLoading = false
            showLoginWebView = false
            return
        }

        showLoginWebView = false

        Task {
            do {
                let valid = try await Self.verifyOpenIDResponse(params: params)
                guard valid else {
                    await MainActor.run {
                        self.lastError = "Steam Login Failed\n\nOpenID validation failed (Steam did not confirm is_valid:true)."
                        self.isLoading = false
                    }
                    return
                }

                self.keychain.set(steamID, forKey: self.steamIDKey)
                self.keychain.set(String(Date().timeIntervalSince1970), forKey: self.sessionTimestampKey)

                await self.fetchAndApplyProfile(steamID: steamID)
                await MainActor.run {
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Steam Login Failed\n\nOpenID validation request failed.\n\(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    /// True if this URL is our Steam OpenID return_to (with or without query).
    static func isOpenIDReturnURL(_ url: URL) -> Bool {
        let s = url.absoluteString
        if s.hasPrefix(httpsReturnTo) { return true }
        // Fallback: any URL that carries a finished OpenID assertion
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            let mode = items.first(where: { $0.name == "openid.mode" })?.value
            let claimed = items.first(where: { $0.name == "openid.claimed_id" })?.value
            if mode == "id_res", claimed != nil { return true }
        }
        return false
    }

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
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.lowercased() == "is_valid:true" }
    }

    nonisolated static func steamID(fromClaimedID claimedID: String) -> String? {
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
            // Profile is best-effort; identity is the validated SteamID
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
