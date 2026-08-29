import AppKit
import SwiftTerm

/// Keeps one live terminal per tab so switching in the sidebar
/// doesn't kill running Claude processes.
final class TerminalManager: NSObject, ObservableObject {
    static let shared = TerminalManager()

    /// Bumped when a process ends/restarts so views and status dots update.
    @Published private(set) var generation = 0

    /// What each tab's terminal is doing right now, refreshed on a timer by
    /// reading the visible screen — see `TerminalActivity`.
    @Published private(set) var activity: [String: TerminalActivity] = [:]
    /// Drives every pulsing dot from one clock: they breathe in step, and no
    /// row has to mutate its own state while the table is laying it out.
    @Published private(set) var pulse = false
    private var activityTimer: Timer?

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
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.pollActivity()
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
        // A profile tab runs as its own account: the CLI reads this instead of
        // the signed-in credentials, which is what lets two tabs use two
        // accounts at the same time.
        if let profile = tab.profile, let token = TokenStore.token(for: profile) {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        switch tab.kind {
        case .resume(let sessionID):
            start(view, envArray, "exec \(ClaudeSession.shellQuote(claudePath)) --resume \(ClaudeSession.shellQuote(sessionID))", in: tab.cwd)
        case .newSession:
            // ⌘N — a fresh Claude session in the tab's folder
            start(view, envArray, "exec \(ClaudeSession.shellQuote(claudePath))", in: tab.cwd)
        case .command(let args):
            // `claude auth login`, `auth logout` — the shell stays afterwards so
            // the result is still readable instead of the tab dropping dead.
            let command = ([claudePath] + args).map(ClaudeSession.shellQuote).joined(separator: " ")
            start(view, envArray, "\(command); echo; exec /bin/zsh -i -l", in: tab.cwd)
        case .shell:
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

    /// A login shell gives `claude` the same PATH the user's terminal has.
    private func start(_ view: LocalProcessTerminalView, _ env: [String], _ command: String, in cwd: String) {
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "cd \(ClaudeSession.shellQuote(cwd)) && \(command)"],
            environment: env,
            execName: nil
        )
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

    // MARK: - Activity

    func activity(of tabID: String) -> TerminalActivity {
        if deadTabs.contains(tabID) { return .dead }
        guard terminals[tabID] != nil else { return .stopped }
        return activity[tabID] ?? .idle
    }

    /// Claude Code has no machine-readable "am I busy" channel, so this reads
    /// what the session is showing: while it works it prints an
    /// "esc to interrupt" hint, and permission prompts ask "Do you want to …".
    private func pollActivity() {
        guard !terminals.isEmpty else {
            if !activity.isEmpty { activity = [:] }
            return
        }
        var next: [String: TerminalActivity] = [:]
        for (id, view) in terminals where !deadTabs.contains(id) {
            next[id] = Self.classify(Self.visibleText(of: view))
        }
        if next != activity { activity = next }
        if next.values.contains(where: \.pulses) {
            pulse.toggle()
        } else if pulse {
            pulse = false
        }
    }

    private static func classify(_ screen: String) -> TerminalActivity {
        if screen.contains("esc to interrupt") { return .busy }
        if screen.contains("Do you want to") { return .needsInput }
        return .idle
    }

    /// The rows currently on screen, lowest-cost snapshot SwiftTerm offers.
    private static func visibleText(of view: LocalProcessTerminalView) -> String {
        let terminal = view.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Slash commands

    /// Types a slash command into a session. Only presses Return when the
    /// prompt is provably empty — appending to half-typed text and submitting
    /// it would send the user's own words to Claude by accident.
    /// Returns whether it was submitted.
    @discardableResult
    func sendSlashCommand(_ command: String, to tabID: String) -> Bool {
        guard let view = terminals[tabID], !deadTabs.contains(tabID) else { return false }
        let submit = activity(of: tabID) == .idle
            && Self.promptIsEmpty(Self.visibleText(of: view))
        view.send(txt: submit ? command + "\r" : command)
        view.window?.makeFirstResponder(view)
        return submit
    }

    /// The prompt box renders as `│ > …`; an empty one has nothing after the
    /// caret. Anything we cannot read confidently counts as "not empty".
    private static func promptIsEmpty(_ screen: String) -> Bool {
        for line in screen.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let unboxed = trimmed.hasPrefix("\u{2502}")     // │
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                : trimmed
            guard unboxed.hasPrefix(">") else { continue }
            let rest = unboxed.dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{2502}"))
            return rest.isEmpty
        }
        return false
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
