import AppKit
import Combine
import SwiftTerm

/// One rate-limit window as `/usage` reports it.
struct UsageWindow: Equatable {
    let percent: Int
    let resets: String
    let resetsAt: Date?

    var level: Int { percent >= 85 ? 2 : (percent >= 60 ? 1 : 0) }

    /// "Resets in 1 hr 47 min", recomputed as the clock ticks.
    func countdown(from now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "Resets in \(days) d \(hours) hr" }
        if hours > 0 { return "Resets in \(hours) hr \(minutes) min" }
        if minutes > 0 { return "Resets in \(minutes) min" }
        return "Resets in under a minute"
    }
}

/// Keeps the 5-hour and weekly limits on screen, close to live.
///
/// Claude Code keeps no local record of these numbers — they come off the API
/// as it works — so the only way to read them without touching credentials is
/// to ask a `claude` session the same question you would: `/usage`.
///
/// One hidden session is kept warm and asked again each minute, rather than
/// booting a fresh one every time: starting Claude costs seconds, asking an
/// already-running one costs about one. It runs no prompt, so it leaves no
/// transcript behind and costs nothing.
final class UsageStore: ObservableObject {
    @Published private(set) var session: UsageWindow?
    @Published private(set) var week: UsageWindow?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isProbing = false
    @Published private(set) var errorMessage: String?

    private var folder: () -> String? = { nil }
    private var probe: LocalProcessTerminalView?
    private var timer: Timer?
    private var retries = 0

    private let interval: TimeInterval = 60

    deinit { probe?.terminate() }

    /// Starts the first read once sessions are known, then every minute.
    func startPolling(folder: @escaping () -> String?) {
        guard timer == nil else { return }
        self.folder = folder
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh()
        }
    }

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > interval * 2
    }

    func refresh() {
        guard !isProbing else { return }
        guard let cwd = folder() else {
            // The first scan may not have landed yet; keep trying briefly
            // rather than going quiet until the next tick.
            guard retries < 15 else { return }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refresh()
            }
            return
        }
        retries = 0
        isProbing = true

        if probe == nil {
            startProbe(in: cwd)
            // The prompt box is not reliably detectable on an off-screen
            // terminal, so this waits out the boot rather than watching for it.
            // Only the first read pays it; later ones reuse the warm session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                self?.ask()
            }
        } else {
            ask()
        }
    }

    // MARK: - The hidden session

    /// Runs in a folder Claude Code already trusts, or it would stop on the
    /// trust prompt instead of answering.
    private func startProbe(in cwd: String) {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        probe = view

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if let profile = TokenStore.activeProfile, let token = TokenStore.token(for: profile) {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }

        let claude = TerminalManager.shared.claudePath
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "cd \(ClaudeSession.shellQuote(cwd)) && exec \(ClaudeSession.shellQuote(claude))"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil
        )
    }

    /// Escape closes a panel left open by the previous read, so `/usage` draws
    /// a fresh one rather than typing into whatever is on screen.
    private func ask() {
        guard let view = probe else { return fail("The usage probe stopped.") }
        view.send(txt: "\u{1b}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let view = self.probe else { return }
            view.send(txt: "/usage\r")
            self.readPanel(until: Date().addingTimeInterval(15))
        }
    }

    private func readPanel(until deadline: Date) {
        guard let view = probe else { return fail("The usage probe stopped.") }
        let parsed = Self.parse(Self.screenText(of: view))
        if parsed.session != nil || parsed.week != nil {
            session = parsed.session
            week = parsed.week
            lastUpdated = Date()
            errorMessage = nil
            isProbing = false
            return
        }
        guard Date() < deadline else {
            // A wedged session is worse than none: drop it and start over next tick.
            teardown()
            return fail("Could not read /usage. Is `claude` signed in?")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.readPanel(until: deadline)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        isProbing = false
    }

    private func teardown() {
        probe?.terminate()
        probe = nil
    }

    /// A different account has different limits, so the warm session is no
    /// longer the one to ask.
    func accountChanged() {
        teardown()
        session = nil
        week = nil
        lastUpdated = nil
        isProbing = false
        refresh()
    }

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

    /// The panel writes a reset either as a bare "9:29pm" (the 5-hour window)
    /// or as "Aug 29 at 4:59pm" (the weekly one). Both become a real date so
    /// either can be counted down to.
    private static func resetDate(from text: String, now: Date = Date()) -> Date? {
        // en_US_POSIX wants "PM", the panel prints "pm". Month names are safe:
        // none of them contain "am" or "pm".
        let normalized = text
            .replacingOccurrences(of: "pm", with: "PM", options: .caseInsensitive)
            .replacingOccurrences(of: "am", with: "AM", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in ["MMM d 'at' h:mmA", "MMM d 'at' hA", "MMM d 'at' h:mma", "MMM d 'at' ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: normalized) else { continue }
            let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            var target = DateComponents()
            target.year = calendar.component(.year, from: now)
            target.month = parts.month
            target.day = parts.day
            target.hour = parts.hour
            target.minute = parts.minute
            guard let date = calendar.date(from: target) else { continue }
            // A reset in early January read on New Year's Eve belongs to next year.
            if date.timeIntervalSince(now) < -2 * 86_400 {
                return calendar.date(byAdding: .year, value: 1, to: date)
            }
            return date
        }

        for format in ["h:mmA", "hA", "h:mma", "ha"] {
            formatter.dateFormat = format
            guard let time = formatter.date(from: normalized) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            guard let today = calendar.date(bySettingHour: parts.hour ?? 0,
                                            minute: parts.minute ?? 0,
                                            second: 0,
                                            of: now) else { continue }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        return nil
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
