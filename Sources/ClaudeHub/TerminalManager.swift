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
    /// The saved account each live terminal was actually launched with (nil =
    /// the signed-in one). A tab keeps the account it started on, so this is
    /// the only honest answer to "what am I burning limits on in this tab".
    private var launchedProfile: [String: String] = [:]
    /// Tabs that wanted a saved account but had to start on the signed-in one
    /// because its token could not be read. Silent fallback is what makes
    /// account switching look broken, so it is remembered and shown.
    private var fellBack: [String: String] = [:]
    /// Text that was typed but not sent when a tab was restarted, waiting for
    /// the new session to be ready to take it back.
    private var pendingDrafts: [String: String] = [:]
    /// Tabs that were busy when the account changed: they finish what they are
    /// doing first and move over after. Never interrupted mid-answer.
    private var deferredSwitches: [String: (tab: TerminalTab, account: String)] = [:]
    /// Tabs whose process has exited; their view stays (showing the exit
    /// message) until the tab is closed or explicitly restarted.
    private var deadTabs: Set<String> = []
    private(set) var claudePath: String = "claude"
    private var appearanceObservation: NSKeyValueObservation?

    private var keyMonitor: Any?

    /// Terminal text size, shared by every tab and remembered across launches.
    @Published private(set) var fontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "terminalFontSize")
        return (8.0...32.0).contains(stored) ? CGFloat(stored) : 12
    }()

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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 36,  // Return
               event.modifierFlags.contains(.shift),
               let terminal = NSApp.keyWindow?.firstResponder as? TerminalView {
                terminal.send(txt: "\u{1b}\r")
                return nil
            }
            // ⌘= is what most keyboards give for "bigger" without reaching for
            // shift; the menu item binds ⌘+ for the same action.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "=" {
                self?.changeFontSize(by: 1)
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
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        applyTheme(to: view)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // A profile tab runs as its own account: the CLI reads this instead of
        // the signed-in credentials, which is what lets two tabs use two
        // accounts at the same time.
        launchedProfile[tab.id] = nil
        fellBack[tab.id] = nil
        // Deliberately the cached token only: a keychain panel here would
        // freeze the app mid-layout, and a session that quietly starts on the
        // wrong account is worse than one that starts late.
        if !tab.pinnedToSignedIn,
           let profile = tab.profile ?? TokenStore.activeProfile,
           let token = TokenStore.cachedToken(for: profile) {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            launchedProfile[tab.id] = profile
        } else if !tab.pinnedToSignedIn,
                  let wanted = tab.profile ?? TokenStore.activeProfile {
            fellBack[tab.id] = wanted
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        switch tab.kind {
        case .resume(let sessionID):
            start(view, envArray, "exec \(ClaudeSession.shellQuote(claudePath)) --resume \(ClaudeSession.shellQuote(sessionID))", in: tab.cwd)
        case .newSession(let sessionID):
            // ⌘N — a fresh Claude session in the tab's folder, under the id the
            // tab was opened with, so the sidebar row and this tab are the same
            // session from the start. Restarting a tab that already has a
            // transcript resumes it: --session-id refuses an id that is taken.
            let flag = Self.transcriptExists(sessionID) ? "--resume" : "--session-id"
            start(view, envArray,
                  "exec \(ClaudeSession.shellQuote(claudePath)) \(flag) \(ClaudeSession.shellQuote(sessionID))",
                  in: tab.cwd)
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

    /// Whether Claude Code has already written a transcript for this session.
    /// The project folder is derived from the cwd by a scheme we would rather
    /// not reimplement, so this just looks for the file across all of them.
    private static func transcriptExists(_ sessionID: String) -> Bool {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        return dirs.contains {
            fm.fileExists(atPath: $0.appendingPathComponent("\(sessionID).jsonl").path)
        }
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

    /// The account this tab runs as: the one it launched with once it is
    /// running, the one it would launch with before that.
    func profile(of tab: TerminalTab) -> String? {
        if terminals[tab.id] != nil { return launchedProfile[tab.id] }
        if tab.pinnedToSignedIn { return nil }
        return tab.profile ?? TokenStore.activeProfile
    }

    /// Whether the tab is already running, so its account is settled rather
    /// than a prediction.
    func hasLaunched(_ tabID: String) -> Bool { terminals[tabID] != nil }

    /// The saved account this tab was meant to run as but could not.
    func fallbackAccount(of tabID: String) -> String? { fellBack[tabID] }

    /// Restart a tab, whether its process ended or is still running.
    ///
    /// A live process is stopped first: dropping the reference would leave it
    /// running on the old account, still holding that token, invisible.
    func relaunch(_ tab: TerminalTab) {
        if let view = terminals.removeValue(forKey: tab.id), !deadTabs.contains(tab.id) {
            // Switching account restarts the session; what you were halfway
            // through typing should survive that.
            if let draft = Self.draft(in: Self.visibleText(of: view)) {
                pendingDrafts[tab.id] = draft
            }
            view.terminate()
        }
        launchedProfile[tab.id] = nil
        fellBack[tab.id] = nil
        deadTabs.remove(tab.id)
        generation += 1
    }

    /// Moves every open conversation onto the account that is active now.
    ///
    /// Switching account used to apply only to what you opened next, which
    /// meant the window could show four tabs under one account label while
    /// three of them ran as somebody else. A conversation survives this: it
    /// resumes from its transcript, on the new account. Shells and one-shot
    /// `claude auth` tabs are left alone — restarting those would throw away
    /// what you were doing in them, and they are not conversations.
    ///
    /// Only the visible tab starts again immediately; the rest start as you
    /// come back to them, which is also when they would have cost anything.
    @discardableResult
    func restartConversations(_ tabs: [TerminalTab]) -> Int {
        let target = TokenStore.activeProfile ?? "the signed-in account"
        var moved = 0
        for tab in tabs where tab.isConversation {
            // A session that is working, or waiting for you to answer a
            // permission prompt, is not something to kill: it finishes, then
            // moves. Anything idle goes now.
            if activity(of: tab.id) == .idle || activity(of: tab.id) == .stopped {
                relaunch(tab)
                moved += 1
            } else {
                deferredSwitches[tab.id] = (tab, target)
            }
        }
        return moved
    }

    /// The account a tab will move to once it is done, if it was busy when you
    /// switched.
    func pendingSwitch(of tabID: String) -> String? {
        deferredSwitches[tabID]?.account
    }

    /// Moves the tabs that were busy when the account changed, now that they
    /// are not.
    private func applyDeferredSwitches() {
        guard !deferredSwitches.isEmpty else { return }
        for (id, pending) in deferredSwitches {
            guard terminals[id] != nil else {
                deferredSwitches[id] = nil
                continue
            }
            guard activity(of: id) == .idle else { continue }
            deferredSwitches[id] = nil
            relaunch(pending.tab)
        }
    }

    func closeTerminal(for tabID: String) {
        if let view = terminals.removeValue(forKey: tabID), !deadTabs.contains(tabID) {
            view.terminate()
        }
        launchedProfile[tabID] = nil
        fellBack[tabID] = nil
        pendingDrafts[tabID] = nil
        deferredSwitches[tabID] = nil
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
        applyDeferredSwitches()
        restoreDrafts()
        if next.values.contains(where: \.pulses) {
            pulse.toggle()
        } else if pulse {
            pulse = false
        }
    }

    /// Types a kept draft back in, once the new session has an empty prompt to
    /// take it — sending it earlier is how a keystroke gets swallowed by a
    /// session that is still starting.
    private func restoreDrafts() {
        guard !pendingDrafts.isEmpty else { return }
        for (id, draft) in pendingDrafts {
            guard let view = terminals[id], !deadTabs.contains(id) else { continue }
            guard Self.promptIsEmpty(Self.visibleText(of: view)) else { continue }
            view.send(txt: draft)
            pendingDrafts[id] = nil
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

    /// The login URL a `claude auth` tab prints, rejoined.
    ///
    /// The terminal hard-wraps it across three lines with no hyphen, and
    /// cmd-clicking it just opens the browser — so this stitches the pieces
    /// back together for the clipboard. Continuation lines are the ones with
    /// no spaces in them.
    func signInURL(in tabID: String) -> String? {
        guard let view = terminals[tabID] else { return nil }
        let lines = Self.visibleText(of: view)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let index = lines.lastIndex(where: { $0.contains("https://") }),
              let start = lines[index].range(of: "https://") else { return nil }

        var url = String(lines[index][start.lowerBound...]).trimmingCharacters(in: .whitespaces)
        var next = index + 1
        while next < lines.count {
            let line = lines[next].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" ") else { break }
            url += line
            next += 1
        }
        return url.count > 30 ? url : nil
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

    /// The prompt renders as `❯ …`, or as `│ > …` inside a box in older
    /// versions. Returns where it is and what is on it.
    private static func promptLine(_ screen: String) -> (index: Int, text: String, lines: [String])? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices.reversed() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let unboxed = trimmed.hasPrefix("\u{2502}")     // │
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                : trimmed
            guard unboxed.hasPrefix("\u{276F}") || unboxed.hasPrefix(">") else { continue }  // ❯
            let text = unboxed.dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{2502}"))
            return (index, text, lines)
        }
        return nil
    }

    /// The hint an empty prompt shows — `Try "write a test for <filepath>"` —
    /// which is on screen but is not something anybody typed.
    private static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("Try \"") || text.hasPrefix("Try \u{201C}")
    }

    /// An empty prompt has nothing on it but the hint. Anything we cannot read
    /// confidently counts as "not empty".
    private static func promptIsEmpty(_ screen: String) -> Bool {
        guard let prompt = promptLine(screen) else { return false }
        return prompt.text.isEmpty || isPlaceholder(prompt.text)
    }

    /// What has been typed into the prompt but not sent yet.
    ///
    /// Long input wraps onto the lines under the caret, so those are taken too,
    /// up to the frame the session draws under its input. Where the wrap fell
    /// is not recoverable from the screen, so the pieces are rejoined with a
    /// space: the words come back, and a rewrapped sentence is a far better
    /// outcome than an empty box.
    static func draft(in screen: String) -> String? {
        guard let prompt = promptLine(screen),
              !prompt.text.isEmpty, !isPlaceholder(prompt.text) else { return nil }

        var parts = [prompt.text]
        for line in prompt.lines.dropFirst(prompt.index + 1) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \u{2502}"))
            guard !trimmed.isEmpty, !isFrame(trimmed) else { break }
            parts.append(trimmed)
        }
        let text = parts.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The rules, status line and hints drawn under the input box.
    private static func isFrame(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        return "\u{2500}\u{256D}\u{2570}\u{23F5}\u{26A0}?".contains(first)   // ─ ╭ ╰ ⏵ ⚠ ?
    }

    // MARK: - Text size

    func changeFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }

    func resetFontSize() { setFontSize(12) }

    private func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 8), 32)
        guard clamped != fontSize else { return }
        fontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "terminalFontSize")

        let font = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        for view in terminals.values {
            view.font = font
            view.needsLayout = true
            view.needsDisplay = true
        }
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
