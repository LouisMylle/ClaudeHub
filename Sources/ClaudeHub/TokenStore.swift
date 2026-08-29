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
///
/// ## Why the tokens are cached in memory
///
/// ClaudeHub is signed ad-hoc, so every build — including every auto-update —
/// is a different program as far as the keychain is concerned, and the first
/// read after an update raises the "wants to use your confidential information"
/// panel. That panel blocks whatever thread asked, so the reads happen off the
/// main thread, once per launch, and the answer is kept for the session. A
/// refusal is remembered too: without that, starting a session would silently
/// fall back to the signed-in account, which looks exactly like account
/// switching being broken.
enum TokenStore {
    private static let service = "be.optimize.claudehub.oauth-token"
    private static let indexKey = "tokenProfiles"

    /// What a keychain read came back with.
    enum Access {
        case token(String)
        /// macOS refused, or the person clicked Deny on the panel.
        case blocked(String)
        /// No such item — the account was forgotten, or never saved here.
        case missing
    }

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var blocked: [String: String] = [:]

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

        // Saving is also how access is repaired: the item now belongs to the
        // build that just wrote it, so it reads back without a panel.
        lock.lock()
        cache[profile] = token
        blocked[profile] = nil
        lock.unlock()

        var list = profiles
        if !list.contains(profile) {
            list.append(profile)
            list.sort()
            UserDefaults.standard.set(list, forKey: indexKey)
        }
        return true
    }

    /// The token if it is already in hand — never prompts, never blocks. This
    /// is what starting a session uses, so a tab can never freeze the app on a
    /// keychain panel.
    static func cachedToken(for profile: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[profile]
    }

    /// Whether this account's token could not be read, and why.
    static func blockedReason(for profile: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return blocked[profile]
    }

    /// Reads a token, raising the keychain panel if macOS wants one. Call it
    /// off the main thread.
    @discardableResult
    static func read(_ profile: String) -> Access {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: "run Claude sessions as \(profile)",
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        lock.lock()
        defer { lock.unlock() }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                let why = "The keychain item is not readable text."
                blocked[profile] = why
                return .blocked(why)
            }
            cache[profile] = token
            blocked[profile] = nil
            return .token(token)
        case errSecItemNotFound:
            cache[profile] = nil
            blocked[profile] = nil
            return .missing
        default:
            let why = Self.explain(status)
            cache[profile] = nil
            blocked[profile] = why
            return .blocked(why)
        }
    }

    /// Loads every saved token once, in the background — at most one keychain
    /// panel per launch, and never on the main thread.
    static func prime(_ profiles: [String], completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for profile in profiles where cachedToken(for: profile) == nil {
                read(profile)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Ad-hoc signing is the usual reason, so the wording points at the fix
    /// rather than at the OSStatus.
    private static func explain(_ status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed,
             errSecInteractionRequired:
            return """
                macOS did not let ClaudeHub read the saved token. Every update is \
                a new program to the keychain — choose Always Allow on the panel, \
                or paste the token again.
                """
        default:
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The keychain refused the token: \(text)"
        }
    }

    static func delete(_ profile: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(profiles.filter { $0 != profile }, forKey: indexKey)
        lock.lock()
        cache[profile] = nil
        blocked[profile] = nil
        lock.unlock()
        if activeProfile == profile { activeProfile = nil }
    }
}
