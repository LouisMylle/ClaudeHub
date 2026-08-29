import Foundation
import Combine

/// Who Claude Code is currently logged in as, per `claude auth status --json`.
struct ClaudeAccount: Equatable {
    let email: String
    let orgName: String?
    let plan: String?          // "pro", "max", …
    let authMethod: String?    // "claude.ai", "console", …

    var shortEmail: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }

    var planLabel: String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    var menuLabel: String {
        [email, planLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Tracks the signed-in account and the accounts you switch between.
///
/// Deliberately hands every credential operation to `claude auth` — ClaudeHub
/// stores nothing but the e-mail addresses you have used, so switching is a
/// normal login, never a token being copied around.
final class AccountStore: ObservableObject {
    @Published private(set) var current: ClaudeAccount?
    /// Not logged in, or `claude auth status` could not be read.
    @Published private(set) var statusMessage: String?
    /// Every address seen or added, so you can switch back with one click.
    @Published private(set) var knownEmails: [String] =
        UserDefaults.standard.stringArray(forKey: "knownAccountEmails") ?? []

    /// Accounts with a saved token, ready to run without a browser.
    @Published private(set) var tokenProfiles: [String] = TokenStore.profiles
    /// nil = run as whoever the CLI is signed in as.
    @Published private(set) var activeProfile: String? = TokenStore.activeProfile

    /// Everything ClaudeHub starts from now on runs as this account.
    func setActive(_ profile: String?) {
        TokenStore.activeProfile = profile
        activeProfile = TokenStore.activeProfile
    }

    private var inFlight = false

    @discardableResult
    func addProfile(_ label: String, token: String) -> Bool {
        guard TokenStore.save(token: token, for: label) else { return false }
        tokenProfiles = TokenStore.profiles
        remember(label)
        return true
    }

    func removeProfile(_ label: String) {
        TokenStore.delete(label)
        tokenProfiles = TokenStore.profiles
        activeProfile = TokenStore.activeProfile
    }

    /// What the sidebar chip shows: the account sessions actually run as.
    var effectiveLabel: String {
        activeProfile ?? current?.shortEmail ?? "Sign in"
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true

        let claude = TerminalManager.shared.claudePath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.readStatus(claude: claude)
            DispatchQueue.main.async {
                self.inFlight = false
                switch result {
                case .success(let account):
                    self.current = account
                    self.statusMessage = nil
                    self.remember(account.email)
                case .failure(let message):
                    self.current = nil
                    self.statusMessage = message
                }
            }
        }
    }

    /// `claude auth login` finishes in a terminal tab; give the CLI a moment
    /// to write the new credentials before asking who we are now.
    func refreshSoon(after seconds: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.refresh()
        }
    }

    func remember(_ email: String) {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.contains("@"), !knownEmails.contains(clean) else { return }
        knownEmails.append(clean)
        knownEmails.sort()
        persist()
    }

    func forget(_ email: String) {
        knownEmails.removeAll { $0 == email }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(knownEmails, forKey: "knownAccountEmails")
    }

    // MARK: - Reading `claude auth status`

    private enum StatusResult {
        case success(ClaudeAccount)
        case failure(String)
    }

    private static func readStatus(claude: String) -> StatusResult {
        // A login shell so node/nvm-style installs resolve the same way they do
        // in the user's own terminal.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "\(ClaudeSession.shellQuote(claude)) auth status --json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failure("Could not run `claude auth status`.")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("`claude auth status` returned no readable status.")
        }
        guard json["loggedIn"] as? Bool == true, let email = json["email"] as? String else {
            return .failure("Not signed in — use Switch Account to log in.")
        }
        return .success(ClaudeAccount(
            email: email,
            orgName: json["orgName"] as? String,
            plan: json["subscriptionType"] as? String,
            authMethod: json["authMethod"] as? String
        ))
    }
}
