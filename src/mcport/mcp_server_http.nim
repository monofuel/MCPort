import
  std/[json, strformat, times, strutils],
  jsony,
  mummy,
  ./mcp_core

type
  HttpMcpServer* = ref object
    server*: McpServer
    httpServer*: Server
    logEnabled*: bool

proc log(httpServer: HttpMcpServer, msg: string) =
  ## Log a message with timestamp if logging is enabled.
  if httpServer.logEnabled:
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    echo fmt"[{timestamp}] HTTP MCP: {msg}"

proc handleMcpRequest(httpServer: HttpMcpServer, request: Request) =
  ## Handle incoming HTTP JSON-RPC requests.
  try:
    # Only accept POST requests
    if request.httpMethod != "POST":
      httpServer.log("Rejected non-POST request: " & request.httpMethod)
      request.respond(405, body = "Method not allowed - use POST")
      return
    
    # Check content type
    var contentType = ""
    for (key, value) in request.headers:
      if key.toLowerAscii() == "content-type":
        contentType = value
        break
    
    if contentType != "application/json":
      httpServer.log("Rejected request with invalid content-type: " & contentType)
      request.respond(400, body = "Content-Type must be application/json")
      return
    
    # Handle the MCP request using the core server
    httpServer.log("Received: " & request.body)
    let result = httpServer.server.handleRequest(request.body)
    
    var headers: HttpHeaders
    headers["content-type"] = "application/json"
    
    if result.isError:
      let errorJson = result.error.toJson()
      httpServer.log("Sent error: " & errorJson)
      request.respond(200, headers, errorJson)  # JSON-RPC errors are still HTTP 200
    else:
      # Handle notifications that don't need responses (id = 0)
      if result.response.id == 0:
        httpServer.log("Notification processed, no response")
        request.respond(204)  # No content for notifications
      else:
        let responseJson = result.response.toJson()
        httpServer.log("Sent response: " & responseJson)
        request.respond(200, headers, responseJson)
    
  except Exception as e:
    httpServer.log("Error handling request: " & e.msg)
    # Return a JSON-RPC error for unexpected exceptions
    let errorResponse = createError(0, -32603, "Internal error: " & e.msg)
    var headers: HttpHeaders
    headers["content-type"] = "application/json"
    request.respond(500, headers, errorResponse.toJson())

proc newHttpMcpServer*(mcpServer: McpServer, logEnabled: bool = true): HttpMcpServer =
  ## Create a new HTTP MCP server wrapper.
  let httpMcpServer = HttpMcpServer(
    server: mcpServer,
    logEnabled: logEnabled
  )
  
  proc requestHandler(request: Request) {.gcsafe.} =
    httpMcpServer.handleMcpRequest(request)
  
  httpMcpServer.httpServer = newServer(requestHandler)
  return httpMcpServer

proc serve*(httpServer: HttpMcpServer, port: int, address: string = "localhost") =
  ## Start serving the HTTP MCP server on the specified port and address.
  let portStr = $port
  httpServer.log(&"Starting HTTP MCP server on {address}:{portStr}")
  httpServer.httpServer.serve(Port(port), address)

proc close*(httpServer: HttpMcpServer) =
  ## Close the HTTP MCP server.
  httpServer.log("Shutting down HTTP MCP server")
  if httpServer.httpServer != nil:
    httpServer.httpServer.close()

proc createExampleHttpServer*(): HttpMcpServer =
  ## Create an example HTTP MCP server with a sample tool.
  let mcpServer = newMcpServer("NimHTTPMCPServer", "1.0.0")
  
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
  
  mcpServer.registerTool(shibboleetTool, shibboleetHandler)
  return newHttpMcpServer(mcpServer)

when isMainModule:
  let server = createExampleHttpServer()
  server.serve(8097, "0.0.0.0") 
