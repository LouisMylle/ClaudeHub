import AppKit
import SwiftTerm

/// A terminal you can drop files onto, which every other terminal on this
/// machine lets you do: the path is typed in at the cursor, escaped, as if you
/// had written it out.
///
/// SwiftTerm registers no dragged types at all, so without this the view simply
/// refuses the drop — no path, no feedback, nothing. Claude Code takes a path
/// for an image or a file to read exactly as it takes typed text, so this is
/// the whole of what is needed.
///
/// It also watches what is pasted into it: Claude Code shows a paste as
/// `[Pasted text #12 +36 lines]` and keeps the content to itself, so this is
/// the only place the content can be kept — see `PasteMemory`.
final class DroppableTerminalView: LocalProcessTerminalView {
    /// Which tab this terminal is, so what is pasted into it is remembered
    /// against the right prompt.
    var tabID: String?
    /// Whether ⌃V means "take this image" here — it does to Claude Code, and
    /// to a shell it means quoted-insert, which is not something to send one
    /// on a guess.
    var takesImagePastes = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Pastes

    override func paste(_ sender: Any) {
        guard let tabID else { return super.paste(sender) }

        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            PasteMemory.shared.note(.text(text), pastedInto: self, tab: tabID)
            return super.paste(sender)
        }

        // An image on the clipboard. ⌘V in a terminal pastes nothing at all —
        // there is no text to send — and Claude Code takes images on ⌃V, which
        // it answers by reading the clipboard itself. So ⌘V is passed on as
        // that, and the image is kept on the way through.
        guard takesImagePastes,
              let file = PasteMemory.shared.keepClipboardImage() else { return super.paste(sender) }
        PasteMemory.shared.note(.image(file), pastedInto: self, tab: tabID)
        send(txt: "\u{16}")
    }

    // MARK: Drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.paths(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.paths(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.paths(in: sender)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }

        // A trailing space, so dropping two files in a row does not run them
        // together, and so you can keep typing straight after one.
        send(txt: paths.map(Self.escaped).joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    private static func paths(in sender: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: options) as? [URL]
        return (urls ?? []).map(\.path)
    }

    /// Backslash-escaped the way a terminal writes a dropped path, so it can be
    /// used as-is whether the line is read by a shell or by Claude.
    private static func escaped(_ path: String) -> String {
        let specials = Set(" \t\n\"'\\$`&|;<>()*?[]{}!#")
        var out = ""
        for character in path {
            if specials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
