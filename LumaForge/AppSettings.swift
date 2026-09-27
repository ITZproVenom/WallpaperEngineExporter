import Foundation

/// Small keychain wrapper for values that should not sit in UserDefaults.
struct KeychainValue {
    let service = "com.itzprovenom.lumaforge"
    let account: String

    func save(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(insert as CFDictionary, nil)
    }

    func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// User-configurable settings. The worker is optional and only matters for
/// real-time scene wallpapers, so the app works fully with none of this set.
@MainActor
final class AppSettings: ObservableObject {
    private static let workerKey = "LumaForgeWorkerURL"
    private let apiKeyStore = KeychainValue(account: "workerAPIKey")

    @Published var workerURLText: String {
        didSet { UserDefaults.standard.set(workerURLText, forKey: Self.workerKey) }
    }

    @Published var apiKey: String {
        didSet { apiKeyStore.save(apiKey) }
    }

    init() {
        workerURLText = UserDefaults.standard.string(forKey: Self.workerKey) ?? ""
        apiKey = ""
        apiKey = apiKeyStore.load() ?? ""
    }

    var workerURL: URL? {
        let trimmed = workerURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    var workerURLIsInvalid: Bool {
        !workerURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && workerURL == nil
    }

    func registry() -> AcquisitionRegistry {
        AcquisitionRegistry(sources: [
            ImportedPackageSource(),
            WorkerSource(baseURL: workerURL, apiKey: apiKey),
        ])
    }
}
