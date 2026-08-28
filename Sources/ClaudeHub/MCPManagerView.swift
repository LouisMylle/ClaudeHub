import SwiftUI

struct MCPManagerView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TabsModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mcp = MCPStore()

    @State private var showAddForm = false
    @State private var serverToRemove: MCPServer?

    // Add form fields
    @State private var newName = ""
    @State private var newScope: MCPServer.Scope = .user
    @State private var newProjectPath = ""
    @State private var newTransport = "stdio"
    @State private var newTarget = ""

    private var groupedServers: [(String, [MCPServer])] {
        var groups: [(String, [MCPServer])] = []
        let user = mcp.servers.filter { $0.scope == .user }
        if !user.isEmpty { groups.append(("User — all projects", user)) }
        let byProject = Dictionary(grouping: mcp.servers.filter { $0.projectPath != nil },
                                   by: { $0.projectPath! })
        for (path, servers) in byProject.sorted(by: { $0.key < $1.key }) {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            groups.append((name, servers.sorted { $0.name < $1.name }))
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("MCP Servers", systemImage: "server.rack")
                    .font(.title3.weight(.semibold))
                Spacer()
                if mcp.isBusy { ProgressView().controlSize(.small) }
                Button {
                    mcp.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button(showAddForm ? "Cancel" : "Add Server") { showAddForm.toggle() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if showAddForm { addForm; Divider() }

            List {
                ForEach(groupedServers, id: \.0) { groupName, servers in
                    Section(groupName) {
                        ForEach(servers) { server in
                            serverRow(server)
                        }
                    }
                }
                if mcp.servers.isEmpty {
                    Text("No MCP servers configured.")
                        .foregroundStyle(.secondary)
                }
            }

            if let message = mcp.statusMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(width: 680, height: 540)
        .onAppear {
            mcp.refresh()
            newProjectPath = tabs.activeTab?.cwd ?? store.projects.first?.path ?? ""
        }
        .confirmationDialog(
            "Remove \(serverToRemove?.name ?? "")?",
            isPresented: .init(get: { serverToRemove != nil },
                               set: { if !$0 { serverToRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let server = serverToRemove { mcp.remove(server) }
                serverToRemove = nil
            }
        } message: {
            Text("Runs `claude mcp remove` for the \(serverToRemove?.scope.rawValue ?? "") scope. Env vars and headers on this entry are lost.")
        }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium)
                    Text(server.transport)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    Text(server.scope.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(server.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                serverToRemove = server
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this server")
        }
        .padding(.vertical, 2)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $newName)
                    .frame(width: 160)
                Picker("Scope", selection: $newScope) {
                    ForEach(MCPServer.Scope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .frame(width: 130)
                Picker("Transport", selection: $newTransport) {
                    Text("stdio").tag("stdio")
                    Text("http").tag("http")
                    Text("sse").tag("sse")
                }
                .frame(width: 140)
            }
            if newScope != .user {
                Picker("Project", selection: $newProjectPath) {
                    ForEach(store.projects) { project in
                        Text(project.name).tag(project.path)
                    }
                }
            }
            HStack {
                TextField(
                    newTransport == "stdio"
                        ? "Command, e.g. npx -y @some/mcp-server --flag"
                        : "URL, e.g. https://mcp.example.dev/mcp",
                    text: $newTarget
                )
                Button("Add") {
                    mcp.add(
                        name: newName.trimmingCharacters(in: .whitespaces),
                        scope: newScope,
                        projectPath: newScope == .user ? nil : newProjectPath,
                        transport: newTransport,
                        target: newTarget.trimmingCharacters(in: .whitespaces)
                    )
                    newName = ""
                    newTarget = ""
                    showAddForm = false
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newTarget.trimmingCharacters(in: .whitespaces).isEmpty
                          || mcp.isBusy)
            }
            Text(newScope.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding()
    }
}
