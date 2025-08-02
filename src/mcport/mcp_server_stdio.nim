import
  std/[streams, times, strformat, strutils, json],
  jsony,
  ./mcp_core

const
  LOG_FILE = "mcp_server.log"  ## Log file path

var
  logFile: File

proc logToFile(stream: char, msg: string) =
  ## Log a message to file and stderr with stream prefix.
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  let formattedMsg = fmt"[{timestamp}] {stream} {msg}"
  
  if logFile.isNil:
    logFile = open(LOG_FILE, fmAppend)
  logFile.writeLine(formattedMsg)
  logFile.flushFile()

proc log*(msg: string) =
  ## Log to stderr and file with 'E' prefix.
  logToFile('E', msg)
  stderr.writeLine(msg)
  stderr.flushFile()

proc sendMcpMessage[T](msg: T) =
  ## Send a properly formatted JSON-RPC message to stdout and log it.
  let jsonMsg = msg.toJson()
  stdout.write(jsonMsg)
  stdout.write("\n")
  stdout.flushFile()
  logToFile('O', "Sent: " & jsonMsg)

proc handleStdioRequest(server: McpServer, line: string) =
  ## Handle an incoming MCP request from stdin using the core server.
  logToFile('I', line)
  
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

proc runStdioServer*(server: McpServer) =
  ## Run the MCP server main loop using STDIO transport.
  log("STDIO MCP Server starting...")
  
  for line in stdin.lines:
    if line.len > 0:
      log("Received: " & line)
      handleStdioRequest(server, line.strip())
  
  if not logFile.isNil:
    log("Server shutting down...")
    logFile.close()

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
