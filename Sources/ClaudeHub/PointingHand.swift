import AppKit
import SwiftUI

/// The pointing-hand cursor, for the parts of the window that are clickable
/// without looking like a button.
///
/// AppKit gives buttons an arrow, which is right when a control has a bezel to
/// say what it is. Most of this window does not: a tab chip, a session row, a
/// pane header and an account chip are all plain drawn rectangles, and the only
/// way to find out they respond is to click one. The cursor is where that
/// belongs.
///
/// Applied to the outermost clickable view rather than to each control inside
/// it: a child that resets the cursor on the way out would hand the arrow back
/// while the pointer is still over its clickable parent.
private struct PointingHand: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// Marks a view as clickable to the pointer.
    func clickable() -> some View { modifier(PointingHand()) }
}

extension Color {
    /// Uncommitted work, and the states that go with it.
    ///
    /// Full-strength orange is a warning colour, and this is not a warning —
    /// it is a count. On the dark sidebar it wants to be lighter than the
    /// system orange to read as a tint rather than an alarm; on a light one it
    /// has to go the other way to stay legible at all.
    static let pending = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.52, alpha: 1)
            : NSColor(calibratedRed: 0.72, green: 0.46, blue: 0.04, alpha: 1)
    })
}
