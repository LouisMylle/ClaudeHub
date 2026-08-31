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
