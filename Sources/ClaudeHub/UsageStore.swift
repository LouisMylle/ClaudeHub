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
    /// This account simply has no limits to report — not a failure to retry.
    @Published private(set) var limitsUnavailable = false
    /// Whose numbers are on screen. Shown, always: an unlabelled percentage is
    /// how one account's usage gets read as another's.
    @Published private(set) var measuredAccount: String?

    private var folder: () -> String? = { nil }
    private var probe: LocalProcessTerminalView?
    /// The saved account the running probe was started for, so a failure can
    /// name it instead of blaming "claude".
    private(set) var probeAccount: String?
    private var timer: Timer?
    private var retries = 0
    /// The API reading costs a real (one-token) request, so it is not asked
    /// every minute like the free screen-reading was.
    private var lastAPIPoll: Date?
    private var forceNextPoll = false
    private let apiInterval: TimeInterval = 180
    /// Bumped whenever the probe is thrown away (a switch, a timeout), so the
    /// read loop of the old session cannot tear down or answer for the new one.
    private var generation = 0

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

    /// Whose limits these are — named, always. The whole confusion this guards
    /// against is a percentage that belongs to another account.
    var accountLabel: String {
        let account = lastUpdated != nil ? measuredAccount : TokenStore.activeProfile
        return account ?? "the signed-in account"
    }

    func refresh() {
        guard !isProbing else { return }
        // Asked and answered; a switch or the ↻ button clears this.
        guard !limitsUnavailable else { return }
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
        // Numbers read on the wrong credential are worse than no numbers: they
        // are another account's limits under this account's name. If the active
        // account's token is not in hand yet, wait for it rather than starting
        // a session that would quietly run as whoever is signed in.
        if let profile = TokenStore.activeProfile,
           TokenStore.cachedToken(for: profile) == nil {
            guard retries < 15 else {
                return fail(TokenStore.blockedReason(for: profile)
                    ?? "Waiting for \(profile)'s token to be readable.")
            }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refresh()
            }
            return
        }
        retries = 0
        isProbing = true

        // A token account is not told its limits by the CLI, but the API states
        // them in the headers of any request. Ask there first; the hidden
        // session is the fallback, not the other way round.
        if let profile = TokenStore.activeProfile,
           let token = TokenStore.cachedToken(for: profile) {
            if !forceNextPoll, let last = lastAPIPoll, session != nil || week != nil,
               Date().timeIntervalSince(last) < apiInterval {
                isProbing = false
                return
            }
            forceNextPoll = false
            lastAPIPoll = Date()
            probeAccount = profile
            let era = generation
            TokenCheck.limits(token: token) { [weak self] headers in
                guard let self, self.generation == era else { return }
                let windows = Self.windows(from: headers)
                guard windows.session != nil || windows.week != nil else {
                    return self.startTerminalProbe(in: cwd)
                }
                self.session = windows.session
                self.week = windows.week
                self.lastUpdated = Date()
                self.measuredAccount = profile
                self.errorMessage = nil
                self.limitsUnavailable = false
                self.isProbing = false
            }
            return
        }

        startTerminalProbe(in: cwd)
    }

    /// Reads the limits the way a person would: by looking at `/usage`.
    private func startTerminalProbe(in cwd: String) {
        isProbing = true
        if probe == nil {
            startProbe(in: cwd)
            // Claude Code takes anywhere from a few seconds to half a minute to
            // draw its prompt, and typing `/usage` before then goes nowhere —
            // which is exactly what a fixed delay used to do on a slow start.
            waitForPrompt(era: generation, until: Date().addingTimeInterval(45))
        } else {
            ask()
        }
    }

    // MARK: - Limits as the API states them

    /// The API states these as
    /// `anthropic-ratelimit-unified-5h-utilization: 0.04` and
    /// `-7d-utilization`, with resets as epoch seconds.
    ///
    /// Builds the two windows out of whatever the rate-limit headers are
    /// called. The names are not something to depend on, so this matches on
    /// what they mean — a five-hour bucket, a weekly one, how much is left and
    /// when it comes back — and returns nothing rather than a guess.
    static func windows(from headers: [String: String]) -> (session: UsageWindow?, week: UsageWindow?) {
        let week = window(in: headers, matching: ["7d", "week", "weekly"])
        let session = window(in: headers, matching: ["5h", "five_hour", "fivehour", "session"])
            // Only if the five-hour headers ever stop being sent. Overage and
            // fallback are their own numbers — 17% of an overage budget is not
            // 17% of a session — so they are kept out of it.
            ?? window(in: headers.filter {
                        !$0.key.contains("7d") && !$0.key.contains("week")
                            && !$0.key.contains("overage") && !$0.key.contains("fallback")
                      },
                      matching: ["unified"])
        return (session, week)
    }

    private static func window(in headers: [String: String], matching keys: [String]) -> UsageWindow? {
        func value(_ suffixes: [String]) -> String? {
            headers.first { name, _ in
                keys.contains(where: name.contains) && suffixes.contains(where: name.hasSuffix)
            }?.value
        }

        let reset = value(["reset", "resets", "reset-at"]).flatMap(parseDate)
        var percent: Int?
        if let used = value(["utilization", "utilisation", "used", "percent",
                             "percent-used", "usage"]).flatMap(Double.init) {
            // Some APIs state utilization as a fraction, some as a percentage.
            percent = Int((used <= 1 ? used * 100 : used).rounded())
        } else if let limit = value(["limit"]).flatMap(Double.init),
                  let remaining = value(["remaining"]).flatMap(Double.init), limit > 0 {
            percent = Int(((1 - remaining / limit) * 100).rounded())
        }
        guard let percent else { return nil }
        return UsageWindow(percent: min(max(percent, 0), 100),
                           resets: reset.map(describe) ?? "",
                           resetsAt: reset)
    }

    /// Headers date things as ISO 8601, as epoch seconds, or as seconds from
    /// now, depending on the header.
    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        guard let number = Double(text) else { return nil }
        // Anything past the year 2001 is a timestamp; anything smaller is a
        // duration.
        return number > 1_000_000_000
            ? Date(timeIntervalSince1970: number)
            : Date().addingTimeInterval(number)
    }

    private static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).lowercased()
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
        if let profile = TokenStore.activeProfile,
           let token = TokenStore.cachedToken(for: profile) {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            probeAccount = profile
        } else {
            probeAccount = nil
        }

        let claude = TerminalManager.shared.claudePath
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "cd \(ClaudeSession.shellQuote(cwd)) && exec \(ClaudeSession.shellQuote(claude))"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil
        )
    }

    /// Polls until the session has drawn its input box, then asks.
    private func waitForPrompt(era: Int, until deadline: Date) {
        guard generation == era else { return }
        guard let view = probe else { return fail("The usage probe stopped.") }
        let screen = Self.screenText(of: view)

        if let refusal = Self.authFailure(in: screen) {
            teardown()
            return fail(refusal)
        }
        if Self.isReady(screen) { return ask() }
        guard Date() < deadline else {
            let seen = Self.tail(of: screen)
            teardown()
            return fail(seen.isEmpty
                ? "The hidden session never finished starting."
                : "The hidden session never showed its prompt. It was showing: \(seen)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForPrompt(era: era, until: deadline)
        }
    }

    /// The input box Claude Code draws once it is ready for typing.
    private static func isReady(_ screen: String) -> Bool {
        screen.contains("\u{276F}")            // ❯
            || screen.contains("\u{2502} >")   // │ >
            || screen.contains("shortcuts")
    }

    /// Escape closes a panel left open by the previous read, so `/usage` draws
    /// a fresh one rather than typing into whatever is on screen.
    private func ask() {
        guard let view = probe else { return fail("The usage probe stopped.") }
        let era = generation
        view.send(txt: "\u{1b}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == era, let view = self.probe else { return }
            view.send(txt: "/usage\r")
            self.readPanel(until: Date().addingTimeInterval(20), era: era, resent: false)
        }
    }

    private func readPanel(until deadline: Date, era: Int, resent: Bool) {
        guard generation == era else { return }
        guard let view = probe else { return fail("The usage probe stopped.") }
        let screen = Self.screenText(of: view)

        // An account whose token no longer authenticates never reaches the
        // panel — it says so on the first line. Repeating that is far more use
        // than "could not read /usage".
        if let refusal = Self.authFailure(in: screen) {
            teardown()
            return fail(refusal)
        }

        // The panel is up but has no limit windows: Claude Code runs a
        // token-authenticated session as "Claude API", and only a subscription
        // login is told about its 5-hour and weekly windows. That is a settled
        // answer — stop asking every minute and say so.
        if Self.panelWithoutLimits(screen) {
            Self.log(screen)
            teardown()
            session = nil
            week = nil
            lastUpdated = Date()
            measuredAccount = probeAccount
            isProbing = false
            limitsUnavailable = true
            errorMessage = probeAccount.map {
                """
                Claude Code does not report the 5-hour and weekly limits for \($0): \
                a saved token authenticates as "Claude API", and only the account \
                you are signed in as is told about its subscription windows. \
                Switch to the signed-in account to see limits again.
                """
            } ?? "This account reports no usage limits."
            return
        }

        let parsed = Self.parse(screen)
        if parsed.session != nil || parsed.week != nil {
            session = parsed.session
            week = parsed.week
            lastUpdated = Date()
            errorMessage = nil
            limitsUnavailable = false
            measuredAccount = probeAccount
            isProbing = false
            return
        }
        guard Date() < deadline else {
            // A wedged session is worse than none: drop it and start over next
            // tick — but say what was on screen instead of it. "Could not read
            // /usage" is unfalsifiable; the session's own last words are not.
            let seen = Self.tail(of: screen)
            Self.log(screen)
            teardown()
            return fail(seen.isEmpty
                ? "Could not read /usage — the hidden session never showed the panel."
                : "Could not read /usage. The hidden session was showing: \(seen)")
        }
        // Half way through, try once more: a keystroke can land while the
        // session is still painting and be swallowed.
        if !resent, Date().timeIntervalSince(deadline) > -10 {
            probe?.send(txt: "/usage\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.readPanel(until: deadline, era: era, resent: true)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.readPanel(until: deadline, era: era, resent: resent)
        }
    }

    /// A failed read is worth keeping in full: the footer has room for one
    /// line, and the answer is usually further up the screen.
    private static func log(_ screen: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeHub")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("usage-probe.log")
        let entry = """

            ===== \(Date()) =====
            \(screen)

            """
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// The last few things the hidden session had on screen, for an error
    /// message that can actually be acted on.
    private static func tail(of screen: String, lines limit: Int = 3) -> String {
        let lines = screen
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(limit)
        let text = lines.joined(separator: " / ")
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    /// The Usage tab, fully drawn, with neither limit window in it.
    private static func panelWithoutLimits(_ screen: String) -> Bool {
        screen.contains("What's contributing to your limits usage?")
            && !screen.contains("Current session")
            && !screen.contains("Current week")
    }

    /// The CLI's own wording when credentials are refused.
    private static func authFailure(in screen: String) -> String? {
        for marker in ["Failed to authenticate",
                       "OAuth access token is invalid",
                       "Invalid API key",
                       "authentication_error",
                       "scope requirement"] where screen.contains(marker) {
            let line = screen.split(separator: "\n")
                .first { $0.contains(marker) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return line ?? marker
        }
        return nil
    }

    private func fail(_ message: String) {
        errorMessage = probeAccount.map { "\($0): \(message)" } ?? message
        isProbing = false
    }

    private func teardown() {
        generation += 1
        probe?.terminate()
        probe = nil
    }

    /// A different account has different limits, so the warm session is no
    /// longer the one to ask.
    func accountChanged() {
        teardown()
        retries = 0
        forceNextPoll = true
        lastAPIPoll = nil
        session = nil
        week = nil
        lastUpdated = nil
        measuredAccount = nil
        errorMessage = nil
        limitsUnavailable = false
        isProbing = false
        refresh()
    }

    /// The ↻ button: try again even for an account that said it has none.
    func refreshByHand() {
        limitsUnavailable = false
        errorMessage = nil
        retries = 0
        forceNextPoll = true
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
