import AppKit
import SwiftTerm

/// Keeps one live terminal per tab so switching in the sidebar
/// doesn't kill running Claude processes.
final class TerminalManager: NSObject, ObservableObject {
    static let shared = TerminalManager()

    /// Bumped when a process ends/restarts so views and status dots update.
    @Published private(set) var generation = 0

    private var terminals: [String: LocalProcessTerminalView] = [:]
    /// Tabs whose process has exited; their view stays (showing the exit
    /// message) until the tab is closed or explicitly restarted.
    private var deadTabs: Set<String> = []
    private(set) var claudePath: String = "claude"
    private var appearanceObservation: NSKeyValueObservation?

    private var keyMonitor: Any?

    override private init() {
        super.init()
        resolveClaudePath()
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshThemes() }
        }
        // Shift+Enter → ESC+CR (the Meta+Enter sequence), which Claude Code
        // treats as "insert newline" instead of "submit" — matching VS Code's
        // integrated-terminal behavior. Plain terminals can't distinguish
        // Shift+Enter from Enter, so this is intercepted at the event level.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 36,  // Return
               event.modifierFlags.contains(.shift),
               let terminal = NSApp.keyWindow?.firstResponder as? TerminalView {
                terminal.send(txt: "\u{1b}\r")
                return nil
            }
            return event
        }
    }

    /// Terminals whose process is still alive (used by quit protection).
    var runningCount: Int {
        terminals.keys.filter { !deadTabs.contains($0) }.count
    }

    private func resolveClaudePath() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            claudePath = found
            return
        }
        // Fall back to asking a login shell (covers nvm/volta/etc. installs)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            let path = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") && $0.hasSuffix("claude") }
            if let path { claudePath = path }
        }
    }

    func isRunning(_ tabID: String) -> Bool {
        terminals[tabID] != nil && !deadTabs.contains(tabID)
    }

    func isDead(_ tabID: String) -> Bool {
        deadTabs.contains(tabID)
    }

    func terminal(for tab: TerminalTab) -> LocalProcessTerminalView {
        if let existing = terminals[tab.id] { return existing }

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyTheme(to: view)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        if let sessionID = tab.resumeSessionID {
            let command = "cd \(ClaudeSession.shellQuote(tab.cwd)) && exec \(ClaudeSession.shellQuote(claudePath)) --resume \(ClaudeSession.shellQuote(sessionID))"
            view.startProcess(
                executable: "/bin/zsh",
                args: ["-l", "-c", command],
                environment: envArray,
                execName: nil
            )
        } else {
            // Plain interactive shell in the tab's folder (⌘T)
            view.startProcess(
                executable: "/bin/zsh",
                args: ["-i", "-l"],
                environment: envArray,
                execName: nil,
                currentDirectory: tab.cwd
            )
        }

        deadTabs.remove(tab.id)
        terminals[tab.id] = view
        return view
    }

    /// Restart a tab whose process ended.
    func relaunch(_ tab: TerminalTab) {
        terminals.removeValue(forKey: tab.id)
        deadTabs.remove(tab.id)
        generation += 1
    }

    func closeTerminal(for tabID: String) {
        if let view = terminals.removeValue(forKey: tabID), !deadTabs.contains(tabID) {
            view.terminate()
        }
        deadTabs.remove(tabID)
        generation += 1
    }

    // MARK: - Theme (follows system appearance)

    static var isDarkMode: Bool {
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Matches the dark terminal background (#1E1E1E) / plain white in light mode.
    static var terminalBackground: NSColor {
        isDarkMode ? NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1) : .white
    }

    private func applyTheme(to view: LocalProcessTerminalView) {
        let dark = Self.isDarkMode
        view.nativeBackgroundColor = Self.terminalBackground
        view.nativeForegroundColor = dark
            ? NSColor(calibratedWhite: 0.87, alpha: 1)
            : NSColor(calibratedWhite: 0.13, alpha: 1)
        view.caretColor = NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.16, alpha: 1)
        view.selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
        view.installColors(dark ? Self.darkAnsiPalette : Self.lightAnsiPalette)
    }

    /// Re-theme cached terminals when the system appearance flips.
    private func refreshThemes() {
        for view in terminals.values {
            applyTheme(to: view)
            view.needsDisplay = true
        }
        generation += 1
    }

    /// ANSI 16-color palette tuned for a white background
    /// (dim enough to stay readable on white, based on Tango/Terminal.app light).
    private static let lightAnsiPalette: [SwiftTerm.Color] = [
        rgb(0x00, 0x00, 0x00), // black
        rgb(0xC2, 0x36, 0x21), // red
        rgb(0x1A, 0x92, 0x1C), // green
        rgb(0xA1, 0x6A, 0x00), // yellow -> dark amber
        rgb(0x20, 0x53, 0xB3), // blue
        rgb(0xA6, 0x38, 0xA6), // magenta
        rgb(0x0E, 0x84, 0x8A), // cyan
        rgb(0x8E, 0x8E, 0x93), // white -> light grey
        rgb(0x5A, 0x5A, 0x5A), // bright black
        rgb(0xE3, 0x4F, 0x3B), // bright red
        rgb(0x2E, 0xA4, 0x30), // bright green
        rgb(0xB8, 0x86, 0x0B), // bright yellow
        rgb(0x3B, 0x74, 0xD9), // bright blue
        rgb(0xC5, 0x4F, 0xC5), // bright magenta
        rgb(0x17, 0xA2, 0xA9), // bright cyan
        rgb(0x3C, 0x3C, 0x3C), // bright white -> near black (bold text on white)
    ]

    /// ANSI 16-color palette for the dark background (VS Code dark terminal).
    private static let darkAnsiPalette: [SwiftTerm.Color] = [
        rgb(0x3C, 0x3C, 0x3C), // black (visible on #1E1E1E)
        rgb(0xCD, 0x31, 0x31), // red
        rgb(0x0D, 0xBC, 0x79), // green
        rgb(0xE5, 0xE5, 0x10), // yellow
        rgb(0x24, 0x72, 0xC8), // blue
        rgb(0xBC, 0x3F, 0xBC), // magenta
        rgb(0x11, 0xA8, 0xCD), // cyan
        rgb(0xE5, 0xE5, 0xE5), // white
        rgb(0x66, 0x66, 0x66), // bright black
        rgb(0xF1, 0x4C, 0x4C), // bright red
        rgb(0x23, 0xD1, 0x8B), // bright green
        rgb(0xF5, 0xF5, 0x43), // bright yellow
        rgb(0x3B, 0x8E, 0xEA), // bright blue
        rgb(0xD6, 0x70, 0xD6), // bright magenta
        rgb(0x29, 0xB8, 0xDB), // bright cyan
        rgb(0xFF, 0xFF, 0xFF), // bright white
    ]

    private static func rgb(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}

extension TerminalManager: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            source.getTerminal().feed(
                text: "\r\n\u{1b}[90m── session ended (exit \(exitCode.map(String.init) ?? "?")) — ↻ on the tab restarts it ──\u{1b}[0m\r\n"
            )
            if let key = self.terminals.first(where: { $0.value === source })?.key {
                self.deadTabs.insert(key)
                self.generation += 1
            }
        }
    }
}
