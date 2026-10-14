import
  std/[json, os],
  mcport

const PortNumber = 8097

let server = newMcpServer("events-example", "1")
server.enableModernProtocol(experimentalEvents = true)
server.registerEvent(EventDefinition(name: "message", description: "A published message.",
  inputSchema: %*{"type": "object"}, payloadSchema: %*{"type": "object"}))
server.registerTool(McpTool(name: "publish", description: "Publish a message event.",
  inputSchema: %*{"type": "object"}), proc(arguments: JsonNode): JsonNode =
    {.cast(gcsafe).}:
      server.emitEvent(EventOccurrence(name: "message", data: arguments))
      %*{"content": []})
if paramCount() > 0 and paramStr(1) == "--stdio":
  server.runStdioServer()
else:
  let http = newHttpMcpServer(server, logEnabled = false, enableWebSocket = true)
  http.serve(PortNumber, "127.0.0.1")
