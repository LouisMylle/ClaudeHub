import Foundation
import Combine

/// What a tab's terminal actually runs.
enum TerminalTabKind: Hashable {
    case resume(String)      // `claude --resume <session-id>`
    case newSession(String)  // a brand-new `claude --session-id <session-id>` in the tab's folder
    case shell               // plain login shell
    case command([String])   // one-shot `claude <args…>`, e.g. auth login
}

struct TerminalTab: Identifiable, Hashable {
    let id: String              // session UUID for Claude sessions, "sh-…"/"cmd-…" otherwise
    var title: String
    let cwd: String
    let kind: TerminalTabKind
    /// Runs as this saved account instead of the signed-in one (see TokenStore).
    var profile: String? = nil
    /// Runs as the CLI's own login even while a saved account is active — the
    /// only way to say "this tab, on the signed-in account" once you have
    /// switched everything else over.
    var pinnedToSignedIn = false
    /// True while `title` is the "New session · folder" placeholder: a fresh
    /// session has no name until Claude has written its transcript.
    var hasProvisionalTitle = false

    /// The Claude conversation this tab is — resumed, or started here with a
    /// session id we picked ourselves. Nil for shells and one-shot commands.
    var sessionID: String? {
        switch kind {
        case .resume(let id), .newSession(let id): return id
        case .shell, .command: return nil
        }
    }

    /// A one-shot `claude …` tab (auth login, setup-token).
    var isCommand: Bool {
        if case .command = kind { return true }
        return false
    }

    /// A live Claude conversation — the tabs slash commands can be sent to.
    var isConversation: Bool {
        switch kind {
        case .resume, .newSession: return true
        case .shell, .command: return false
        }
    }
}

final class TabsModel: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabID: String?

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// Folder new tabs land in when nothing else is specified.
    var currentFolder: String {
        activeTab?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The open tab running this session, whichever account it runs under.
    func tab(forSessionID id: String) -> TerminalTab? {
        tabs.first { $0.sessionID == id }
    }

    func openSession(_ session: ClaudeSession, profile: String? = nil, signedIn: Bool = false) {
        // Same session under another account is a separate tab, not a clash.
        let id = Self.tabID(session: session.id, profile: signedIn ? "signed-in" : profile)
        if tabs.contains(where: { $0.id == id }) {
            activeTabID = id
            return
        }
        // The conversation is already open — under an account, or as the tab it
        // was started in. Clicking its row brings that tab forward instead of
        // opening a second copy of the same chat.
        if profile == nil, !signedIn, let open = tab(forSessionID: session.id) {
            activeTabID = open.id
            return
        }
        append(TerminalTab(
            id: id,
            title: signedIn
                ? "\(session.title) · signed in"
                : profile.map { "\(session.title) · \(Self.shortLabel($0))" } ?? session.title,
            cwd: session.cwd,
            kind: .resume(session.id),
            profile: profile,
            pinnedToSignedIn: signedIn
        ))
    }

    /// ⌘N: a fresh Claude session in `cwd` (the current folder by default).
    ///
    /// The session id is picked here and handed to the CLI, so the tab and the
    /// sidebar row are the same session from the first moment — the status dot
    /// lights up as soon as the row appears, and clicking it comes back here
    /// instead of resuming the chat a second time.
    func openNewSession(cwd: String? = nil, profile: String? = nil) {
        let folder = cwd ?? currentFolder
        let name = Self.folderName(folder)
        let sessionID = UUID().uuidString.lowercased()
        append(TerminalTab(
            id: Self.tabID(session: sessionID, profile: profile),
            title: profile.map { "\(name) · \(Self.shortLabel($0))" } ?? "New session · \(name)",
            cwd: folder,
            kind: .newSession(sessionID),
            profile: profile,
            hasProvisionalTitle: true
        ))
    }

    /// ⌘T: plain shell tab in `cwd` (the current folder by default).
    func openNewTab(cwd: String? = nil) {
        let folder = cwd ?? currentFolder
        append(TerminalTab(
            id: "sh-\(UUID().uuidString)",
            title: Self.folderName(folder),
            cwd: folder,
            kind: .shell
        ))
    }

    /// Runs a `claude` subcommand in its own tab — `auth login`, `auth logout`.
    /// Reusing an existing tab of the same command keeps them from piling up.
    func openCommand(_ args: [String], title: String, cwd: String? = nil) {
        let id = "cmd-\(args.joined(separator: " "))"
        if tabs.contains(where: { $0.id == id }) {
            close(id)   // a finished login tab would otherwise just sit there
        }
        append(TerminalTab(
            id: id,
            title: title,
            cwd: cwd ?? currentFolder,
            kind: .command(args)
        ))
    }

    /// ⌘1–⌘9
    func activate(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        TerminalManager.shared.closeTerminal(for: id)
        if activeTabID == id {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// Closes the tabs of sessions that no longer exist (after a delete).
    func closeTabs(forSessionIDs ids: Set<String>) {
        for tab in tabs where tab.sessionID.map(ids.contains) == true {
            close(tab.id)
        }
    }

    /// Gives a freshly started tab the chat's own name once the sidebar has
    /// scanned the transcript Claude wrote for it.
    func adoptSessionTitles(from projects: [ClaudeProject]) {
        guard tabs.contains(where: \.hasProvisionalTitle) else { return }
        var titles: [String: String] = [:]
        for project in projects {
            for session in project.sessions { titles[session.id] = session.title }
        }
        for index in tabs.indices where tabs[index].hasProvisionalTitle {
            guard let sessionID = tabs[index].sessionID,
                  let title = titles[sessionID] else { continue }
            tabs[index].title = tabs[index].profile
                .map { "\(title) · \(Self.shortLabel($0))" } ?? title
            tabs[index].hasProvisionalTitle = false
        }
    }

    private func append(_ tab: TerminalTab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    private static func tabID(session: String, profile: String?) -> String {
        profile.map { "\(session)#\($0)" } ?? session
    }

    static func shortLabel(_ profile: String) -> String {
        profile.split(separator: "@").first.map(String.init) ?? profile
    }

    private static func folderName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
