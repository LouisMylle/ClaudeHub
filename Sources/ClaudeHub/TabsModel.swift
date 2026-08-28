import Foundation
import Combine

struct TerminalTab: Identifiable, Hashable {
    let id: String              // session UUID for resumed sessions, "new-…" for fresh ones
    let title: String
    let cwd: String
    let resumeSessionID: String?   // nil = start a brand-new claude session
}

final class TabsModel: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabID: String?

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    func openSession(_ session: ClaudeSession) {
        if tabs.contains(where: { $0.id == session.id }) {
            activeTabID = session.id
            return
        }
        tabs.append(TerminalTab(
            id: session.id,
            title: session.title,
            cwd: session.cwd,
            resumeSessionID: session.id
        ))
        activeTabID = session.id
    }

    /// ⌘T: plain shell tab in the folder of the active tab (home folder as fallback).
    func openNewTab() {
        let cwd = activeTab?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let projectName = cwd.split(separator: "/").last.map(String.init) ?? cwd
        let tab = TerminalTab(
            id: "new-\(UUID().uuidString)",
            title: projectName,
            cwd: cwd,
            resumeSessionID: nil
        )
        tabs.append(tab)
        activeTabID = tab.id
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
}
