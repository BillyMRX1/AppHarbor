import AppHarborMCPBridge
import MCP
import Foundation
import Darwin

@main
enum AppHarborMCPMain {
    static func main() async {
        do {
            let server = await MCPToolServer.makeServer()
            try await server.start(transport: MCP.StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            let line = "AppHarbor MCP server failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(line.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
