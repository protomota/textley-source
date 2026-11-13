import Foundation
import Logging
import MCP

/// The agent launches the existing app executable in this mode. It does not
/// instantiate SwiftUI, open Core Data or enable access. Only the running app
/// accesses the library and enforces permission/revision checks.
enum TextleyMCPStdioBridge {
    static func run() async {
        do {
            let connection = try configuration()
            try await forward(endpoint: connection.endpoint, token: connection.token)
        } catch {
            // Never include requests, note content or credentials in diagnostics.
            FileHandle.standardError.write(Data("Open Textley, enable MCP access in Settings → Integrations → MCP, and restart this server in your agent. If macOS asks, approve Textley’s existing Keychain access.\n".utf8))
            exit(1)
        }
    }

    private static func configuration() throws -> (endpoint: URL, token: String) {
        #if DEBUG
        // Integration harness only; these overrides are absent from Release.
        if let address = ProcessInfo.processInfo.environment["TEXTLEY_MCP_TEST_ENDPOINT"],
           let token = ProcessInfo.processInfo.environment["TEXTLEY_MCP_TEST_TOKEN"],
           let endpoint = URL(string: address), endpoint.scheme == "http", endpoint.host == "127.0.0.1",
           endpoint.path == "/mcp", token.count == 64 {
            return (endpoint, token)
        }
        #endif
        guard let token = try TextleyMCPToken.loadExisting() else {
            throw MCPAccessError.message("Enable MCP in Textley first.")
        }
        return (URL(string: "http://127.0.0.1:\(TextleyMCPService.defaultPort)/mcp")!, token)
    }

    static func forward(endpoint: URL, token: String) async throws {
        let client = Client(name: "Textley desktop bridge", version: "1.0.3")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 660
        let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false, requestModifier: { request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        })
        do {
            let upstream = try await client.connect(transport: transport)
            let server = Server(name: "Textley", version: "1.0.3", instructions: upstream.instructions, capabilities: .init(tools: .init()))
            await server.withMethodHandler(ListTools.self) { parameters in
                let context = try await client.send(ListTools.request(parameters))
                return try await context.value
            }
            await server.withMethodHandler(CallTool.self) { parameters in
                let context = try await client.send(CallTool.request(parameters))
                return try await context.value
            }
            try await server.start(transport: TextleyStdioTransport())
            await server.waitUntilCompleted()
            await server.stop()
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

private actor TextleyStdioTransport: Transport {
    private let stdio = StdioTransport()
    nonisolated var logger: Logger { stdio.logger }

    func connect() async throws { try await stdio.connect() }
    func disconnect() async { await stdio.disconnect() }
    func send(_ data: Data) async throws { try await stdio.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await message in await stdio.receive() {
                        continuation.yield(TextleyMCPInitialization.normalized(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}

enum TextleyMCPInitialization {
    static func normalized(_ message: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              experimental.values.contains(where: { !($0 is String) }) else { return message }

        // The Swift SDK expects strings here. MCP clients can send objects, and Textley doesn't use experimental capabilities.
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? message
    }
}
