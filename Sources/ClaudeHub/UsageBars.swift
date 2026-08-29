import SwiftUI

/// The 5-hour and weekly limits, always on screen in the sidebar footer.
struct UsageBars: View {
    @ObservedObject var usage: UsageStore

    private static let barWidth: CGFloat = 90

    var body: some View {
        HStack(spacing: 6) {
            // Both windows count down; the raw text is only a fallback for a
            // reset the panel phrased in some way we could not turn into a date.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    row("5h", usage.session, at: context.date)
                    row("Week", usage.week, at: context.date)
                    // Never a bare percentage: it says whose it is.
                    Text(usage.accountLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 39)
                }
            }
            Button {
                usage.refreshByHand()
            } label: {
                // A failed read is worth an icon of its own: silently showing
                // "—" forever is how a broken account looks like a quiet one.
                //
                // The two symbols are deliberately separate views. Swapping the
                // name on one shared Image keeps the view — and its in-flight
                // spin — alive across the swap, so the triangle inherits the
                // turn and ends up sitting there tilted.
                Group {
                    if showsProblem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Color.secondary)
                            .rotationEffect(.degrees(usage.isProbing ? 360 : 0))
                            // Nothing to animate on the way back: a repeatForever
                            // that is merely re-targeted keeps on turning.
                            .animation(usage.isProbing
                                       ? .linear(duration: 1).repeatForever(autoreverses: false)
                                       : nil,
                                       value: usage.isProbing)
                    }
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(usage.isProbing)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .help(helpText)
    }

    /// An account with nothing to report is not a fault, so it does not get a
    /// warning triangle — only something that actually went wrong does.
    private var showsProblem: Bool {
        usage.errorMessage != nil && !usage.isProbing && !usage.limitsUnavailable
    }

    private var iconName: String {
        if showsProblem { return "exclamationmark.triangle.fill" }
        if usage.limitsUnavailable { return "info.circle" }
        return "arrow.clockwise"
    }

    private var helpText: String {
        if let error = usage.errorMessage { return "\(error)\n\nClick to try again." }
        guard let updated = usage.lastUpdated else {
            return usage.isProbing ? "Reading /usage…" : "Click ↻ to read your limits"
        }
        let seconds = Int(Date().timeIntervalSince(updated))
        let ago = seconds < 60 ? "just now" : "\(seconds / 60) min ago"
        return "Updated \(ago), and every minute — click ↻ for now"
    }

    @ViewBuilder
    private func row(_ label: String, _ window: UsageWindow?, at now: Date) -> some View {
        // A blank row reads as "nothing to report"; the truth is "we could not
        // find out", and the two deserve different words.
        let trailing = window?.countdown(from: now)
            ?? window?.resets
            ?? (usage.limitsUnavailable ? "not reported" : nil)
            ?? (showsProblem ? "unavailable" : nil)
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            // Fixed width on purpose: a GeometryReader here reads the size of
            // the very inset it sits in, which makes the sidebar re-layout
            // while it is already laying out.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: Self.barWidth)
                if let window {
                    Capsule()
                        .fill(Self.color(for: window.level))
                        .frame(width: Self.barWidth * CGFloat(window.percent) / 100)
                }
            }
            .frame(width: Self.barWidth, height: 7)

            if let window {
                Text("\(window.percent)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(for: window.level))
                    .frame(width: 36, alignment: .trailing)
            } else if usage.limitsUnavailable {
                Text("n/a")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            } else if usage.isProbing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }

            Text(trailing ?? "")
                .font(.system(size: 11))
                .foregroundStyle(window == nil && showsProblem ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private static func color(for level: Int) -> Color {
        switch level {
        case 2: return .red
        case 1: return .orange
        default: return .green
        }
    }
}
