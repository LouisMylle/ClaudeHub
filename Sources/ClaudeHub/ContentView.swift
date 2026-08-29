import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TabsModel
    @EnvironmentObject var accounts: AccountStore
    @EnvironmentObject var usage: UsageStore
    @ObservedObject var terminalManager = TerminalManager.shared
    @ObservedObject var updates = UpdateChecker.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSessionID: String?
    @State private var searchText = ""
    @State private var showMCPManager = false
    @State private var showHiddenSessions = false
    @State private var pendingDeletion: [ClaudeSession] = []
    @State private var deletionScope = ""
    @State private var deleteError: String?

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

    /// A session's dot comes from the tab running it — which may be the tab it
    /// was started in (⌘N) or one opened under another account, so the tab id
    /// is not always the session id.
    private func activity(of session: ClaudeSession) -> TerminalActivity {
        guard let tab = tabs.tab(forSessionID: session.id) else { return .stopped }
        return terminalManager.activity(of: tab.id)
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
        .onAppear {
            store.refresh()
            accounts.refresh()
            // Loads the saved tokens (one keychain panel at most, off the main
            // thread) and checks each one: a token revoked since it was saved
            // should be visible on the chip, not on your first message.
            accounts.primeTokens()
            updates.check()
            // The probe needs a folder Claude Code already trusts, so it waits
            // for the first scan — off the sidebar's own update cycle.
            usage.startPolling { store.projects.first?.path }
        }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
            // Coming back from the login page in the browser lands here.
            accounts.refresh()
            // The limits are not polled behind a window nobody is watching, so
            // coming back to it is when they are worth re-reading.
            usage.refresh()
        }
        .onChange(of: store.projects) { _, projects in
            // A ⌘N tab is titled after its folder until the transcript exists.
            tabs.adoptSessionTitles(from: projects)
        }
        .onChange(of: selectedSessionID) { _, id in
            guard let id, let session = session(withID: id) else { return }
            tabs.openSession(session)
        }
        .onChange(of: tabs.activeTabID) { _, _ in
            // Keep the sidebar in sync with the active tab (nil for fresh-session tabs)
            selectedSessionID = tabs.activeTab?.sessionID
        }
        .onReceive(NotificationCenter.default.publisher(for: .newClaudeSessionInFolder)) { _ in
            newSessionInChosenFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedSession)) { _ in
            requestDeletionOfSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeAccountChanged)) { _ in
            // Switching account switches the whole window, not just what you
            // open next: every conversation restarts on the new account and
            // resumes where it was.
            terminalManager.restartConversations(tabs.tabs)
            usage.accountChanged()
        }
        .confirmationDialog(deleteTitle, isPresented: deleteConfirmationBinding, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { confirmDeletion() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(deleteMessage)
        }
        .alert("Could not delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSessionID) {
            ForEach(filteredProjects) { project in
                Section {
                    ForEach(project.sessions) { session in
                        SessionRow(session: session,
                                   activity: activity(of: session),
                                   isHidden: store.hiddenSessionIDs.contains(session.id))
                            .tag(session.id)
                            .contextMenu { sessionMenu(session) }
                    }
                } header: {
                    ProjectHeader(
                        project: project,
                        newSession: { tabs.openNewSession(cwd: project.path); store.refreshSoon() },
                        menu: { projectMenu(project) }
                    )
                }
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { requestDeletionOfSelection() }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UsageBars(usage: usage)
                HStack {
                    AccountChip(accounts: accounts, tabs: tabs)
                Spacer()
                Text("\(store.projects.map(\.sessions.count).reduce(0, +)) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(store.projects.count) projects · ClaudeHub v\(UpdateChecker.currentVersion)")
                if store.isLoading { ProgressView().controlSize(.small) }
                if updates.updateAvailable, let version = updates.latestVersion {
                    Button {
                        updates.downloadAndInstall()
                    } label: {
                        if updates.isInstalling {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("v\(version)", systemImage: "arrow.down.circle.fill")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help(updates.errorMessage
                          ?? "Update to ClaudeHub \(version) — downloads, installs, and relaunches")
                }
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
            }
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Session in Current Folder") { newSession() }
                        .disabled(tabs.activeTab == nil)
                    Button("New Session in Folder…") { newSessionInChosenFolder() }
                    Button("New Terminal Tab") { tabs.openNewTab() }
                    if !store.projects.isEmpty {
                        Divider()
                        Section("Start in project") {
                            ForEach(store.projects.prefix(10)) { project in
                                Button(project.name) { newSession(in: project.path) }
                                    .help(project.path)
                            }
                        }
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                } primaryAction: {
                    if tabs.activeTab == nil { newSessionInChosenFolder() } else { newSession() }
                }
                .help("Start a new Claude session (⌘N) — hold for more options")
            }
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
                TabBarView(newSession: { newSession() },
                           newSessionElsewhere: { newSessionInChosenFolder() },
                           accounts: accounts)
                Divider()
                if tab.isCommand, let link = terminalManager.signInURL(in: tab.id) {
                    SignInLinkBar(url: link)
                    Divider()
                }
                TerminalHostView(tab: tab, generation: terminalManager.generation)
                    .background(terminalBackground)
            }
            .navigationTitle(tab.title)
            .navigationSubtitle(tab.cwd)
        } else {
            ContentUnavailableView {
                Label("ClaudeHub", systemImage: "terminal")
            } description: {
                Text("Pick a session in the sidebar to resume it right here,\nor start a fresh one.")
            } actions: {
                HStack {
                    Button("New Session…") { newSessionInChosenFolder() }
                        .buttonStyle(.borderedProminent)
                    if let recent = store.projects.first {
                        Button("New Session in \(recent.name)") { newSession(in: recent.path) }
                    }
                }
            }
        }
    }

    // MARK: - Starting sessions

    private func newSession(in folder: String? = nil) {
        tabs.openNewSession(cwd: folder)
        store.refreshSoon()
    }

    /// ⇧⌘N — pick any folder on disk, no existing session needed.
    private func newSessionInChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder for the new Claude session"
        panel.prompt = "Start Session"
        panel.directoryURL = URL(fileURLWithPath: tabs.currentFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newSession(in: url.path)
    }

    // MARK: - Menus

    @ViewBuilder
    private func sessionMenu(_ session: ClaudeSession) -> some View {
        if !accounts.tokenProfiles.isEmpty {
            Menu("Resume as") {
                ForEach(accounts.tokenProfiles, id: \.self) { profile in
                    Button(accounts.describe(profile: profile)) {
                        tabs.openSession(session, profile: profile)
                    }
                }
                // Without this there is no way back to the CLI's own login
                // once a saved account is the active one.
                Button(accounts.current.map { "\($0.email) (signed in)" } ?? "Signed-in account") {
                    tabs.openSession(session, signedIn: true)
                }
            }
            Divider()
        }
        Button("New Session in This Folder") { newSession(in: session.cwd) }
        Button("New Terminal in This Folder") { tabs.openNewTab(cwd: session.cwd) }
        Divider()
        if Self.vsCodeURL != nil {
            Button("Open in VS Code") { openInVSCode(session.cwd) }
        }
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
        Button("Delete Session…", role: .destructive) {
            requestDeletion([session], scope: "“\(session.title)”")
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: ClaudeProject) -> some View {
        Button("New Session in This Project") { newSession(in: project.path) }
        Button("New Terminal in This Project") { tabs.openNewTab(cwd: project.path) }
        Divider()
        if Self.vsCodeURL != nil {
            Button("Open in VS Code") { openInVSCode(project.path) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Delete All Sessions in \(project.name)…", role: .destructive) {
            requestDeletion(project.sessions, scope: "all \(project.sessions.count) sessions in \(project.name)")
        }
    }

    // MARK: - Deleting

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
    }

    private var deleteTitle: String {
        pendingDeletion.count == 1 ? "Delete this session?" : "Delete \(pendingDeletion.count) sessions?"
    }

    private var deleteMessage: String {
        let running = pendingDeletion.filter { terminalManager.isRunning($0.id) }.count
        var text = "Deleting \(deletionScope) moves the transcript to the Trash. "
            + "The chat disappears from ClaudeHub and can no longer be resumed."
        if running > 0 {
            text += running == 1
                ? "\n\nIts open tab will be closed and the running process ended."
                : "\n\n\(running) open tabs will be closed and their running processes ended."
        }
        return text
    }

    private func requestDeletion(_ sessions: [ClaudeSession], scope: String) {
        guard !sessions.isEmpty else { return }
        deletionScope = scope
        pendingDeletion = sessions
    }

    /// The ⌫ key on the focused sidebar row.
    private func requestDeletionOfSelection() {
        guard let id = selectedSessionID, let session = session(withID: id) else { return }
        requestDeletion([session], scope: "“\(session.title)”")
    }

    private func confirmDeletion() {
        let sessions = pendingDeletion
        pendingDeletion = []
        guard !sessions.isEmpty else { return }

        let ids = Set(sessions.map(\.id))
        tabs.closeTabs(forSessionIDs: ids)
        if let selected = selectedSessionID, ids.contains(selected) { selectedSessionID = nil }

        let failed = store.delete(sessions)
        guard !failed.isEmpty else { return }
        deleteError = failed.count == 1
            ? "“\(failed[0].title)” could not be moved to the Trash. Check the file's permissions."
            : "\(failed.count) sessions could not be moved to the Trash. Check the files' permissions."
    }

    /// nil when VS Code is not installed, which hides the menu item.
    private static let vsCodeURL: URL? =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    private func openInVSCode(_ path: String) {
        guard let application = Self.vsCodeURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
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
    let newSession: () -> Void
    let newSessionElsewhere: () -> Void
    @ObservedObject var accounts: AccountStore

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: tab.id == tabs.activeTabID,
                            activity: terminalManager.activity(of: tab.id),
                            accountLabel: accounts.effectiveLabel,
                            account: terminalManager.profile(of: tab),
                            accountIsLive: terminalManager.hasLaunched(tab.id),
                            fellBackFrom: terminalManager.fallbackAccount(of: tab.id),
                            pending: terminalManager.pendingSwitch(of: tab.id),
                            activate: { tabs.activeTabID = tab.id },
                            restart: { terminalManager.relaunch(tab) },
                            close: { tabs.close(tab.id) }
                        )
                    }
                }
                .padding(.vertical, 5)
            }
            Menu {
                Button("Usage & Limits") { ClaudeCommands.send("/usage", tabs: tabs) }
                Button("Account & Status") { ClaudeCommands.send("/status", tabs: tabs) }
                Button("Context Left") { ClaudeCommands.send("/context", tabs: tabs) }
                Divider()
                AccountItems(accounts: accounts, tabs: tabs)
            } label: {
                Image(systemName: "gauge.with.needle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Usage, limits and account switching (⌘U)")
            Menu {
                Button("New Session Here") { newSession() }
                Button("New Session in Folder…") { newSessionElsewhere() }
                Button("New Terminal Here") { tabs.openNewTab() }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                newSession()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Claude session in this folder (⌘N) — hold for a terminal tab or another folder")
            .padding(.trailing, 8)
        }
        .padding(.leading, 8)
        .background(.bar)
    }
}

private struct TabChip: View {
    let tab: TerminalTab
    let isActive: Bool
    let activity: TerminalActivity
    let accountLabel: String
    /// The saved account this tab runs as, nil for the signed-in one.
    let account: String?
    /// True once the tab is running, so the account is a fact, not a plan.
    let accountIsLive: Bool
    /// Set when the tab wanted a saved account and had to start without it.
    let fellBackFrom: String?
    /// Set when the tab could not move to the new account yet, and why.
    let pending: (account: String, waitingOnPaste: Bool)?
    let activate: () -> Void
    let restart: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if activity == .dead {
                Button(action: restart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Session ended — restart")
            } else if tab.isConversation {
                ActivityDot(activity: activity, size: 6)
                    .opacity(isActive || activity.pulses ? 1 : 0.55)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let pending {
                Text("→ \(TabsModel.shortLabel(pending.account))")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.20), in: Capsule())
                    .help(pending.waitingOnPaste
                          ? """
                            Waiting: the prompt holds pasted content, which only \
                            this session has — restarting would lose it. Send or \
                            clear it and this tab moves to \(pending.account).
                            """
                          : """
                            Busy right now — this conversation moves to \
                            \(pending.account) and resumes as soon as it is done.
                            """)
            } else if let fellBackFrom {
                Text("signed in")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .help("""
                        This tab runs on the signed-in account: the saved token \
                        for \(fellBackFrom) could not be read. Fix it in the \
                        account menu, then restart the tab.
                        """)
            } else if let account {
                Text(TabsModel.shortLabel(account))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(accountIsLive ? 0.22 : 0.10), in: Capsule())
                    .help(accountIsLive
                          ? "Running as \(account)"
                          : "Will start as \(account)")
            }
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
        .contextMenu {
            // Switching account already restarts every conversation; this is
            // for the single tab you want moved or simply started again.
            Text(fellBackFrom.map { "Wanted \($0) — running on the signed-in account" }
                 ?? account.map { "Running as \($0)" }
                 ?? "Running as the signed-in account")
            Button(tab.sessionID == nil
                   ? "Restart Tab"
                   : "Restart as \(accountLabel)") { restart() }
            Button("Close Tab") { close() }
        }
    }
}

/// The login URL a `claude auth` tab prints is hard-wrapped across three lines
/// and cmd-clicking it goes straight to the browser, so there is no way to just
/// copy it. This lifts it out whole.
private struct SignInLinkBar: View {
    let url: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text(url)
                .font(.system(size: 11).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(copied ? "Copied" : "Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
            if let destination = URL(string: url) {
                Button("Open") { NSWorkspace.shared.open(destination) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let activity: TerminalActivity
    let isHidden: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(session.lastActivity, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if activity != .stopped {
                ActivityDot(activity: activity)
            }
        }
        .padding(.vertical, 1)
        .opacity(isHidden ? 0.55 : 1)
    }
}

private struct ProjectHeader<MenuContent: View>: View {
    let project: ClaudeProject
    let newSession: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(project.sessions.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Spacer()
            Button(action: newSession) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            // Keeps the button clear of the sidebar scroll bar.
            .padding(.trailing, 8)
            .help("New Claude session in \(project.name)")
        }
        .padding(.top, 12)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        // Deferred: setting state straight from a hover callback mutates the
        // row while AppKit is still laying the table out.
        .onHover { hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        .help(project.path)
        .contextMenu { menu() }
    }
}
