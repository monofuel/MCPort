import
  std/[streams, strutils, json],
  jsony,
  ./mcp_core

proc log*(msg: string) =
  stderr.writeLine(msg)
  stderr.flushFile()

proc sendMcpMessage[T](msg: T) =
  ## Send a properly formatted JSON-RPC message to stdout.
  let jsonMsg = msg.toJson()
  stdout.write(jsonMsg)
  stdout.write("\n")
  stdout.flushFile()


proc stdioNotificationCallback(notification: JsonNode) =
  ## Notification callback for STDIO transport - sends notifications to stdout.
  sendMcpMessage(notification)

proc handleStdioRequest(server: McpServer, line: string) =
  ## Handle an incoming MCP request from stdin using the core server.

  # Check if the incoming message is a notification (no 'id' field) or request (has 'id' field)
  let isNotification = try:
    let parsed = line.parseJson()
    not parsed.hasKey("id")
  except jsony.JsonError as e:
    log("JSON parsing failed for incoming message: " & e.msg)
    false  # If parsing fails, assume it's a request so we send an error response

  let result = server.handleRequest(line)

  if result.isError:
    # Always send error responses, even for malformed notifications
    sendMcpMessage(result.error)
  else:
    # Only send success responses for requests, not for notifications
    if not isNotification:
      sendMcpMessage(result.response)

proc runStdioServer*(server: McpServer, notificationCallback: NotificationCallback = nil) =
  ## Run the MCP server main loop using STDIO transport.
  ## notificationCallback: Optional callback for sending notifications to the client.
  log("STDIO MCP Server starting...")

  # Set up notification callback - use provided one or default STDIO callback
  let callback = if notificationCallback != nil: notificationCallback else: stdioNotificationCallback
  server.setNotificationCallback(callback)

  for line in stdin.lines:
    if line.len > 0:
      log("Received: " & line)
      handleStdioRequest(server, line.strip())
  

when isMainModule:
  let server = createExampleServer()
  runStdioServer(server) 
