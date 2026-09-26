import Foundation
import AuthenticationServices
import Security
import UIKit

struct SteamOpenID {
    static let endpoint = "https://steamcommunity.com/openid/login"

    static func steamID(from callback: URL, expectedState: String) -> String? {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        guard values["state"] == expectedState,
              values["openid.mode"] == "id_res",
              values["openid.op_endpoint"] == endpoint else { return nil }

        let id = values["openid.claimed_id"]?.split(separator: "/").last.map(String.init) ?? ""
        guard id.count == 17, id.allSatisfy(\.isNumber), id.hasPrefix("7656119") else { return nil }
        return id
    }
}

final class SteamKeychain {
    private let service = "com.itzprovenom.lumaforge"

    func save(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "steamID",
            kSecValueData as String: Data(id.utf8)
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "steamID",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "steamID"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class SteamSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var steamID: String?
    @Published private(set) var signingIn = false

    private let keychain = SteamKeychain()
    private var auth: ASWebAuthenticationSession?
    private var state = ""

    override init() {
        steamID = keychain.load()
        super.init()
    }

    func signIn() {
        guard !signingIn else { return }
        signingIn = true
        state = UUID().uuidString

        var components = URLComponents(string: SteamOpenID.endpoint)!
        components.queryItems = [
            .init(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            .init(name: "openid.mode", value: "checkid_setup"),
            .init(name: "openid.return_to", value: "https://fswswvhpszebuxnloysy.supabase.co/functions/v1/lumaforge-steam-callback?state=\(state)"),
            .init(name: "openid.realm", value: "https://fswswvhpszebuxnloysy.supabase.co/"),
            .init(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            .init(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select")
        ]

        guard let url = components.url else {
            signingIn = false
            return
        }

        let session = ASWebAuthenticationSession(url: url, callback: .https(host: "lumaforge.local", path: "/steam-callback")) { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.signingIn = false }
                guard error == nil,
                      let callback,
                      let id = SteamOpenID.steamID(from: callback, expectedState: self.state) else { return }

                if (try? await self.verify(callback)) == true {
                    self.steamID = id
                    self.keychain.save(id)
                }
            }
        }

        session.presentationContextProvider = self
        auth = session
        session.start()
    }

    func signOut() {
        steamID = nil
        keychain.clear()
    }

    private func verify(_ callback: URL) async throws -> Bool {
        guard var components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return false }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "openid.mode" }
        query.append(.init(name: "openid.mode", value: "check_authentication"))
        components.queryItems = query

        var request = URLRequest(url: URL(string: SteamOpenID.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return String(decoding: data, as: UTF8.self)
            .range(of: #"(?im)^is_valid\s*:\s*true"#, options: .regularExpression) != nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
