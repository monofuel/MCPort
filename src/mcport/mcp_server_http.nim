import
  std/[json, strformat, times, strutils, tables],
  jsony,
  mummy,
  mummy/routers,
  ./mcp_core

type
  AuthCallback* = proc(request: Request): bool {.gcsafe.}

  HttpMcpServer* = ref object
    server*: McpServer
    httpServer*: Server
    logEnabled*: bool
    authCb*: AuthCallback  ## Optional auth callback for HTTP requests
    notifications*: seq[JsonNode]  ## Queue of notifications for polling

proc log(httpServer: HttpMcpServer, msg: string) =
  ## Log a message with timestamp if logging is enabled.
  if httpServer.logEnabled:
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    echo fmt"[{timestamp}] HTTP MCP: {msg}"

proc httpNotificationCallback(httpServer: HttpMcpServer, notification: JsonNode) =
  ## Notification callback for HTTP transport - stores notifications in queue.
  httpServer.notifications.add(notification)

proc checkAuth(httpServer: HttpMcpServer, request: Request): bool =
  ## Check authorization using the configured auth callback.
  ## Returns true if authorized, false if not authorized or if auth callback throws.
  try:
    return httpServer.authCb(request)
  except Exception as e:
    httpServer.log("Auth callback error: " & e.msg)
    return false

proc handleJsonRpcRequest(httpServer: HttpMcpServer, request: Request) =
  ## Handle JSON-RPC requests to the /mcp endpoint.
  try:
    # Only accept POST requests for JSON-RPC
    if request.httpMethod != "POST":
      httpServer.log("Rejected non-POST request to /mcp: " & request.httpMethod)
      request.respond(405, body = "Method not allowed - use POST for JSON-RPC requests")
      return
    
    # Check content type (accept parameters like charset)
    var contentType = ""
    for (key, value) in request.headers:
      if key.toLowerAscii() == "content-type":
        contentType = value
        break
    
    let ct = contentType.toLowerAscii().strip()
    if ct.len == 0 or not ct.startsWith("application/json"):
      httpServer.log("Rejected /mcp request with invalid content-type: " & contentType)
      request.respond(400, body = "Content-Type must start with application/json")
      return

    # Authorization check using provided callback
    if not httpServer.checkAuth(request):
      var headers: HttpHeaders
      headers["content-type"] = "application/json"
      request.respond(401, headers, "{\"error\":\"Unauthorized\"}")
      return

    # Handle the MCP JSON-RPC request using the core server
    httpServer.log("Received JSON-RPC request: " & request.body)
    let result = httpServer.server.handleRequest(request.body)
    
    var headers: HttpHeaders
    headers["content-type"] = "application/json"
    
    if result.isError:
      let errorJson = result.error.toJson()
      httpServer.log("Sent JSON-RPC error: " & errorJson)
      request.respond(200, headers, errorJson)  # JSON-RPC errors are still HTTP 200
    else:
      # Handle notifications that don't need responses (empty result object)
      if result.response.result == %*{}:
        httpServer.log("JSON-RPC notification processed, no response")
        request.respond(204)  # No content for notifications
      else:
        let responseJson = result.response.toJson()
        httpServer.log("Sent JSON-RPC response: " & responseJson)
        request.respond(200, headers, responseJson)
    
  except Exception as e:
    httpServer.log("Error handling JSON-RPC request: " & e.msg)
    # Return a JSON-RPC error for unexpected exceptions
    let errorResponse = createError(0, -32603, "Internal error: " & e.msg)
    var headers: HttpHeaders
    headers["content-type"] = "application/json"
    request.respond(500, headers, errorResponse.toJson())

proc handleServerInfoRequest(httpServer: HttpMcpServer, request: Request) =
  ## Handle server metadata requests to the /server-info endpoint.
  try:
    # Accept both GET and POST for server info
    if request.httpMethod != "GET" and request.httpMethod != "POST":
      httpServer.log("Rejected invalid method for /server-info: " & request.httpMethod)
      request.respond(405, body = "Method not allowed - use GET or POST for server info")
      return

    # Authorization check using provided callback
    if not httpServer.checkAuth(request):
      var headers: HttpHeaders
      headers["content-type"] = "application/json"
      request.respond(401, headers, "{\"error\":\"Unauthorized\"}")
      return

    # Create server metadata response
    let serverInfo = %*{
      "name": httpServer.server.serverInfo.name,
      "version": httpServer.server.serverInfo.version,
      "capabilities": ["tools", "resources", "prompts"],
      "endpoints": {
        "jsonrpc": "/mcp",
        "server_info": "/server-info"
      },
      "tools_count": len(httpServer.server.tools),
      "description": "MCP Server over HTTP"
    }

    var headers: HttpHeaders
    headers["content-type"] = "application/json"

    let responseJson = serverInfo.toJson()
    httpServer.log("Sent server info response")
    request.respond(200, headers, responseJson)

  except Exception as e:
    httpServer.log("Error handling server info request: " & e.msg)
    request.respond(500, body = "Error generating server information")

proc handleNotificationsRequest(httpServer: HttpMcpServer, request: Request) =
  ## Handle notification polling requests to the /notifications endpoint.
  try:
    # Accept GET requests for polling notifications
    if request.httpMethod != "GET":
      httpServer.log("Rejected invalid method for /notifications: " & request.httpMethod)
      request.respond(405, body = "Method not allowed - use GET for notifications")
      return

    # Authorization check using provided callback
    if not httpServer.checkAuth(request):
      var headers: HttpHeaders
      headers["content-type"] = "application/json"
      request.respond(401, headers, "{\"error\":\"Unauthorized\"}")
      return

    # Return all pending notifications and clear the queue
    let notifications = httpServer.notifications
    httpServer.notifications = @[]  # Clear the queue

    let response = %*{"notifications": notifications}
    var headers: HttpHeaders
    headers["content-type"] = "application/json"

    let responseJson = response.toJson()
    httpServer.log(&"Sent {notifications.len} notifications")
    request.respond(200, headers, responseJson)

  except Exception as e:
    httpServer.log("Error handling notifications request: " & e.msg)
    request.respond(500, body = "Error retrieving notifications")

proc newHttpMcpServer*(mcpServer: McpServer, logEnabled: bool = true, authCb: AuthCallback = nil): HttpMcpServer =
  ## Create a new HTTP MCP server wrapper.

  # Default to always-authorized if no auth callback provided
  let finalAuthCb = if authCb != nil: authCb else:
    (proc(request: Request): bool {.gcsafe.} = true)

  let httpMcpServer = HttpMcpServer(
    server: mcpServer,
    logEnabled: logEnabled,
    authCb: finalAuthCb,
    notifications: @[]
  )

  # Set up notification callback for the MCP server
  mcpServer.setNotificationCallback(proc(notification: JsonNode) =
    httpNotificationCallback(httpMcpServer, notification)
  )
  
  # Set up router with MCP endpoints
  var router: Router
  
  # Logging middleware - logs ALL requests
  proc loggingMiddleware(request: Request) {.gcsafe.} =
    httpMcpServer.log(&"Incoming request: {request.httpMethod} {request.uri}")
    httpMcpServer.log(&"Headers: {request.headers}")
    if request.body.len > 0:
      httpMcpServer.log(&"Body: {request.body}")
  
  # JSON-RPC endpoint for MCP interactions
  proc mcpHandler(request: Request) {.gcsafe.} =
    loggingMiddleware(request)
    httpMcpServer.handleJsonRpcRequest(request)
  
  # Server info endpoint
  proc serverInfoHandler(request: Request) {.gcsafe.} =
    loggingMiddleware(request)
    httpMcpServer.handleServerInfoRequest(request)

  # Notifications polling endpoint
  proc notificationsHandler(request: Request) {.gcsafe.} =
    loggingMiddleware(request)
    httpMcpServer.handleNotificationsRequest(request)

  # Catch-all handler for invalid routes
  proc invalidRouteHandler(request: Request) {.gcsafe.} =
    loggingMiddleware(request)
    httpMcpServer.log(&"Invalid route accessed: {request.uri}")
    request.respond(404, body = "Not found - valid endpoints: /mcp, /server-info, /notifications")
  
  # main MCP endpoint!
  router.post("/mcp", mcpHandler)

  # server-info is not part of the MCP spec but useful for debugging.
  router.get("/server-info", serverInfoHandler)
  router.post("/server-info", serverInfoHandler)

  # notifications polling endpoint
  router.get("/notifications", notificationsHandler)

  # Add catch-all routes for invalid endpoints
  router.get("/*", invalidRouteHandler)
  router.post("/*", invalidRouteHandler)
  router.put("/*", invalidRouteHandler)
  router.delete("/*", invalidRouteHandler)
  router.patch("/*", invalidRouteHandler)
  
  httpMcpServer.httpServer = newServer(router)
  return httpMcpServer

proc serve*(httpServer: HttpMcpServer, port: int, address: string = "localhost") =
  ## Start serving the HTTP MCP server on the specified port and address.
  let portStr = $port
  httpServer.log(&"Starting HTTP MCP server on {address}:{portStr}")
  httpServer.httpServer.serve(Port(port), address)

proc clearNotifications*(httpServer: HttpMcpServer) =
  ## Clear all pending notifications (useful for testing).
  httpServer.notifications = @[]

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
