import AppKit
import SwiftTerm

/// What was pasted into a prompt, so a restarted session can be given it back.
///
/// Claude Code keeps pasted text and images in its own memory and shows only a
/// stand-in for them — `[Pasted text #12 +36 lines]`, `[Image #3]`. The screen
/// therefore cannot give the content back, which is why a tab holding one used
/// to sit still when you switched account: restarting it would have thrown the
/// content away and left the stand-in behind as if it were what you wrote.
///
/// So the paste is caught on its way in and kept here, keyed by the stand-in it
/// produced. A restart then replays it — the text as a paste, the image through
/// the clipboard, which is where Claude Code reads an image from. Anything not
/// remembered this way still holds the tab back, exactly as before: content is
/// never lost to a guess.
final class PasteMemory {
    static let shared = PasteMemory()

    /// A paste, in the form it has to go back in.
    enum Payload {
        case text(String)
        /// A PNG on disk. The clipboard is how Claude Code takes an image, and
        /// a file is what survives both a restart and this app going away.
        case image(URL)
    }

    /// One move in putting a prompt back together.
    enum Step {
        /// Typed in, as it was read off the screen.
        case text(String)
        /// Sent as a paste, so a long one becomes an attachment again instead
        /// of thirty lines of typing.
        case paste(String)
        /// Put on the clipboard and taken with ⌃V.
        case image(URL)
    }

    /// Stand-ins this tab's prompt can hold, and what each one really is.
    private var records: [String: [String: Payload]] = [:]
    /// Oldest first, so a tab that pastes all day does not grow without end.
    private var order: [String: [String]] = [:]

    private static let maxPerTab = 24
    /// Past this, a paste is left unremembered and the tab waits as it used to:
    /// holding tens of megabytes to save one restart is the worse trade.
    private static let maxText = 4 * 1024 * 1024
    /// And past this, the oldest go — a prompt cannot hold that many pastes at
    /// once anyway, so what is dropped is almost always long since sent.
    private static let maxTextPerTab = 16 * 1024 * 1024

    private let store: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        store = caches.appendingPathComponent("ClaudeHub/pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        pruneOldImages()
    }

    // MARK: - Catching a paste

    /// Watches for the stand-in this paste turns into, and remembers which one
    /// it was.
    ///
    /// Which stand-in a paste produced cannot be known when it is sent — the
    /// number is Claude Code's to hand out, and it appears a moment later. So
    /// the prompt is compared against itself: the one stand-in that is there
    /// afterwards and was not there before is this paste.
    func note(_ payload: Payload, pastedInto view: LocalProcessTerminalView, tab: String) {
        if case .text(let text) = payload, text.utf8.count > Self.maxText { return }
        let before = Self.standIns(of: view)
        look(for: payload, after: before, in: view, tab: tab, attempt: 0)
    }

    private func look(for payload: Payload,
                      after before: Set<String>,
                      in view: LocalProcessTerminalView,
                      tab: String,
                      attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.2 : 0.3)) { [weak view] in
            guard let view else { return }
            let new = Self.standIns(of: view).subtracting(before)
            if new.count == 1, let placeholder = new.first {
                self.bind(placeholder, to: payload, tab: tab)
                return
            }
            // Two at once means we cannot tell them apart, and none yet means
            // it may still be coming. Five looks covers a slow session; after
            // that the paste stays unremembered and the tab simply waits.
            guard new.isEmpty, attempt < 5 else { return }
            self.look(for: payload, after: before, in: view, tab: tab, attempt: attempt + 1)
        }
    }

    private func bind(_ placeholder: String, to payload: Payload, tab: String) {
        records[tab, default: [:]][placeholder] = payload
        var kept = (order[tab] ?? []).filter { $0 != placeholder }
        kept.append(placeholder)
        while kept.count > Self.maxPerTab || bytes(of: kept, tab: tab) > Self.maxTextPerTab {
            let dropped = kept.removeFirst()
            if case .image(let file)? = records[tab]?[dropped] {
                try? FileManager.default.removeItem(at: file)
            }
            records[tab]?[dropped] = nil
            if kept.isEmpty { break }
        }
        order[tab] = kept
    }

    private func bytes(of placeholders: [String], tab: String) -> Int {
        placeholders.reduce(0) { total, placeholder in
            guard case .text(let text)? = records[tab]?[placeholder] else { return total }
            return total + text.utf8.count
        }
    }

    /// The stand-ins in a tab's prompt die with the session that numbered them.
    /// The files behind them do not: a restart is still holding those.
    func forget(tab: String, deletingImages: Bool) {
        if deletingImages {
            for placeholder in order[tab] ?? [] {
                if case .image(let file)? = records[tab]?[placeholder] {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        records[tab] = nil
        order[tab] = nil
    }

    // MARK: - Putting a prompt back

    /// The draft as the moves that rebuild it, or nil when something in it
    /// cannot be reproduced — in which case the tab waits instead.
    func plan(for draft: String, tab: String) -> [Step]? {
        let known = records[tab] ?? [:]
        var steps: [Step] = []
        var cursor = draft.startIndex

        for range in Self.standInRanges(in: draft) {
            let literal = String(draft[cursor..<range.lowerBound])
            guard !Self.looksLikeStandIn(literal) else { return nil }
            if !literal.isEmpty { steps.append(.text(literal)) }

            guard let payload = known[String(draft[range])] else { return nil }
            switch payload {
            case .text(let text):
                steps.append(.paste(text))
            case .image(let file):
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                steps.append(.image(file))
            }
            cursor = range.upperBound
        }

        let tail = String(draft[cursor...])
        guard !Self.looksLikeStandIn(tail) else { return nil }
        if !tail.isEmpty { steps.append(.text(tail)) }
        return steps
    }

    // MARK: - Images

    /// Keeps a copy of whatever image is on the clipboard, as a PNG.
    ///
    /// ⌃V hands Claude Code nothing but the keystroke — it goes and reads the
    /// clipboard itself — so this moment is the only chance to keep the image.
    func keepClipboardImage() -> URL? {
        guard let png = Self.clipboardPNG() else { return nil }
        let file = store.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return file
    }

    /// Whether the clipboard holds an image at all, without copying it.
    static func clipboardHasImage() -> Bool {
        let board = NSPasteboard.general
        if board.data(forType: .png) != nil || board.data(forType: .tiff) != nil { return true }
        return imageFile(on: board) != nil
    }

    private static func clipboardPNG() -> Data? {
        let board = NSPasteboard.general
        if let data = board.data(forType: .png) { return data }
        if let tiff = board.data(forType: .tiff) { return png(fromImageData: tiff) }
        // A file copied in Finder: Claude Code reads that too, so it is the
        // same kind of paste and worth keeping.
        guard let file = imageFile(on: board), let data = try? Data(contentsOf: file) else { return nil }
        return file.pathExtension.lowercased() == "png" ? data : png(fromImageData: data)
    }

    private static func png(fromImageData data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    private static func imageFile(on board: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        let images = Set(["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"])
        return urls?.first { images.contains($0.pathExtension.lowercased()) }
    }

    /// Nothing here is worth keeping past a couple of days: every file belongs
    /// to a prompt that has long since been sent or thrown away.
    private func pruneOldImages() {
        let cutoff = Date().addingTimeInterval(-2 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: store, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The clipboard, borrowed for as long as it takes Claude Code to read the
    /// image off it, and given back the way it was found.
    struct Clipboard {
        private let saved: [[NSPasteboard.PasteboardType: Data]]
        private let changeCount: Int

        /// Puts `file` on the clipboard, remembering what was there.
        static func lend(_ file: URL) -> Clipboard? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { copy, type in
                    copy[type] = item.data(forType: type)
                }
            }
            board.clearContents()
            board.setData(data, forType: .png)
            return Clipboard(saved: saved, changeCount: board.changeCount)
        }

        func giveBack() {
            let board = NSPasteboard.general
            // Copied something in the meantime: theirs wins, obviously.
            guard board.changeCount == changeCount else { return }
            board.clearContents()
            let items = saved.map { entry -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
    }

    // MARK: - Reading stand-ins off the screen

    /// Exactly the forms Claude Code writes, so a match is a stand-in and not a
    /// sentence in square brackets.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[(?:Pasted text #\d+(?: \+\d+ lines)?|Image #\d+|Audio #\d+|\.\.\.Truncated text #\d+ \+\d+ lines\.\.\.)\]"#)

    static func standInRanges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { Range($0.range, in: text) }
    }

    /// A looser test, for the leftovers: `[Image from Claude in Chrome]` and
    /// `[Image: …]` are stand-ins too, and ones we have no way to reproduce.
    /// Anything that even looks like one keeps the tab where it is.
    static func looksLikeStandIn(_ text: String) -> Bool {
        text.contains("[Pasted") || text.contains("[Image") || text.contains("[Audio")
            || text.contains("Truncated text #")
    }

    static func standIns(of view: LocalProcessTerminalView) -> Set<String> {
        guard let draft = TerminalManager.draft(of: view) else { return [] }
        return Set(standInRanges(in: draft).map { String(draft[$0]) })
    }

    /// How many images the prompt is showing — what tells us Claude Code has
    /// taken the one we just put on the clipboard.
    static func imageCount(of view: LocalProcessTerminalView) -> Int {
        guard let draft = TerminalManager.draft(of: view) else { return 0 }
        return standInRanges(in: draft).filter { draft[$0].hasPrefix("[Image #") }.count
    }
}
