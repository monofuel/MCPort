import
  std/[json, locks, strutils, tables],
  jsony,
  ./[mcp_core, mcp_extensions]

type
  StdioWriter = ref object
    gate: Lock
    modern: bool

proc log*(msg: string) =
  stderr.writeLine(msg)
  stderr.flushFile()

proc sendStdioContext(target: pointer, message: JsonNode) {.gcsafe.} =
  let writer {.cursor.} = cast[StdioWriter](target)
  withLock writer.gate:
    stdout.writeLine($message)
    stdout.flushFile()

proc runStdioServer*(server: McpServer, notificationCallback: NotificationCallback = nil) =
  server.freezeEvents()
  let writer = StdioWriter()
  initLock(writer.gate)
  proc send(message: JsonNode) {.gcsafe.} =
    withLock writer.gate:
      stdout.writeLine($message)
      stdout.flushFile()
  let context = RequestContext(transport: StdioTransport, connectionId: "stdio",
    sender: sendStdioContext, sendTarget: cast[pointer](writer))
  server.notificationSinks.add(proc(message: JsonNode) =
    var legacy: bool
    withLock writer.gate:
      legacy = not writer.modern
    if legacy and (message{"method"}.getStr() != "notifications/resources/updated" or
        message{"params", "uri"}.getStr() in server.resourceSubscriptions):
      send(message))
  if notificationCallback != nil:
    server.setNotificationCallback(notificationCallback)
  defer: server.closeSubscriptions(graceful = true)
  for line in stdin.lines:
    if line.strip.len == 0:
      continue
    var notification = false
    try:
      let message = parseJson(line)
      notification = message.kind == JObject and not message.hasKey("id")
      if message{"params", "_meta", ProtocolVersionKey}.getStr() == ModernProtocolVersion:
        withLock writer.gate:
          writer.modern = true
    except JsonParsingError:
      notification = false
    let response = server.handleRequest(line, context)
    if response.isError:
      send(parseJson(response.error.toJson()))
    elif not response.deferred and not notification:
      send(parseJson(response.response.toJson()))

when isMainModule:
  runStdioServer(createExampleServer())
