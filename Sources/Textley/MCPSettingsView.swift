import AppKit
import SwiftUI

struct MCPSettingsView: View {
    let service: TextleyMCPService

    private enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case claudeChat = "Claude chat"
        var id: Self { self }
    }

    @State private var client: Client = .claudeCode
    @State private var message: String?

    var body: some View {
        Form {
            Section("MCP access") {
                Toggle("Enable MCP access", isOn: Binding(
                    get: { service.enabled },
                    set: { value in Task { await service.setEnabled(value) } }
                ))
                .disabled(service.isChanging)
                .accessibilityIdentifier("mcpEnableToggle")
                Toggle("Allow MCP to write", isOn: Binding(
                    get: { service.allowsWriting },
                    set: service.setAllowsWriting
                ))
                .disabled(!service.enabled || service.isChanging)
                .accessibilityIdentifier("mcpWriteToggle")
                Text("Agents can access open tabs and folders. A connected agent may send retrieved text to its AI provider.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(service.status, systemImage: service.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(service.enabled ? Color.primary : Color.secondary)
                        if service.enabled {
                            Text(service.allowsWriting ? "Read & write" : "Read only")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if service.isTesting { ProgressView().controlSize(.small) }
                    Button("Test Connection") { Task { await service.testConnection() } }
                        .disabled(!service.enabled || service.isChanging || service.isTesting)
                }
                if let error = service.errorMessage { Text(error).foregroundStyle(.red) }
                if let test = service.testMessage { Text(test).font(.caption) }
            }

            Section("Connect an app") {
                Picker("Client", selection: $client) {
                    ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch client {
                case .claudeCode:
                    Text("Save the connection in a project folder. Open that same folder in Claude’s Code tab in a local session.")
                    Button("Save Project Connection…") {
                        perform {
                            guard let config = TextleyMCPDesktopSetup.projectConfiguration else { return nil }
                            return try TextleyMCPDesktopSetup.saveProject(configuration: config)
                        }
                    }
                case .codex:
                    Text("Add a STDIO server named textley in Codex Settings → MCP servers. Paste the Command and Argument in their own fields.")
                    HStack {
                        Button("Copy Command") { copy(TextleyMCPDesktopSetup.command, name: "Command") }
                        Button("Copy Argument") { copy(TextleyMCPDesktopSetup.argument, name: "Argument") }
                    }
                case .claudeChat:
                    Text("Save the local extension, install it in Claude’s Extensions settings, then paste the access token.")
                    HStack {
                        Button("Save Claude Extension…") {
                            perform { try TextleyMCPDesktopSetup.saveClaudeExtension(endpoint: service.endpoint) }
                        }
                        Button("Copy Access Token") {
                            if let token = service.accessToken { copy(token, name: "Access token") }
                        }
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .disabled(!service.enabled || service.isChanging)
            .onChange(of: client) { _, _ in message = nil }

            Section("Activity and access controls") {
                if let name = service.lastClientName, let date = service.lastClientDate {
                    LabeledContent("Last agent", value: name + " · " + date.formatted(date: .omitted, time: .shortened))
                }
                if let tool = service.lastToolName, let date = service.lastToolDate {
                    LabeledContent("Last successful call", value: tool + " · " + date.formatted(date: .omitted, time: .shortened))
                }
                Button("Rotate Access Token…") { confirmRotation() }.disabled(!service.enabled || service.isChanging)
                Button("Copy HTTP Configuration") {
                    if let configuration = service.clientConfiguration { copy(configuration, name: "HTTP configuration") }
                }
                .disabled(!service.enabled || service.isChanging)
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ value: String, name: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        message = name + " copied."
    }

    private func perform(_ action: () throws -> String?) {
        do { message = try action() } catch { NSApp.presentError(error) }
    }

    private func confirmRotation() {
        let alert = NSAlert()
        alert.messageText = "Rotate the Textley MCP token?"
        alert.informativeText = "Existing connections will need to reconnect. Claude chat and direct HTTP clients need the new token."
        alert.addButton(withTitle: "Rotate Token")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await service.rotateToken() }
    }
}
