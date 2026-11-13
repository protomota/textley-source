import AppKit
import MCP
@testable import Textley
import XCTest

final class MCPTests: XCTestCase {
    @MainActor
    func testRealMCPConnectionAndPermissionLifecycle() async throws {
        _ = NSApplication.shared
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Vault").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("Field Notes.md")
        try Data("# Draft\n".utf8).write(to: file)
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("a unique trail marker".utf8).write(to: nested.appendingPathComponent("Note.md"))
        let outside = folder.appendingPathComponent("Outside.md")
        try Data("Out of scope".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape.md"), withDestinationURL: outside)

        let suite = "Textley-MCP-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TextleyApplication(defaults: defaults)
        let window = app.newWindow()
        defer { window.window?.orderOut(nil); app.removeWindow(window) }
        window.addVault(root)
        let token = try TextleyMCPToken.generate()
        let service = TextleyMCPService(defaults: defaults, port: 0, token: token)
        await service.attach(store: app)
        XCTAssertFalse(service.enabled)
        await service.setEnabled(true)
        XCTAssertTrue(service.enabled, service.errorMessage ?? "")
        XCTAssertFalse(service.allowsWriting)

        let endpoint = try XCTUnwrap(URL(string: service.endpoint))
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}}},"clientInfo":{"name":"Codex fixture","version":"1"}}}"#
        let handshake = try await request(endpoint, token: token, body: initialize)
        XCTAssertEqual(handshake.status, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: handshake.data) as? [String: Any])
        XCTAssertNotNil(envelope["result"])
        let client = Client(name: "Textley isolated test", version: "1")
        _ = try await client.connect(transport: transport(endpoint, token: token))
        let discovered = try await client.listTools()
        XCTAssertEqual(discovered.tools.count, 27)
        XCTAssertTrue(discovered.tools.allSatisfy { $0.annotations.title?.isEmpty == false })
        let vaults = try payload(try await client.callTool(name: "list_vaults", arguments: [:]))
        let vault = try XCTUnwrap((vaults["vaults"] as? [[String: Any]])?.first?["id"] as? String)
        let listed = try payload(try await client.callTool(name: "list_files", arguments: ["vault_id": .string(vault)]))
        let paths = try XCTUnwrap((listed["entries"] as? [[String: String]])?.compactMap { $0["path"] })
        XCTAssertEqual(Set(paths), ["Field Notes.md", "Nested", "Nested/Note.md"])
        let searched = try payload(try await client.callTool(name: "search_files", arguments: [
            "vault_id": .string(vault), "query": "unique trail marker", "search_contents": true
        ]))
        let matches = try XCTUnwrap((searched["entries"] as? [[String: String]])?.compactMap { $0["path"] })
        XCTAssertEqual(matches, ["Nested/Note.md"])
        let location: [String: Value] = ["vault_id": .string(vault), "path": "Field Notes.md"]
        let read = try payload(try await client.callTool(name: "read_file", arguments: location))
        XCTAssertEqual(read["text"] as? String, "# Draft\n")
        let denied = try await client.callTool(name: "open_file", arguments: location)
        XCTAssertEqual(denied.isError, true)
        for unsafe in ["../Outside.md", "Escape.md", "/etc/passwd", ".mcp.json"] {
            let rejected = try await client.callTool(name: "read_file", arguments: ["vault_id": .string(vault), "path": .string(unsafe)])
            XCTAssertEqual(rejected.isError, true, unsafe)
        }
        let missingToken = try await request(endpoint, token: nil)
        let browserOrigin = try await request(endpoint, token: token, origin: "https://example.com")
        XCTAssertEqual(missingToken.status, 401)
        XCTAssertEqual(browserOrigin.status, 403)

        service.setAllowsWriting(true)
        let opened = try payload(try await client.callTool(name: "open_file", arguments: location))
        let tab = try XCTUnwrap(opened["tab_id"] as? String)
        let readRevision = try XCTUnwrap(read["revision"] as? String)
        let edit: [String: Value] = [
            "tab_id": .string(tab), "expected_revision": .string(readRevision), "old_text": "Draft", "new_text": "Ready"
        ]
        let edited = try payload(try await client.callTool(name: "edit_text", arguments: edit))
        let editedRevision = try XCTUnwrap(edited["revision"] as? String)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Draft\n")
        let stale = try await client.callTool(name: "edit_text", arguments: edit)
        XCTAssertEqual(stale.isError, true)
        let dirtyClose = try await client.callTool(name: "close_tab", arguments: ["tab_id": .string(tab)])
        XCTAssertEqual(dirtyClose.isError, true)
        let save: [String: Value] = ["tab_id": .string(tab), "expected_revision": .string(editedRevision)]
        _ = try payload(try await client.callTool(name: "save_file", arguments: save))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Ready\n")

        if let probe = ProcessInfo.processInfo.environment["TEXTLEY_MCP_CLIENT_PROBE"] {
            try await checkInstalledClients(probe, endpoint: endpoint, token: token, folder: root)
        }

        let create: [String: Value] = ["vault_id": .string(vault), "path": "New.txt", "text": "created"]
        _ = try payload(try await client.callTool(name: "create_file", arguments: create))
        let duplicate = try await client.callTool(name: "create_file", arguments: create)
        XCTAssertEqual(duplicate.isError, true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("New.txt"), encoding: .utf8), "created")

        service.setAllowsWriting(false)
        let writeRevoked = try await client.callTool(name: "new_document", arguments: [:])
        XCTAssertEqual(writeRevoked.isError, true)
        if let bridgeBinary = ProcessInfo.processInfo.environment["TEXTLEY_NATIVE_BRIDGE_BINARY"] {
            try await checkDesktopBridge(endpoint: endpoint, token: token, binary: bridgeBinary)
            try await checkDesktopBridge(endpoint: endpoint, token: token, binary: nil)
        }
        await client.disconnect()
        await service.rotateToken()
        let newEndpoint = try XCTUnwrap(URL(string: service.endpoint))
        let oldTokenStatus = try await request(newEndpoint, token: token)
        XCTAssertEqual(oldTokenStatus.status, 401)
        XCTAssertNotEqual(service.accessToken, token)
        await service.setEnabled(false)
        XCTAssertFalse(service.enabled)
    }

    private func checkInstalledClients(_ probe: String, endpoint: URL, token: String, folder: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", probe, folder.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TEXTLEY_MCP_TEST_ENDPOINT"] = endpoint.absoluteString
        environment["TEXTLEY_MCP_TEST_TOKEN"] = token
        process.environment = environment
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw NSError(domain: "Textley MCP client test", code: Int(status)) }
        let fixture = folder.appendingPathComponent("Codex Acceptance.md")
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "# Verified through Codex\n")
    }

    private func checkDesktopBridge(endpoint: URL, token: String, binary: String?) async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", source.appendingPathComponent("Scripts/check-mcp-bridge.cjs").path]
        var environment = ProcessInfo.processInfo.environment
        environment["TEXTLEY_NATIVE_BRIDGE_BINARY"] = binary
        environment["TEXTLEY_BRIDGE_SCRIPT"] = source.appendingPathComponent("Resources/TextleyClaudeMCP/server.js").path
        environment["TEXTLEY_MCP_TEST_ENDPOINT"] = endpoint.absoluteString
        environment["TEXTLEY_MCP_TEST_TOKEN"] = token
        environment["TEXTLEY_MCP_URL"] = endpoint.absoluteString
        environment["TEXTLEY_MCP_TOKEN"] = token
        environment["TEXTLEY_BRIDGE_VAULT"] = "Vault"
        environment["TEXTLEY_BRIDGE_FILE"] = "Field Notes.md"
        environment["TEXTLEY_BRIDGE_TEXT"] = "# Ready"
        process.environment = environment
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        XCTAssertEqual(status, 0)
    }

    func testClaudeProjectConfigPreservesOtherServers() throws {
        let old = Data(#"{"mcpServers":{"jotley":{"type":"stdio","command":"/Applications/Jotley.app"}},"other":{"keep":true}}"#.utf8)
        let incoming = Data(#"{"mcpServers":{"textley":{"type":"stdio","command":"/Applications/Textley.app/Contents/MacOS/Textley","args":["--mcp-stdio"]}}}"#.utf8)
        let merged = try TextleyMCPDesktopSetup.mergedProjectConfiguration(existing: old, connection: incoming)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["jotley", "textley"])
        XCTAssertNotNil(json["other"])
        XCTAssertFalse(merged.replacesConnection)
        XCTAssertFalse(String(decoding: merged.data, as: UTF8.self).contains("access_token"))
        XCTAssertThrowsError(try TextleyMCPDesktopSetup.mergedProjectConfiguration(existing: Data("bad".utf8), connection: incoming))
    }

    private func transport(_ endpoint: URL, token: String) -> HTTPClientTransport {
        HTTPClientTransport(endpoint: endpoint, streaming: false, requestModifier: { request in
            var request = request
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        })
    }

    private func payload(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        let content = try XCTUnwrap(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.fileReadCorruptFile) }
        XCTAssertNotEqual(result.isError, true, text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func request(_ endpoint: URL, token: String?, origin: String? = nil, body: String = "{}") async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
