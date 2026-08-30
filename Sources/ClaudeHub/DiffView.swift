import SwiftUI

/// One line of a diff, with the old and the new side by side.
struct DiffRow: Identifiable {
    enum Kind { case context, removed, added, replaced, hunk }

    let id: Int
    let kind: Kind
    let leftNumber: Int?
    let left: String?
    let rightNumber: Int?
    let right: String?
}

/// Reads a repository's changes and lays them out as two columns.
///
/// `git diff` writes one column: removals and additions stacked, which is
/// readable for a one-line change and hard work for anything else. The same
/// output rearranged — what was there on the left, what is there now on the
/// right, aligned — is the view an editor gives you, and it is the reason the
/// editor was being opened for a look.
@MainActor
final class DiffModel: ObservableObject {
    @Published private(set) var files: [GitFile] = []
    @Published var selected: String?
    @Published private(set) var rows: [DiffRow] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    let root: String

    init(root: String) {
        self.root = root
    }

    var name: String { (root as NSString).lastPathComponent }

    func load() {
        loading = true
        let root = self.root
        Task.detached(priority: .userInitiated) {
            let status = GitStore.run(["status", "--porcelain=v2", "--branch",
                                       "--untracked-files=normal"], in: root)
            let files = status.map { GitStore.parse($0, root: root).files } ?? []
            await MainActor.run {
                self.files = files
                self.loading = false
                if self.selected == nil || !files.contains(where: { $0.path == self.selected }) {
                    self.selected = files.first?.path
                }
                self.loadDiff()
            }
        }
    }

    func loadDiff() {
        guard let path = selected else {
            rows = []
            message = files.isEmpty ? "Nothing has changed in this repository." : nil
            return
        }
        loading = true
        let root = self.root
        let untracked = files.first { $0.path == path }?.mark == "?"

        Task.detached(priority: .userInitiated) {
            // An untracked file has nothing to compare against, so it is
            // compared with nothing: every line is an addition.
            let arguments = untracked
                ? ["diff", "--no-index", "--no-color", "-U3", "/dev/null", path]
                : ["diff", "--no-color", "-U3", "HEAD", "--", path]
            let output = GitStore.run(arguments, in: root) ?? ""
            let rows = DiffModel.rows(from: output)
            await MainActor.run {
                self.rows = rows
                self.loading = false
                self.message = rows.isEmpty ? "No textual difference — it may be a binary file." : nil
            }
        }
    }

    // MARK: - Turning one column into two

    /// Pairs each run of removed lines with the run of added lines that follows
    /// it, which is what makes a change read as a change rather than as a
    /// deletion followed by an unrelated insertion.
    nonisolated static func rows(from diff: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var id = 0
        var oldLine = 0
        var newLine = 0
        var removed: [String] = []
        var added: [String] = []

        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                let kind: DiffRow.Kind = left != nil && right != nil ? .replaced
                    : (left != nil ? .removed : .added)
                rows.append(DiffRow(id: id,
                                    kind: kind,
                                    leftNumber: left != nil ? oldLine + index + 1 : nil,
                                    left: left,
                                    rightNumber: right != nil ? newLine + index + 1 : nil,
                                    right: right))
                id += 1
            }
            oldLine += removed.count
            newLine += added.count
            removed = []
            added = []
        }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                flush()
                // "@@ -12,7 +12,9 @@ context"
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    oldLine = (Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 1) - 1
                    newLine = (Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 1) - 1
                }
                rows.append(DiffRow(id: id, kind: .hunk, leftNumber: nil,
                                    left: line, rightNumber: nil, right: nil))
                id += 1
                continue
            }
            // Everything before the first hunk is git's own preamble.
            guard !rows.isEmpty || !removed.isEmpty || !added.isEmpty else { continue }
            if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed.append(String(line.dropFirst()))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added.append(String(line.dropFirst()))
            } else if line.hasPrefix(" ") || line.isEmpty {
                flush()
                let text = line.isEmpty ? "" : String(line.dropFirst())
                oldLine += 1
                newLine += 1
                rows.append(DiffRow(id: id, kind: .context,
                                    leftNumber: oldLine, left: text,
                                    rightNumber: newLine, right: text))
                id += 1
            } else if line.hasPrefix("\\") {
                continue                                   // "\ No newline at end of file"
            }
        }
        flush()
        return rows
    }
}

/// The two columns, with the changed files beside them.
struct DiffView: View {
    @StateObject private var model: DiffModel
    let openInEditor: (String) -> Void

    init(root: String, openInEditor: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: DiffModel(root: root))
        self.openInEditor = openInEditor
    }

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 150, idealWidth: 210, maxWidth: 340)
            diff
                .frame(minWidth: 320)
        }
        .onAppear { model.load() }
        .onChange(of: model.selected) { _, _ in model.loadDiff() }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .clickable()
                    .help("Read the changes again")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            List(model.files, selection: $model.selected) { file in
                HStack(spacing: 6) {
                    Text(file.mark)
                        .font(.system(size: 10, weight: .semibold).monospaced())
                        .foregroundStyle(Self.color(for: file.mark))
                        .frame(width: 9, alignment: .leading)
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(file.path)
                .help(file.path)
                .contextMenu {
                    Button("Open in VS Code") { openInEditor(file.path) }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var diff: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.selected ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if model.loading { ProgressView().controlSize(.small) }
                if let path = model.selected {
                    Button("Open in VS Code") { openInEditor(path) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .clickable()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if let message = model.message {
                Spacer()
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            DiffRowView(row: row)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private static func color(for mark: String) -> Color {
        switch mark {
        case "A": return .green
        case "D": return .red
        case "?": return .secondary
        default: return .pending
        }
    }
}

private struct DiffRowView: View {
    let row: DiffRow

    private static let numberWidth: CGFloat = 42
    private static let font = Font.system(size: 11.5).monospaced()

    var body: some View {
        if row.kind == .hunk {
            HStack {
                Text(row.left ?? "")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
        } else {
            HStack(spacing: 0) {
                half(number: row.leftNumber, text: row.left, side: .left)
                Divider()
                half(number: row.rightNumber, text: row.right, side: .right)
            }
        }
    }

    private enum Side { case left, right }

    @ViewBuilder
    private func half(number: Int?, text: String?, side: Side) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: Self.numberWidth, alignment: .trailing)
            Text(text ?? "")
                .font(Self.font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: side, hasText: text != nil))
    }

    /// Removals tint the left, additions the right; a line that is simply
    /// missing on one side is greyed rather than coloured, so the eye is not
    /// told a line was deleted when it was only never there.
    private func background(for side: Side, hasText: Bool) -> Color {
        guard hasText else { return Color.primary.opacity(0.04) }
        switch (row.kind, side) {
        case (.removed, .left), (.replaced, .left): return Color.red.opacity(0.16)
        case (.added, .right), (.replaced, .right): return Color.green.opacity(0.16)
        default: return .clear
        }
    }
}
