import AppKit
import Combine
import Foundation

/// One changed file, as `git status` marks it.
struct GitFile: Identifiable, Equatable {
    /// "M" modified, "A" added, "D" deleted, "?" untracked, "U" unmerged.
    let mark: String
    let path: String

    var id: String { "\(mark) \(path)" }
}

/// What one repository has lying around.
struct RepoStatus: Identifiable, Equatable {
    let root: String
    let branch: String
    /// Nil when the branch tracks nothing — it exists only on this machine.
    let upstream: String?
    let ahead: Int
    let behind: Int
    let files: [GitFile]

    var id: String { root }
    var name: String { (root as NSString).lastPathComponent }
    var changed: Int { files.filter { $0.mark != "?" }.count }
    var untracked: Int { files.filter { $0.mark == "?" }.count }
    var isDirty: Bool { !files.isEmpty }

    /// The count for the project header: everything that is not committed.
    var pending: Int { files.count }

    /// Where this branch stands against the remote, in the fewest words that
    /// are still true.
    var syncLabel: String {
        guard upstream != nil else { return "not pushed anywhere" }
        switch (ahead, behind) {
        case (0, 0): return "in sync"
        case (let a, 0): return "\(a) ahead"
        case (0, let b): return "\(b) behind"
        case (let a, let b): return "\(a) ahead, \(b) behind"
        }
    }

    var isUnpushed: Bool { upstream == nil }
}

/// Reads `git status` for the projects ClaudeHub already knows about.
///
/// The question this answers is not "what changed in this file" — that is an
/// editor's job, and a good one is already open. It is "where did I leave work
/// lying around", across every project in the sidebar, which is the same
/// question the session list answers and nothing else on screen does.
final class GitStore: ObservableObject {
    @Published private(set) var repos: [RepoStatus] = []

    private var roots: [String] = []
    /// cwd → repository root, so the walk up the tree happens once per folder.
    private var rootCache: [String: String?] = [:]
    private var timer: Timer?
    private var scanning = false
    private let queue = DispatchQueue(label: "be.optimize.claudehub.git", qos: .utility)

    private lazy var gitPath: String = {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }()

    /// The repositories worth watching, from the folders the sidebar lists.
    var dirtyRepos: [RepoStatus] { repos.filter(\.isDirty) }

    func status(forProjectAt path: String) -> RepoStatus? {
        guard let root = rootCache[path] ?? nil else { return nil }
        return repos.first { $0.root == root }
    }

    /// Refreshed on a slow timer, and only while the window is in front: a
    /// status you are not looking at is 27 processes nobody asked for.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard NSApplication.shared.isActive else { return }
            self?.scan()
        }
    }

    /// Called with the sidebar's project folders whenever they are rescanned.
    func track(projects paths: [String]) {
        let resolved = paths.compactMap { path -> String? in
            if let cached = rootCache[path] { return cached }
            let root = Self.repositoryRoot(of: path)
            rootCache[path] = root
            return root
        }
        let unique = Array(Set(resolved)).sorted()
        guard unique != roots else { return }
        roots = unique
        scan()
    }

    func scan() {
        guard !scanning, !roots.isEmpty else { return }
        scanning = true
        let roots = self.roots
        let git = gitPath

        queue.async {
            let statuses = roots.compactMap { Self.read(root: $0, git: git) }
            DispatchQueue.main.async {
                self.scanning = false
                let sorted = statuses.sorted { ($0.pending, $1.name) > ($1.pending, $0.name) }
                if sorted != self.repos { self.repos = sorted }
            }
        }
    }

    // MARK: - Reading

    /// The repository a folder belongs to, or nil if it is not in one.
    private static func repositoryRoot(of path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func read(root: String, git: String) -> RepoStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.arguments = ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text, root: root)
    }

    /// `git status --porcelain=v2 --branch`, which states the branch, its
    /// upstream and how far apart they are before listing the files.
    static func parse(_ text: String, root: String) -> RepoStatus {
        var branch = "detached"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var files: [GitFile] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // "+2 -1"
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                behind = parts.count > 1 ? Int(parts[1].dropFirst()) ?? 0 : 0
            } else if line.hasPrefix("? ") {
                files.append(GitFile(mark: "?", path: String(line.dropFirst(2))))
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>", and a rename
                // adds "<tab><original>" to the end of the path.
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard fields.count == 9 else { continue }
                let code = fields[1]
                let path = fields[8].split(separator: "\t").first.map(String.init) ?? String(fields[8])
                files.append(GitFile(mark: mark(for: code), path: path))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                if let path = fields.last { files.append(GitFile(mark: "U", path: String(path))) }
            }
        }

        return RepoStatus(root: root,
                          branch: branch,
                          upstream: upstream,
                          ahead: ahead,
                          behind: behind,
                          files: files)
    }

    /// The staged column first, then the unstaged one: what the file is, in one
    /// letter, the way git itself abbreviates it.
    private static func mark(for code: Substring) -> String {
        for character in code where character != "." {
            return String(character)
        }
        return "M"
    }
}
