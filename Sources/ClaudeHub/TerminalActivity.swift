import SwiftUI

/// What a tab's terminal is doing, as read off the screen by TerminalManager.
enum TerminalActivity: Equatable {
    case stopped      // no terminal yet
    case idle         // running, waiting for you, and you have seen it
    case busy         // Claude is working ("esc to interrupt")
    case finished     // answered while you were somewhere else, still unread
    case needsInput   // a permission prompt is waiting on an answer
    case dead         // the process exited

    /// Blue is "this one wants you": a question that blocks the session
    /// pulses, an answer you have not read yet sits still. Green is the settled
    /// state — running, nothing waiting, nothing you have missed.
    var color: Color {
        switch self {
        case .stopped: return .secondary
        case .idle: return .green
        case .busy: return .orange
        case .finished: return .blue
        case .needsInput: return .blue
        case .dead: return .secondary
        }
    }

    var pulses: Bool { self == .busy || self == .needsInput }

    /// Unread answers earn a ring, so the two blues are never in doubt at 7pt.
    var isUnread: Bool { self == .finished }

    var help: String {
        switch self {
        case .stopped: return "Not running"
        case .idle: return "Waiting for you"
        case .busy: return "Claude is working"
        case .finished: return "Finished — you have not looked at it yet"
        case .needsInput: return "Waiting for your answer"
        case .dead: return "Session ended"
        }
    }
}

/// The status dot. Steady while idle, breathing while Claude is busy or is
/// waiting on an answer, so a glance across the sidebar tells you where to look.
struct ActivityDot: View {
    let activity: TerminalActivity
    var size: CGFloat = 7

    @ObservedObject private var manager = TerminalManager.shared

    var body: some View {
        let dimmed = activity.pulses && manager.pulse
        Circle()
            .fill(activity.color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(activity.color.opacity(0.35), lineWidth: size * 0.45)
                    .frame(width: size * 2.1, height: size * 2.1)
                    .opacity(activity.isUnread ? 1 : 0)
            )
            .opacity(dimmed ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.7), value: dimmed)
            .help(activity.help)
    }
}
