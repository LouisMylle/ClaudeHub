import Foundation
import Security

/// Long-lived `claude setup-token` tokens, one per account, in the login
/// keychain.
///
/// This is what makes switching instant. `claude auth login` changes the one
/// account the CLI is signed in as, machine-wide, through the browser. A token
/// instead travels in a single session's environment as
/// `CLAUDE_CODE_OAUTH_TOKEN`, so a tab can run as a different account than the
/// one you are signed in as — and two tabs can run as two accounts at once.
///
/// ClaudeHub never reads Claude Code's own credentials: you mint a token with
/// `claude setup-token` and hand it over, exactly like giving an app an API key.
enum TokenStore {
    private static let service = "be.optimize.claudehub.oauth-token"
    private static let indexKey = "tokenProfiles"

    /// The account ClaudeHub runs sessions as. nil means "whoever the CLI is
    /// signed in as", which is the behaviour without any saved accounts.
    static var activeProfile: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: "activeProfile"),
                  profiles.contains(value) else { return nil }
            return value
        }
        set { UserDefaults.standard.set(newValue, forKey: "activeProfile") }
    }

    /// Labels only — the tokens themselves never leave the keychain.
    static var profiles: [String] {
        UserDefaults.standard.stringArray(forKey: indexKey) ?? []
    }

    @discardableResult
    static func save(token: String, for profile: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        attributes[kSecAttrLabel as String] = "ClaudeHub — \(profile)"
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return false }

        var list = profiles
        if !list.contains(profile) {
            list.append(profile)
            list.sort()
            UserDefaults.standard.set(list, forKey: indexKey)
        }
        return true
    }

    static func token(for profile: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ profile: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(profiles.filter { $0 != profile }, forKey: indexKey)
        if activeProfile == profile { activeProfile = nil }
    }
}
