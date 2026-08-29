import SwiftUI

/// The 5-hour and weekly limits, always on screen in the sidebar footer.
struct UsageBars: View {
    @ObservedObject var usage: UsageStore

    private static let barWidth: CGFloat = 90

    var body: some View {
        VStack(spacing: 5) {
            // The 5-hour window is the one you wait on, so it counts down.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                row("5h", usage.session, trailing: usage.session?.countdown(from: context.date))
            }
            row("Week", usage.week, trailing: usage.week?.resets)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture { usage.refresh() }
        .help(helpText)
    }

    private var helpText: String {
        if let error = usage.errorMessage { return error }
        guard let updated = usage.lastUpdated else {
            return usage.isProbing ? "Reading /usage…" : "Click to read your limits"
        }
        return "Limits as of \(updated.formatted(date: .omitted, time: .shortened)) — click to refresh"
    }

    @ViewBuilder
    private func row(_ label: String, _ window: UsageWindow?, trailing: String?) -> some View {
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
                .foregroundStyle(.secondary)
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
