import Foundation

struct ClaudeSession: Identifiable, Hashable {
    let id: String          // session UUID (jsonl filename)
    let title: String
    let cwd: String
    let lastModified: Date
    let fileURL: URL

    var resumeCommand: String {
        "cd \(ClaudeSession.shellQuote(cwd)) && claude --resume \(id)"
    }

    /// Everything Claude Code keeps for this session: the transcript, the
    /// sidecar folder next to it (tool results), and the session's env dir.
    /// Deleting a chat should not leave these behind.
    var artifactURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            fileURL,
            fileURL.deletingPathExtension(),                                  // <uuid>/ sidecar
            home.appendingPathComponent(".claude/session-env/\(id)"),
        ]
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ClaudeProject: Identifiable, Hashable {
    let id: String          // cwd
    let name: String
    let path: String
    var sessions: [ClaudeSession]

    var lastModified: Date { sessions.map(\.lastModified).max() ?? .distantPast }
}
