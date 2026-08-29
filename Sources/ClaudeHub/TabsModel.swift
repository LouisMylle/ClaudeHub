import Foundation
import Combine

/// What a tab's terminal actually runs.
enum TerminalTabKind: Hashable {
    case resume(String)   // `claude --resume <session-id>`
    case newSession       // a brand-new `claude` session in the tab's folder
    case shell            // plain login shell
    case command([String])   // one-shot `claude <args…>`, e.g. auth login
}

struct TerminalTab: Identifiable, Hashable {
    let id: String              // session UUID for resumed sessions, "new-…"/"sh-…" otherwise
    let title: String
    let cwd: String
    let kind: TerminalTabKind

    var resumeSessionID: String? {
        if case .resume(let id) = kind { return id }
        return nil
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

    func openSession(_ session: ClaudeSession) {
        if tabs.contains(where: { $0.id == session.id }) {
            activeTabID = session.id
            return
        }
        append(TerminalTab(
            id: session.id,
            title: session.title,
            cwd: session.cwd,
            kind: .resume(session.id)
        ))
    }

    /// ⌘N: a fresh Claude session in `cwd` (the current folder by default).
    func openNewSession(cwd: String? = nil) {
        let folder = cwd ?? currentFolder
        append(TerminalTab(
            id: "new-\(UUID().uuidString)",
            title: "New session · \(Self.folderName(folder))",
            cwd: folder,
            kind: .newSession
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
        for tab in tabs where tab.resumeSessionID.map(ids.contains) == true {
            close(tab.id)
        }
    }

    private func append(_ tab: TerminalTab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    private static func folderName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
