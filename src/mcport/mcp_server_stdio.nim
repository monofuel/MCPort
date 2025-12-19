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
  except:
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
  

proc createExampleServer*(): McpServer =
  ## Create an example MCP server with a sample tool.
  let server = newMcpServer("NimMCPServer", "1.0.0")
  
  # Register the example shibboleet tool
  let shibboleetTool = McpTool(
    name: "secret_fetcher",
    description: "Delivers a secret leet greeting from the universe",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "recipient": {
          "type": "string",
          "description": "Who to greet (optional)"
        }
      },
      "required": [],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )
  
  proc shibboleetHandler(arguments: JsonNode): JsonNode =
    let recipient = if arguments.hasKey("recipient"): arguments["recipient"].getStr() else: "friend"
    return %*("Shibboleet says: Leet greetings from the universe! Hello, " & recipient & "!")
  
  server.registerTool(shibboleetTool, shibboleetHandler)
  return server

when isMainModule:
  let server = createExampleServer()
  runStdioServer(server) 
