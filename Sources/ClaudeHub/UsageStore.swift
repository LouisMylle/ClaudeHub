import AppKit
import Combine
import SwiftTerm

/// One rate-limit window as `/usage` reports it.
struct UsageWindow: Equatable {
    let percent: Int
    let resets: String
    /// Only the 5-hour window resets at a clock time we can count down to.
    let resetsAt: Date?

    var level: Int { percent >= 85 ? 2 : (percent >= 60 ? 1 : 0) }

    /// "Resets in 1 hr 47 min", recomputed as the clock ticks.
    func countdown(from now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "Resets in \(hours) hr \(minutes) min" }
        if minutes > 0 { return "Resets in \(minutes) min" }
        return "Resets in under a minute"
    }
}

/// Keeps the 5-hour and weekly limits on screen.
///
/// Claude Code keeps no local record of these numbers — they come off the API
/// as it works — so the only way to read them without touching credentials is
/// to ask a `claude` session the same question you would: `/usage`. A probe
/// session is started off-screen, asked, scraped and killed. It runs no prompt,
/// so it leaves no transcript behind.
final class UsageStore: ObservableObject {
    @Published private(set) var session: UsageWindow?
    @Published private(set) var week: UsageWindow?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isProbing = false
    @Published private(set) var errorMessage: String?

    /// Where the probe runs. A folder Claude Code already trusts, or it would
    /// stop on the trust prompt instead of answering.
    private var folder: () -> String? = { nil }

    private var probe: LocalProcessTerminalView?
    private var timer: Timer?
    private var deadline: DispatchWorkItem?
    private var retries = 0

    private let bootSeconds: TimeInterval = 8
    private let renderSeconds: TimeInterval = 7

    /// Starts the first probe once sessions are known, then every 10 minutes.
    func startPolling(folder: @escaping () -> String?) {
        guard timer == nil else { return }
        self.folder = folder
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh()
        }
    }

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > 900
    }

    func refresh() {
        guard !isProbing else { return }
        guard let cwd = folder() else {
            // The first scan may not have landed yet; keep trying briefly
            // rather than going quiet until the next 10-minute tick.
            guard retries < 15 else { return }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refresh()
            }
            return
        }
        retries = 0
        isProbing = true
        errorMessage = nil

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        probe = view

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        let claude = TerminalManager.shared.claudePath
        let command = "cd \(ClaudeSession.shellQuote(cwd)) && exec \(ClaudeSession.shellQuote(claude))"
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", command],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil
        )

        // Boot, ask, read, stop — with a hard deadline so a hung probe can
        // never leave a stray `claude` running.
        DispatchQueue.main.asyncAfter(deadline: .now() + bootSeconds) { [weak self] in
            guard let self, self.probe === view else { return }
            view.send(txt: "/usage\r")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + bootSeconds + renderSeconds) { [weak self] in
            guard let self, self.probe === view else { return }
            self.finish(reading: view)
        }
        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.probe === view else { return }
            self.finish(reading: view)
        }
        deadline = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + bootSeconds + renderSeconds + 10, execute: stop)
    }

    private func finish(reading view: LocalProcessTerminalView) {
        deadline?.cancel()
        deadline = nil
        probe = nil

        let screen = Self.screenText(of: view)
        view.terminate()

        let parsed = Self.parse(screen)
        isProbing = false
        if parsed.session == nil && parsed.week == nil {
            errorMessage = "Could not read /usage. Is `claude` signed in?"
            return
        }
        session = parsed.session
        week = parsed.week
        lastUpdated = Date()
        errorMessage = nil
    }

    /// The whole scrollback, not just the viewport: the panel can scroll off.
    private static func screenText(of view: LocalProcessTerminalView) -> String {
        let terminal = view.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// The panel renders as a header, a bar line ending in `75%used`, then
    /// `Resets 4:29pm (Europe/Brussels)`.
    static func parse(_ screen: String) -> (session: UsageWindow?, week: UsageWindow?) {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (window(after: "Current session", in: lines),
                window(after: "Current week", in: lines))
    }

    private static func window(after header: String, in lines: [String]) -> UsageWindow? {
        guard let start = lines.lastIndex(where: { $0.contains(header) }) else { return nil }
        var percent: Int?
        var resets: String?
        for line in lines[start...].prefix(5) {
            if percent == nil, let found = firstPercent(in: line) { percent = found }
            if resets == nil, let range = line.range(of: "Resets") {
                var text = String(line[range.lowerBound...])
                    .replacingOccurrences(of: "Resets", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // Drop the "(Europe/Brussels)" tail — it never changes and the
                // footer has no room for it.
                if let paren = text.firstIndex(of: "(") {
                    text = String(text[..<paren]).trimmingCharacters(in: .whitespaces)
                }
                resets = text
            }
            if percent != nil && resets != nil { break }
        }
        guard let percent else { return nil }
        let text = resets ?? ""
        return UsageWindow(percent: percent, resets: text, resetsAt: resetDate(from: text))
    }

    /// Turns a bare "9:29pm" into the next moment the clock reads that. The
    /// weekly window says "Aug 29 at 4:59pm" instead, which is left as text.
    private static func resetDate(from text: String, now: Date = Date()) -> Date? {
        let compact = text.replacingOccurrences(of: " ", with: "").uppercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mma"
        guard let time = formatter.date(from: compact) else { return nil }

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        guard let today = calendar.date(bySettingHour: parts.hour ?? 0,
                                        minute: parts.minute ?? 0,
                                        second: 0,
                                        of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static func firstPercent(in line: String) -> Int? {
        guard let range = line.range(of: "%") else { return nil }
        let digits = line[line.startIndex..<range.lowerBound]
            .reversed()
            .prefix { $0.isNumber }
            .reversed()
        guard !digits.isEmpty, let value = Int(String(digits)), value <= 100 else { return nil }
        return value
    }
}
