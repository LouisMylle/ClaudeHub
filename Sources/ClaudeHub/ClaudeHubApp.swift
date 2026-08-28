import SwiftUI

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(tabs)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.shared.check() }
            }
            CommandGroup(after: .newItem) {
                Button("New Tab") { tabs.openNewTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Refresh Sessions") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
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
