import Foundation
import Combine
import UIKit
import AuthenticationServices

/// Real Steam OpenID 2.0 authentication with dual paths:
/// 1. ASWebAuthenticationSession (preferred on normal iOS installs)
/// 2. WKWebView navigation intercept (fallback for LiveContainer / when custom-scheme callbacks fail)
///
/// Steam rejects custom URL schemes as `openid.return_to` ("Invalid return protocol"),
/// so `return_to` is always an HTTPS URL. WKWebView intercepts that URL before any page loads.
/// ASWebAuthenticationSession still registers the custom scheme so that if an intermediate
/// redirect ever delivers `wallpaperexporter://…`, it is handled; on failure we fall back to WKWebView.
@MainActor
final class SteamAuthenticationService: NSObject, ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: SteamUser?
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    /// Presents the WKWebView login sheet (LiveContainer / fallback path).
    @Published var showLoginWebView = false

    private let keychain = KeychainHelper()
    private let steamIDKey = "steam_id"
    private let sessionTimestampKey = "steam_session_ts"

    private var authSession: ASWebAuthenticationSession?

    // MARK: - Deterministic OpenID endpoints (no jsDelivr)

    /// Custom scheme registered in Info.plist (used by ASWebAuthenticationSession callback matcher).
    static let callbackScheme = "wallpaperexporter"
    static let callbackHost = "steam-callback"

    /// HTTPS return_to required by Steam. Must share origin prefix with realm.
    /// WKWebView intercepts navigation to this URL (with OpenID query) and never loads the page.
    /// Page content is irrelevant for the WKWebView path.
    static let httpsReturnTo =
        "https://raw.githubusercontent.com/ITZproVenom/WallpaperEngineExporter/main/docs/openid-return.html"
    static let httpsRealm = "https://raw.githubusercontent.com"

    /// Legacy hosts we still treat as return_to if Steam or an older build redirects there.
    private static let legacyReturnToPrefixes: [String] = [
        "https://raw.githubusercontent.com/ITZproVenom/WallpaperEngineExporter",
        "https://raw.githack.com/ITZproVenom/WallpaperEngineExporter",
        "https://cdn.jsdelivr.net/gh/ITZproVenom/WallpaperEngineExporter",
        "https://cdn.jsdelivr.net/gh/itzprovenom/WallpaperEngineExporter"
    ]

    // MARK: - Environment detection

    /// True when custom-scheme delivery is known to be unreliable (LiveContainer, etc.).
    static var prefersWebViewAuth: Bool {
        if UserDefaults.standard.bool(forKey: "force_steam_webview_auth") { return true }
        let path = Bundle.main.bundlePath.lowercased()
        if path.contains("livecontainer") { return true }
        if ProcessInfo.processInfo.environment["LIVECONTAINER"] != nil { return true }
        return false
    }

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Public API

    /// Builds the Steam OpenID login URL with deterministic HTTPS return_to / realm.
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

        if Self.prefersWebViewAuth {
            showLoginWebView = true
            return
        }

        startASWebAuthenticationSession(fallbackToWebViewOnFailure: true)
    }

    /// Explicit WKWebView path (also used after ASWeb failure).
    func signInWithWebView() {
        lastError = nil
        isLoading = true
        showLoginWebView = true
    }

    func cancelLoginWebView() {
        showLoginWebView = false
        if authSession == nil {
            isLoading = false
        }
    }

    func cancelASWebSession() {
        authSession?.cancel()
        authSession = nil
    }

    // MARK: - ASWebAuthenticationSession path

    private func startASWebAuthenticationSession(fallbackToWebViewOnFailure: Bool) {
        guard let url = makeOpenIDLoginURL() else {
            lastError = "Steam Login Failed\n\nCould not construct the Steam OpenID login URL."
            isLoading = false
            return
        }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.authSession = nil

                if let error {
                    let ns = error as NSError
                    if ns.domain == ASWebAuthenticationSessionError.errorDomain,
                       ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self.isLoading = false
                        self.lastError = nil
                        return
                    }
                    if fallbackToWebViewOnFailure {
                        self.lastError = nil
                        self.showLoginWebView = true
                        return
                    }
                    self.isLoading = false
                    self.lastError = "Steam Login Failed\n\nASWebAuthenticationSession error.\n\(error.localizedDescription)"
                    return
                }

                guard let callbackURL else {
                    if fallbackToWebViewOnFailure {
                        self.showLoginWebView = true
                        return
                    }
                    self.isLoading = false
                    self.lastError = "Steam Login Failed\n\nNo callback URL received from ASWebAuthenticationSession."
                    return
                }

                self.handleOpenIDCallbackURL(callbackURL)
            }
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session

        if !session.start() {
            authSession = nil
            if fallbackToWebViewOnFailure {
                showLoginWebView = true
            } else {
                isLoading = false
                lastError = "Steam Login Failed\n\nCould not start ASWebAuthenticationSession."
            }
        }
    }

    // MARK: - Callback handling (shared by both paths)

    /// Process a callback URL from ASWebAuthenticationSession or WKWebView intercept.
    func handleOpenIDCallbackURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              !items.isEmpty else {
            lastError = "Steam Login Failed\n\nCallback URL had no OpenID parameters.\n\(url.absoluteString.prefix(200))"
            isLoading = false
            showLoginWebView = false
            return
        }

        var params: [String: String] = [:]
        for item in items {
            if let value = item.value {
                params[item.name] = value
            }
        }

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
            return
        }

        let required = [
            "openid.mode",
            "openid.op_endpoint",
            "openid.claimed_id",
            "openid.identity",
            "openid.return_to",
            "openid.response_nonce",
            "openid.assoc_handle",
            "openid.signed",
            "openid.sig"
        ]
        var missing: [String] = []
        for key in required {
            if params[key]?.isEmpty ?? true {
                missing.append(key)
            }
        }
        if !missing.isEmpty {
            lastError = "Steam Login Failed\n\nIncomplete OpenID response. Missing:\n\(missing.joined(separator: ", "))"
            isLoading = false
            showLoginWebView = false
            return
        }

        if let returnedTo = params["openid.return_to"],
           !returnedTo.hasPrefix(Self.httpsReturnTo),
           !Self.legacyReturnToPrefixes.contains(where: { returnedTo.hasPrefix($0) }) {
            lastError = "Steam Login Failed\n\nopenid.return_to mismatch.\nGot: \(returnedTo.prefix(120))"
            isLoading = false
            showLoginWebView = false
            return
        }

        guard let claimedID = params["openid.claimed_id"],
              let steamID = Self.steamID(fromClaimedID: claimedID) else {
            lastError = "Steam Login Failed\n\nCould not extract a valid SteamID64 from openid.claimed_id."
            isLoading = false
            showLoginWebView = false
            return
        }

        if let identity = params["openid.identity"], identity != claimedID {
            lastError = "Steam Login Failed\n\nopenid.identity does not match openid.claimed_id."
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
                        self.lastError = "Steam Login Failed\n\nOpenID validation failed (Steam did not confirm is_valid:true).\nThe response signature could not be verified."
                        self.isLoading = false
                    }
                    return
                }

                self.keychain.set(steamID, forKey: self.steamIDKey)
                self.keychain.set(String(Date().timeIntervalSince1970), forKey: self.sessionTimestampKey)

                await self.fetchAndApplyProfile(steamID: steamID)
                await MainActor.run {
                    self.isLoading = false
                    self.lastError = nil
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Steam Login Failed\n\nOpenID validation request failed.\n\(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - URL classification

    static func isOpenIDReturnURL(_ url: URL) -> Bool {
        let s = url.absoluteString
        if s.hasPrefix(httpsReturnTo) { return true }
        for prefix in legacyReturnToPrefixes {
            if s.hasPrefix(prefix) { return true }
        }
        if url.scheme?.lowercased() == callbackScheme { return true }
        return false
    }

    static func isFinishedOpenIDAssertion(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return false
        }
        let mode = items.first(where: { $0.name == "openid.mode" })?.value
        let claimed = items.first(where: { $0.name == "openid.claimed_id" })?.value
        return mode == "id_res" && claimed != nil && !(claimed?.isEmpty ?? true)
    }

    // MARK: - Steam check_authentication

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
        request.timeoutInterval = 20

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

    // MARK: - Profile + session

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
        cancelASWebSession()
        keychain.delete(steamIDKey)
        keychain.delete(sessionTimestampKey)
        currentUser = nil
        isAuthenticated = false
        lastError = nil
        isLoading = false
        showLoginWebView = false
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

// MARK: - ASWebAuthenticationSession presentation

extension SteamAuthenticationService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        return ASPresentationAnchor()
    }
}
