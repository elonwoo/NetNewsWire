import Darwin
import Foundation
import MCP
import NetNewsWireMCPCore

func writeStderr(_ message: String) {
    let line = "NetNewsWireMCP: " + message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

do {
    let context = try Startup.prepare()
    for line in context.diagnostics {
        writeStderr(line)
    }

    let server = Server(
        name: "netnewswire-mcp",
        version: "0.1.0",
        title: "NetNewsWire MCP",
        capabilities: Server.Capabilities(tools: .init())
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: ToolCatalog.serverTools)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
        ToolDispatcher.call(
            name: parameters.name, arguments: parameters.arguments, context: context)
    }

    let transport = StdioTransport()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
} catch let error as StartupError {
    writeStderr(error.message)
    exit(error.code)
} catch {
    writeStderr("启动失败：\(error)")
    exit(1)
}
