import SwiftUI

extension Notification.Name {
    /// Menu → "New Session in Folder…": the folder picker lives in the window
    /// that has the tabs, so the command just asks for it.
    static let newClaudeSessionInFolder = Notification.Name("ClaudeHub.newSessionInFolder")
    /// Menu → "Delete Session": acted on by the window holding the selection.
    static let deleteSelectedSession = Notification.Name("ClaudeHub.deleteSelectedSession")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = TerminalManager.shared.runningCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = running == 1
            ? "1 terminal is still running"
            : "\(running) terminals are still running"
        alert.informativeText = "Quitting ClaudeHub ends these processes. Claude sessions can be resumed later from the sidebar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct ClaudeHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var tabs = TabsModel()
    @StateObject private var accounts = AccountStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(tabs)
                .environmentObject(accounts)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.shared.check() }
            }
            CommandGroup(replacing: .newItem) {
                NewItemCommands(store: store, tabs: tabs)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Delete Session…") {
                    NotificationCenter.default.post(name: .deleteSelectedSession, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            // Take over ⌘W: close the active tab, not the window
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    if let id = tabs.activeTabID { tabs.close(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(tabs.activeTabID == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Claude") {
                Button("Usage & Limits") { ClaudeCommands.send("/usage", tabs: tabs) }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(!ClaudeCommands.canSend(tabs))
                Button("Account & Status") { ClaudeCommands.send("/status", tabs: tabs) }
                    .disabled(!ClaudeCommands.canSend(tabs))
                Button("Context Left") { ClaudeCommands.send("/context", tabs: tabs) }
                    .disabled(!ClaudeCommands.canSend(tabs))
                Button("Model…") { ClaudeCommands.send("/model", tabs: tabs) }
                    .disabled(!ClaudeCommands.canSend(tabs))

                Divider()

                Button("Switch Account…") {
                    ClaudeCommands.logIn(as: nil, accounts: accounts, tabs: tabs)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                AccountItems(accounts: accounts, tabs: tabs)
            }
            CommandMenu("Tabs") {
                ForEach(1..<10, id: \.self) { number in
                    Button("Tab \(number)") { tabs.activate(index: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .disabled(tabs.tabs.count < number)
                }
            }
        }
    }
}

/// The File menu. A view (rather than inline buttons) so it can reach
/// `openWindow` for "New Window", which `.newItem` no longer provides.
private struct NewItemCommands: View {
    // Plain references, not @ObservedObject: these commands only call methods,
    // they show no state. Observing would rebuild the File menu on every
    // session scan, which re-enters the sidebar's layout.
    let store: SessionStore
    let tabs: TabsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Claude Session") {
            tabs.openNewSession()
            store.refreshSoon()
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("New Claude Session in Folder…") {
            NotificationCenter.default.post(name: .newClaudeSessionInFolder, object: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button("New Terminal Tab") { tabs.openNewTab() }
            .keyboardShortcut("t", modifiers: .command)

        Divider()

        Button("New Window") { openWindow(id: "main") }
            .keyboardShortcut("n", modifiers: [.command, .option])

        Button("Refresh Sessions") { store.refresh() }
            .keyboardShortcut("r", modifiers: .command)
    }
}
