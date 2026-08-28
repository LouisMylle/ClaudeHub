import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TabsModel
    @ObservedObject var terminalManager = TerminalManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSessionID: String?
    @State private var searchText = ""
    @State private var showMCPManager = false
    @State private var showHiddenSessions = false

    /// Matches the SwiftTerm palette background in TerminalManager.
    private var terminalBackground: SwiftUI.Color {
        colorScheme == .dark ? Color(red: 0.118, green: 0.118, blue: 0.118) : .white
    }

    private var filteredProjects: [ClaudeProject] {
        let visible: [ClaudeProject] = store.projects.compactMap { project in
            var copy = project
            copy.sessions = project.sessions.filter {
                showHiddenSessions || !store.hiddenSessionIDs.contains($0.id)
            }
            return copy.sessions.isEmpty ? nil : copy
        }
        guard !searchText.isEmpty else { return visible }
        let query = searchText.lowercased()
        return visible.compactMap { project in
            if project.name.lowercased().contains(query) { return project }
            let sessions = project.sessions.filter { $0.title.lowercased().contains(query) }
            guard !sessions.isEmpty else { return nil }
            var copy = project
            copy.sessions = sessions
            return copy
        }
    }

    private func session(withID id: String) -> ClaudeSession? {
        for project in store.projects {
            if let session = project.sessions.first(where: { $0.id == id }) {
                return session
            }
        }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .onChange(of: selectedSessionID) { _, id in
            guard let id, let session = session(withID: id) else { return }
            tabs.openSession(session)
        }
        .onChange(of: tabs.activeTabID) { _, _ in
            // Keep the sidebar in sync with the active tab (nil for fresh-session tabs)
            selectedSessionID = tabs.activeTab?.resumeSessionID
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSessionID) {
            ForEach(filteredProjects) { project in
                Section {
                    ForEach(project.sessions) { session in
                        SessionRow(session: session,
                                   isRunning: terminalManager.isRunning(session.id),
                                   isHidden: store.hiddenSessionIDs.contains(session.id))
                            .tag(session.id)
                            .contextMenu { sessionMenu(session) }
                    }
                } header: {
                    ProjectHeader(project: project)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(store.projects.count) projects · \(store.projects.map(\.sessions.count).reduce(0, +)) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if !store.hiddenSessionIDs.isEmpty {
                    Button {
                        showHiddenSessions.toggle()
                    } label: {
                        Image(systemName: showHiddenSessions ? "eye" : "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(showHiddenSessions
                          ? "Hide the \(store.hiddenSessionIDs.count) hidden sessions again"
                          : "Show \(store.hiddenSessionIDs.count) hidden sessions")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showMCPManager = true
                } label: {
                    Label("MCP Servers", systemImage: "server.rack")
                }
                .help("Manage Claude Code MCP servers")
            }
            ToolbarItem {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan ~/.claude/projects")
            }
        }
        .sheet(isPresented: $showMCPManager) {
            MCPManagerView()
                .environmentObject(store)
                .environmentObject(tabs)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let tab = tabs.activeTab {
            VStack(spacing: 0) {
                TabBarView()
                Divider()
                TerminalHostView(tab: tab, generation: terminalManager.generation)
                    .background(terminalBackground)
            }
            .navigationTitle(tab.title)
            .navigationSubtitle(tab.cwd)
        } else {
            ContentUnavailableView {
                Label("ClaudeHub", systemImage: "terminal")
            } description: {
                Text("Select a session to resume it right here.\n⌘T opens a terminal tab in the current folder.")
            }
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: ClaudeSession) -> some View {
        Button("Open in Terminal.app") { openInTerminalApp(session) }
        Button("Reveal Folder in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
        }
        Divider()
        Button("Copy Resume Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.resumeCommand, forType: .string)
        }
        Button("Copy Session ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.id, forType: .string)
        }
        Divider()
        if store.hiddenSessionIDs.contains(session.id) {
            Button("Unhide Session") { store.setHidden(session, false) }
        } else {
            Button("Hide Session") {
                if selectedSessionID == session.id { selectedSessionID = nil }
                store.setHidden(session, true)
            }
        }
    }

    private func openInTerminalApp(_ session: ClaudeSession) {
        let command = session.resumeCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        DispatchQueue.global().async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Tab bar

private struct TabBarView: View {
    @EnvironmentObject var tabs: TabsModel
    @ObservedObject var terminalManager = TerminalManager.shared

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: tab.id == tabs.activeTabID,
                            isDead: terminalManager.isDead(tab.id),
                            activate: { tabs.activeTabID = tab.id },
                            restart: { terminalManager.relaunch(tab) },
                            close: { tabs.close(tab.id) }
                        )
                    }
                }
                .padding(.vertical, 5)
            }
            Button {
                tabs.openNewTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New terminal tab in the current folder (⌘T)")
            .padding(.trailing, 8)
        }
        .padding(.leading, 8)
        .background(.bar)
    }
}

private struct TabChip: View {
    let tab: TerminalTab
    let isActive: Bool
    let isDead: Bool
    let activate: () -> Void
    let restart: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if isDead {
                Button(action: restart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Session ended — restart")
            } else {
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
            }
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let isRunning: Bool
    let isHidden: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(session.lastModified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .help("Terminal running")
            }
        }
        .padding(.vertical, 1)
        .opacity(isHidden ? 0.55 : 1)
    }
}

private struct ProjectHeader: View {
    let project: ClaudeProject

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.caption2)
            Text(project.name)
        }
        .help(project.path)
    }
}
