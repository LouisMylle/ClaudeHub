import SwiftUI

/// The things the Claude menu and the sidebar account chip can do.
///
/// Account changes go through the `claude auth` CLI in a visible terminal tab,
/// so the real login flow (browser, SSO, 2FA) happens exactly as it normally
/// would and ClaudeHub never holds a credential.
enum ClaudeCommands {

    // MARK: Slash commands in the current session

    static func canSend(_ tabs: TabsModel) -> Bool {
        guard let tab = tabs.activeTab, tab.isConversation else { return false }
        return TerminalManager.shared.activity(of: tab.id) != .dead
    }

    static func send(_ command: String, tabs: TabsModel) {
        guard let tab = tabs.activeTab, tab.isConversation else { return }
        TerminalManager.shared.sendSlashCommand(command, to: tab.id)
    }

    // MARK: Accounts

    /// `email == nil` opens the plain login picker, same as `/login`.
    static func logIn(as email: String?, accounts: AccountStore, tabs: TabsModel) {
        var args = ["auth", "login"]
        if let email, !email.isEmpty {
            args += ["--email", email]
            accounts.remember(email)
        }
        tabs.openCommand(args, title: email.map { "Login · \($0)" } ?? "Login")
        // The browser round trip takes a while; the window regaining focus
        // refreshes too, this just catches a login that finished in the tab.
        accounts.refreshSoon(after: 15)
        accounts.refreshSoon(after: 45)
    }

    static func promptForNewAccount(accounts: AccountStore, tabs: TabsModel) {
        let alert = NSAlert()
        alert.messageText = "Sign in to another account"
        alert.informativeText = """
            ClaudeHub only remembers the address, so you can switch back with one \
            click later. The login itself runs `claude auth login` in a tab.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "you@example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let email = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        logIn(as: email.isEmpty ? nil : email, accounts: accounts, tabs: tabs)
    }

    // MARK: Saved accounts (instant, no browser)

    /// Mints a token for whichever account you log in as, in a visible tab.
    static func runSetupToken(tabs: TabsModel) {
        tabs.openCommand(["setup-token"], title: "Setup token")
    }

    static func addProfile(accounts: AccountStore, tabs: TabsModel) {
        let alert = NSAlert()
        alert.messageText = "Add an account you can switch to instantly"
        alert.informativeText = """
            Run `claude setup-token` while signed in as that account, then paste \
            the token it prints. ClaudeHub keeps it in your login keychain and \
            hands it to the sessions you start as that account — no browser, and \
            other tabs keep running on their own account.
            """
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 56))
        let label = NSTextField(frame: NSRect(x: 0, y: 30, width: 330, height: 22))
        label.placeholderString = "Label, e.g. work@example.com"
        let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 22))
        token.placeholderString = "Token from claude setup-token"
        container.addSubview(label)
        container.addSubview(token)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Run setup-token…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = label

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let name = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !secret.isEmpty else { return }
            if !accounts.addProfile(name, token: secret) {
                let failure = NSAlert()
                failure.messageText = "Could not save the token"
                failure.informativeText = "The login keychain refused the item."
                failure.runModal()
            }
        case .alertSecondButtonReturn:
            runSetupToken(tabs: tabs)
        default:
            break
        }
    }

    static func removeProfile(_ label: String, accounts: AccountStore) {
        let alert = NSAlert()
        alert.messageText = "Forget \(label)?"
        alert.informativeText = """
            The token is deleted from your keychain. Sessions already running as \
            this account keep going. Revoke the token itself at claude.ai if you \
            no longer want it to work at all.
            """
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accounts.removeProfile(label)
    }

    static func logOut(accounts: AccountStore, tabs: TabsModel) {
        let alert = NSAlert()
        alert.messageText = "Log out of Claude Code?"
        alert.informativeText = """
            This signs out the `claude` CLI everywhere, not just in ClaudeHub. \
            Sessions that are already running keep going until they need to \
            authenticate again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        tabs.openCommand(["auth", "logout"], title: "Logout")
        accounts.refreshSoon(after: 4)
    }
}

/// Account items, shared by the menu-bar Claude menu and the sidebar chip.
/// Shortcuts live in the menu bar only, so nothing is bound twice.
struct AccountItems: View {
    @ObservedObject var accounts: AccountStore
    @ObservedObject var tabs: TabsModel

    var body: some View {
        Section("Signed in") {
            if let current = accounts.current {
                Text(current.menuLabel)
                if let org = current.orgName { Text(org) }
            } else {
                Text(accounts.statusMessage ?? "Checking…")
            }
        }

        Divider()

        if !accounts.tokenProfiles.isEmpty {
            Section("Start a session as") {
                ForEach(accounts.tokenProfiles, id: \.self) { profile in
                    Button(profile) { tabs.openNewSession(profile: profile) }
                }
            }
        }
        Button("Add Account for Instant Switching…") {
            ClaudeCommands.addProfile(accounts: accounts, tabs: tabs)
        }

        Divider()

        let others = accounts.knownEmails.filter { $0 != accounts.current?.email }
        if !others.isEmpty {
            Section("Switch to") {
                ForEach(others, id: \.self) { email in
                    Button(email) { ClaudeCommands.logIn(as: email, accounts: accounts, tabs: tabs) }
                }
            }
        }
        Button("Sign In to Another Account…") {
            ClaudeCommands.promptForNewAccount(accounts: accounts, tabs: tabs)
        }

        Divider()

        Button("Re-check Account") { accounts.refresh() }
        Button("Log Out…") { ClaudeCommands.logOut(accounts: accounts, tabs: tabs) }

        if !others.isEmpty || !accounts.tokenProfiles.isEmpty {
            Divider()
            Menu("Forget") {
                ForEach(accounts.tokenProfiles, id: \.self) { profile in
                    Button("\(profile) (saved token)") {
                        ClaudeCommands.removeProfile(profile, accounts: accounts)
                    }
                }
                ForEach(others, id: \.self) { email in
                    Button(email) { accounts.forget(email) }
                }
            }
        }
    }
}

/// Sidebar footer chip — which account am I burning limits on right now.
struct AccountChip: View {
    @ObservedObject var accounts: AccountStore
    @ObservedObject var tabs: TabsModel

    var body: some View {
        Menu {
            AccountItems(accounts: accounts, tabs: tabs)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: accounts.current == nil
                      ? "person.crop.circle.badge.exclamationmark"
                      : "person.crop.circle")
                Text(accounts.current?.shortEmail ?? "Sign in")
                    .lineLimit(1)
                if let plan = accounts.current?.planLabel {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(accounts.current.map { "Signed in as \($0.email)\nSwitch accounts, or check usage with ⌘U" }
              ?? "Not signed in — click to log in")
    }
}
