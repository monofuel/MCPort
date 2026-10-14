import
  std/[json, options, os, strutils],
  mummy, mcport

let server = newMcpServer("events-fixture", "1")
server.enableModernProtocol(experimentalEvents = true, heartbeatMs = 100)
server.registerEvent(EventDefinition(name: "message", inputSchema: %*{}, payloadSchema: %*{}))
server.registerEvent(EventDefinition(name: "checked", inputSchema: %*{}, payloadSchema: %*{}),
  check = proc(context: RequestContext, request: EventPollRequest): EventBatch =
    if request.cursor.isNone:
      return EventBatch(cursor: some("start"), nextPollMs: 1000)
    if request.cursor.get == "start":
      return EventBatch(events: @[EventOccurrence(name: "checked", eventId: "checked",
        timestamp: "2026-01-01T00:00:00Z", data: %*{"checked": true}, cursor: some("end"))], cursor: some("end"), nextPollMs: 1000)
    EventBatch(cursor: request.cursor, nextPollMs: 1000),
  authorize = proc(context: RequestContext, arguments: JsonNode) =
    if context.transport in {WebSocketTransport, HttpTransport} and context.auth{"account"}.getStr() != "tests":
      raise eventError(-32024, "Missing account context")
    if arguments{"deny"}.getBool():
      raise eventError(-32024, "Forbidden"))
server.registerTool(McpTool(name: "shutdown", inputSchema: %*{}), proc(arguments: JsonNode): JsonNode =
  {.cast(gcsafe).}:
    server.closeSubscriptions(graceful = true)
    %*{"content": []})
server.registerTool(McpTool(name: "publish", inputSchema: %*{}), proc(arguments: JsonNode): JsonNode =
  {.cast(gcsafe).}:
    server.emitEvent(EventOccurrence(name: "message", data: arguments))
    server.notifyResourceUpdated("test://one")
    server.notifyToolsListChanged()
    %*{"content": []})
if paramCount() == 0:
  server.runStdioServer()
else:
  let auth = proc(request: Request): bool {.gcsafe.} = request.headers["Authorization"] == "Bearer test"
  let http = newHttpMcpServer(server, logEnabled = false, enableWebSocket = true, authCb = auth,
    authContext = proc(request: Request): JsonNode = %*{"account": "tests"})
  http.serve(parseInt(paramStr(1)), "127.0.0.1")
