import SwiftUI
import SwiftTerm

/// Hosts the SwiftTerm view for a tab inside SwiftUI.
/// A container view lets us swap terminals when tabs switch or restart.
struct TerminalHostView: NSViewRepresentable {
    let tab: TerminalTab
    let generation: Int   // dependency: re-runs updateNSView when a process ends/restarts

    private static let leftInset: CGFloat = 12

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let terminal = TerminalManager.shared.terminal(for: tab)
        guard terminal.superview !== container else { return }

        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = NSRect(
            x: Self.leftInset,
            y: 0,
            width: max(0, container.bounds.width - Self.leftInset),
            height: container.bounds.height
        )
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)

        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}
