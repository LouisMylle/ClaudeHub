import SwiftUI

/// The 5-hour and weekly limits, always on screen in the sidebar footer.
struct UsageBars: View {
    @ObservedObject var usage: UsageStore

    var body: some View {
        VStack(spacing: 3) {
            row("5h", usage.session)
            row("Week", usage.week)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
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
    private func row(_ label: String, _ window: UsageWindow?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)

            // Fixed width on purpose: a GeometryReader here reads the size of
            // the very inset it sits in, which makes the sidebar re-layout
            // while it is already laying out.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: Self.barWidth)
                if let window {
                    Capsule()
                        .fill(Self.color(for: window.level))
                        .frame(width: Self.barWidth * CGFloat(window.percent) / 100)
                }
            }
            .frame(width: Self.barWidth, height: 5)

            if let window {
                Text("\(window.percent)%")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(for: window.level))
                    .frame(width: 28, alignment: .trailing)
            } else if usage.isProbing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 28, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)
            }

            Text(window?.resets ?? "")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private static let barWidth: CGFloat = 84

    private static func color(for level: Int) -> Color {
        switch level {
        case 2: return .red
        case 1: return .orange
        default: return .green
        }
    }
}
