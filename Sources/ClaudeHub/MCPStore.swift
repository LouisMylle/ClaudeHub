import Foundation
import Combine

struct MCPServer: Identifiable, Hashable {
    enum Scope: String, CaseIterable {
        case user, project, local

        var label: String {
            switch self {
            case .user: return "User (all projects)"
            case .project: return "Project (.mcp.json, shared)"
            case .local: return "Local (this machine, per project)"
            }
        }
    }

    let name: String
    let scope: Scope
    let projectPath: String?    // nil for user scope
    let transport: String       // stdio / http / sse
    let detail: String          // command + args, or URL

    var id: String { "\(scope.rawValue)|\(projectPath ?? "")|\(name)" }
}

/// Reads MCP config from ~/.claude.json and per-project .mcp.json files;
/// mutations go through the `claude mcp` CLI so config stays consistent.
final class MCPStore: ObservableObject {
    @Published var servers: [MCPServer] = []
    @Published var isBusy = false
    @Published var statusMessage: String?

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let servers = Self.scan()
            DispatchQueue.main.async { self.servers = servers }
        }
    }

    // MARK: - Reading

    private static func scan() -> [MCPServer] {
        var result: [MCPServer] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        result += parse(root["mcpServers"], scope: .user, projectPath: nil)

        var projectPaths: Set<String> = []
        if let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects {
                projectPaths.insert(path)
                guard let projectDict = value as? [String: Any] else { continue }
                result += parse(projectDict["mcpServers"], scope: .local, projectPath: path)
            }
        }

        // Shared project config committed alongside the code
        for path in projectPaths {
            let mcpFile = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            guard let data = try? Data(contentsOf: mcpFile),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            result += parse(dict["mcpServers"], scope: .project, projectPath: path)
        }

        return result.sorted {
            ($0.scope.rawValue, $0.projectPath ?? "", $0.name)
                < ($1.scope.rawValue, $1.projectPath ?? "", $1.name)
        }
    }

    private static func parse(_ value: Any?, scope: MCPServer.Scope, projectPath: String?) -> [MCPServer] {
        guard let dict = value as? [String: Any], !dict.isEmpty else { return [] }
        return dict.compactMap { name, config in
            guard let config = config as? [String: Any] else { return nil }
            let url = config["url"] as? String
            let command = config["command"] as? String
            let transport = (config["type"] as? String) ?? (url != nil ? "http" : "stdio")
            var detail = url ?? command ?? "?"
            if let args = config["args"] as? [String], !args.isEmpty {
                detail += " " + args.joined(separator: " ")
            }
            return MCPServer(name: name, scope: scope, projectPath: projectPath,
                             transport: transport, detail: detail)
        }
    }

    // MARK: - Mutations (via claude CLI)

    func remove(_ server: MCPServer) {
        let command = "mcp remove \(ClaudeSession.shellQuote(server.name)) -s \(server.scope.rawValue)"
        run(command, cwd: server.projectPath, successMessage: "Removed \(server.name)")
    }

    /// `target` is the URL for http/sse, or the full command line for stdio
    /// (parsed by the shell, so quoting works like in a terminal).
    func add(name: String, scope: MCPServer.Scope, projectPath: String?, transport: String, target: String) {
        let quotedName = ClaudeSession.shellQuote(name)
        let command: String
        if transport == "stdio" {
            command = "mcp add \(quotedName) -s \(scope.rawValue) -- \(target)"
        } else {
            command = "mcp add -t \(transport) -s \(scope.rawValue) \(quotedName) \(ClaudeSession.shellQuote(target))"
        }
        run(command, cwd: projectPath, successMessage: "Added \(name)")
    }

    private func run(_ mcpArgs: String, cwd: String?, successMessage: String) {
        isBusy = true
        statusMessage = nil
        let claudePath = TerminalManager.shared.claudePath
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "\(ClaudeSession.shellQuote(claudePath)) \(mcpArgs)"]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var output = ""
            var status: Int32 = -1
            do {
                try process.run()
                process.waitUntilExit()
                status = process.terminationStatus
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } catch {
                output = error.localizedDescription
            }
            let servers = Self.scan()
            DispatchQueue.main.async {
                self.servers = servers
                self.isBusy = false
                self.statusMessage = status == 0
                    ? successMessage
                    : output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
