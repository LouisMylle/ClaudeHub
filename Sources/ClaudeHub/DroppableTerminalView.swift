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
final class DroppableTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

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
