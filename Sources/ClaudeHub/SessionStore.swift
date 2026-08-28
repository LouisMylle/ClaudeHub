import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published var projects: [ClaudeProject] = []
    @Published var isLoading = false

    private let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let root = projectsRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let projects = Self.scan(root: root)
            DispatchQueue.main.async {
                self.projects = projects
                self.isLoading = false
            }
        }
    }

    /// Hidden sessions stay on disk (still resumable), they just leave the list.
    @Published var hiddenSessionIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenSessionIDs") ?? [])

    func setHidden(_ session: ClaudeSession, _ hidden: Bool) {
        if hidden {
            hiddenSessionIDs.insert(session.id)
        } else {
            hiddenSessionIDs.remove(session.id)
        }
        UserDefaults.standard.set(Array(hiddenSessionIDs), forKey: "hiddenSessionIDs")
    }

    private static func scan(root: URL) -> [ClaudeProject] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var byCwd: [String: [ClaudeSession]] = [:]
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let session = parseSession(file: file) else { continue }
                byCwd[session.cwd, default: []].append(session)
            }
        }

        return byCwd.map { cwd, sessions in
            ClaudeProject(
                id: cwd,
                name: projectName(for: cwd),
                path: cwd,
                sessions: sessions.sorted { $0.lastModified > $1.lastModified }
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    private static func projectName(for cwd: String) -> String {
        let comps = cwd.split(separator: "/").map(String.init)
        guard let last = comps.last else { return cwd }
        // Prefix with parent folder when the last component is generic-ish or for context
        if comps.count >= 2 {
            let parent = comps[comps.count - 2]
            if ["frontend", "backend", "src", "app", "web", "api", "portal"].contains(last.lowercased()) {
                return "\(parent)/\(last)"
            }
        }
        return last
    }

    // MARK: - JSONL parsing

    private static func parseSession(file: URL) -> ClaudeSession? {
        let id = file.deletingPathExtension().lastPathComponent
        // Session transcripts are named by UUID; skip anything else (e.g. agent sidechains)
        guard UUID(uuidString: id) != nil else { return nil }

        guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = attrs.contentModificationDate,
              let size = attrs.fileSize, size > 0 else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let headData = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let head = String(decoding: headData, as: UTF8.self)

        var tail = ""
        let tailLength = 64 * 1024
        if size > 256 * 1024 {
            try? handle.seek(toOffset: UInt64(max(0, size - tailLength)))
            if let tailData = try? handle.readToEnd() {
                tail = String(decoding: tailData, as: UTF8.self)
            }
        }

        // Sidechain (subagent) transcripts live alongside main sessions in old versions — skip them.
        if firstJSONValue(in: head, key: "isSidechain") == "true" { return nil }

        // cwd is required to resume in the right folder; files without one are
        // bridge stubs or empty shells — not useful in the list.
        guard let cwd = firstJSONString(in: head, key: "cwd"), !cwd.isEmpty else { return nil }

        let title = lastJSONString(in: tail, key: "aiTitle")
            ?? lastJSONString(in: head, key: "aiTitle")
            ?? firstUserPrompt(in: head)
            ?? "Session \(id.prefix(8))"

        return ClaudeSession(
            id: id,
            title: title,
            cwd: cwd,
            lastModified: mtime,
            fileURL: file
        )
    }

    /// Extracts the raw token following `"key":` (for booleans/numbers).
    private static func firstJSONValue(in text: String, key: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":") else { return nil }
        let rest = text[range.upperBound...].prefix(8)
        if rest.hasPrefix("true") { return "true" }
        if rest.hasPrefix("false") { return "false" }
        return nil
    }

    private static func firstJSONString(in text: String, key: String) -> String? {
        extractString(in: text, key: key, fromEnd: false)
    }

    private static func lastJSONString(in text: String, key: String) -> String? {
        extractString(in: text, key: key, fromEnd: true)
    }

    private static func extractString(in text: String, key: String, fromEnd: Bool) -> String? {
        let needle = "\"\(key)\":\""
        let range = fromEnd
            ? text.range(of: needle, options: .backwards)
            : text.range(of: needle)
        guard let range else { return nil }

        var raw = ""
        var escaped = false
        for ch in text[range.upperBound...] {
            if escaped {
                raw.append("\\")
                raw.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            raw.append(ch)
        }
        // Decode JSON string escapes by round-tripping through JSONSerialization
        if let data = "[\"\(raw)\"]".data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let decoded = arr.first {
            return decoded.isEmpty ? nil : decoded
        }
        return raw.isEmpty ? nil : raw
    }

    private static func firstUserPrompt(in head: String) -> String? {
        for line in head.split(separator: "\n") {
            guard line.contains("\"type\":\"user\""),
                  !line.contains("\"isMeta\":true"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any] else { continue }

            var text: String?
            if let s = message["content"] as? String {
                text = s
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            guard var t = text else { continue }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip slash-command noise and system-injected content
            if t.isEmpty || t.hasPrefix("<") { continue }
            let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
            return firstLine.count > 80 ? String(firstLine.prefix(77)) + "…" : firstLine
        }
        return nil
    }
}
