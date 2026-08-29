import SwiftUI

/// What a tab's terminal is doing, as read off the screen by TerminalManager.
enum TerminalActivity: Equatable {
    case stopped      // no terminal yet
    case idle         // running, waiting for you
    case busy         // Claude is working ("esc to interrupt")
    case needsInput   // a permission prompt is waiting on an answer
    case dead         // the process exited

    var color: Color {
        switch self {
        case .stopped: return .secondary
        case .idle: return .green
        case .busy: return .orange
        case .needsInput: return .blue
        case .dead: return .secondary
        }
    }

    var pulses: Bool { self == .busy || self == .needsInput }

    var help: String {
        switch self {
        case .stopped: return "Not running"
        case .idle: return "Waiting for you"
        case .busy: return "Claude is working"
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
            .opacity(dimmed ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.7), value: dimmed)
            .help(activity.help)
    }
}
