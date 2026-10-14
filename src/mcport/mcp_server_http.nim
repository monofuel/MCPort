import
  std/[json, locks, strformat, times, strutils, tables],
  jsony,
  mummy,
  mummy/routers,
  ./[mcp_core, mcp_extensions, mcp_http_metadata]

type
  AuthContextCallback* = proc(request: Request): JsonNode {.gcsafe.}
  AuthCallback* = proc(request: Request): bool {.gcsafe.}
  ## Register extra routes on the HTTP router *before* the MCP catch-all.
  ## Used by hosts that serve a dashboard (or other GETs) next to /mcp.
  ExtraRoutesCallback* = proc(router: var Router) {.gcsafe.}

  HttpMcpServer* = ref object
    server*: McpServer
    httpServer*: Server
    logEnabled*: bool
    authCb*: AuthCallback  ## Optional auth callback for HTTP requests
    notifications*: seq[JsonNode]  ## Queue of notifications for polling
    webSocketContexts: Table[WebSocket, tuple[connectionId, auth: string, target: pointer]]
    connectionCounter: int
    authContext: AuthContextCallback
    allowedOrigins: seq[string]
    notifLock*: Lock              ## Protects notifications from concurrent access

proc sendWebSocketContext(target: pointer, message: JsonNode) {.gcsafe.} =
  cast[ptr WebSocket](target)[].send($message)

proc log(httpServer: HttpMcpServer, msg: string) =
  ## Log a message with timestamp if logging is enabled.
  if httpServer.logEnabled:
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    echo fmt"[{timestamp}] HTTP MCP: {msg}"

proc httpNotificationCallback(httpServer: HttpMcpServer, notification: JsonNode) =
  ## Notification callback for HTTP transport - stores notifications in queue.
  withLock httpServer.notifLock:
    if notification{"method"}.getStr() != "notifications/resources/updated" or
        notification{"params", "uri"}.getStr() in httpServer.server.resourceSubscriptions:
      httpServer.notifications.add(notification.copy())

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

    # Parse the body once to detect notifications (no 'id' field) before calling
    # handleRequest, so we don't rely on the fragile %*{} sentinel value.
    let parsedBody = request.body.parseJson()
    let isNotification = parsedBody.kind == JObject and not parsedBody.hasKey("id")

    # Handle the MCP JSON-RPC request using the core server
    httpServer.log("Received JSON-RPC request: " & request.body)
    let context = RequestContext(transport: HttpTransport,
      auth: (if httpServer.authContext != nil: httpServer.authContext(request) else: nil))
    let metadataVersion = parsedBody{"params", "_meta", ProtocolVersionKey}.getStr()
    if metadataVersion.len > 0 and parsedBody{"method"}.getStr() != "server/discover":
      if request.headers["MCP-Protocol-Version"] != metadataVersion:
        var headers: HttpHeaders
        headers["Content-Type"] = "application/json"
        let error = createError(parsedBody{"id"}, -32020, "Protocol version header mismatch")
        request.respond(400, headers, error.toJson())
        return
    elif request.headers["MCP-Protocol-Version"] == ModernProtocolVersion and parsedBody{"method"}.getStr() != "server/discover":
      var headers: HttpHeaders
      headers["Content-Type"] = "application/json"
      request.respond(400, headers, createError(parsedBody{"id"}, -32600, "Request metadata is required").toJson())
      return
    if metadataVersion == ModernProtocolVersion:
      let origin = request.headers["Origin"]
      if origin.len > 0 and origin notin httpServer.allowedOrigins:
        request.respond(403)
        return
      var mismatch = request.headers["Mcp-Method"] != parsedBody{"method"}.getStr()
      try:
        if parsedBody{"method"}.getStr() in ["tools/call", "resources/read", "prompts/get"]:
          mismatch = mismatch or decodeHeaderValue(request.headers["Mcp-Name"]) != parsedBody.requestName()
        if parsedBody{"method"}.getStr() == "tools/call" and parsedBody.requestName() in httpServer.server.tools:
          for (key, value) in parameterHeaders(httpServer.server.tools[parsedBody.requestName()].inputSchema, parsedBody{"params", "arguments"}):
            mismatch = mismatch or decodeHeaderValue(request.headers[key]) != decodeHeaderValue(value)
      except ValueError:
        mismatch = true
      if mismatch:
        var headers: HttpHeaders
        headers["Content-Type"] = "application/json"
        request.respond(400, headers, createError(parsedBody{"id"}, -32020, "Request header mismatch").toJson())
        return
    let result = httpServer.server.handleRequest(request.body, context)

    var headers: HttpHeaders
    headers["content-type"] = "application/json"

    if result.isError:
      let errorJson = result.error.toJson()
      httpServer.log("Sent JSON-RPC error: " & errorJson)
      request.respond((if metadataVersion == ModernProtocolVersion and result.error.error.code == -32601: 404 elif metadataVersion.len > 0 and result.error.error.code in [-32022, -32600]: 400 else: 200), headers, errorJson)  # JSON-RPC errors are still HTTP 200
    elif isNotification:
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
    var notifications: seq[JsonNode]
    withLock httpServer.notifLock:
      notifications = httpServer.notifications
      httpServer.notifications = @[]

    let response = %*{"notifications": notifications}
    var headers: HttpHeaders
    headers["content-type"] = "application/json"

    let responseJson = response.toJson()
    httpServer.log(&"Sent {notifications.len} notifications")
    request.respond(200, headers, responseJson)

  except Exception as e:
    httpServer.log("Error handling notifications request: " & e.msg)
    request.respond(500, body = "Error retrieving notifications")

proc newHttpMcpServer*(
    mcpServer: McpServer,
    logEnabled: bool = true,
    authCb: AuthCallback = nil,
    registerExtra: ExtraRoutesCallback = nil,
    enableWebSocket = false,
    authContext: AuthContextCallback = nil,
    allowedOrigins: seq[string] = @[]
): HttpMcpServer =
  ## Create a new HTTP MCP server wrapper.
  ## Optional registerExtra adds host routes (e.g. a dashboard) before the
  ## catch-all 404 handlers so they do not steal /mcp.

  # Default to always-authorized if no auth callback provided
  let finalAuthCb = if authCb != nil: authCb else:
    (proc(request: Request): bool {.gcsafe.} = true)

  let httpMcpServer = HttpMcpServer(
    server: mcpServer,
    logEnabled: logEnabled,
    authCb: finalAuthCb,
    notifications: @[], authContext: authContext, allowedOrigins: allowedOrigins
  )
  initLock(httpMcpServer.notifLock)

  # Set up notification callback for the MCP server
  mcpServer.notificationSinks.add(proc(notification: JsonNode) =
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
    request.respond(404, body = "Not found - valid endpoints: /mcp, /server-info, /notifications, /")
  
  if enableWebSocket:
    if mcpServer.extensionState == nil:
      raise newException(ValueError, "Enable modern protocol before WebSocket transport")
    proc upgradeHandler(request: Request) {.gcsafe.} =
      if request.headers["Origin"].len > 0 and request.headers["Origin"] notin allowedOrigins:
        request.respond(403)
        return
      if not httpMcpServer.checkAuth(request):
        request.respond(401)
        return
      let auth = if authContext != nil: $authContext(request) else: "null"
      let socket = request.upgradeToWebSocket()
      let target = cast[ptr WebSocket](allocShared0(sizeof(WebSocket)))
      target[] = socket
      withLock httpMcpServer.notifLock:
        inc httpMcpServer.connectionCounter
        let wrapperId = $cast[uint](httpMcpServer)
        httpMcpServer.webSocketContexts[socket] = ("ws:" & wrapperId & ":" & $httpMcpServer.connectionCounter, auth, cast[pointer](target))
    router.get("/mcp/ws", upgradeHandler)

  # main MCP endpoint!
  router.post("/mcp", mcpHandler)
  proc unsupportedMethod(request: Request) {.gcsafe.} =
    request.respond(405, body = "Use POST for JSON requests; use WebSocket or stdio for push")
  router.get("/mcp", unsupportedMethod)
  router.delete("/mcp", unsupportedMethod)

  # server-info is not part of the MCP spec but useful for debugging.
  router.get("/server-info", serverInfoHandler)
  router.post("/server-info", serverInfoHandler)

  # notifications polling endpoint
  router.get("/notifications", notificationsHandler)

  # Host-provided routes (dashboard, health pages, …) before the catch-all.
  if registerExtra != nil:
    registerExtra(router)

  # Add catch-all routes for invalid endpoints
  router.get("/*", invalidRouteHandler)
  router.post("/*", invalidRouteHandler)
  router.put("/*", invalidRouteHandler)
  router.delete("/*", invalidRouteHandler)
  router.patch("/*", invalidRouteHandler)
  
  proc webSocketHandler(socket: WebSocket, event: WebSocketEvent, message: Message) {.gcsafe.} =
    var context: RequestContext
    withLock httpMcpServer.notifLock:
      if socket notin httpMcpServer.webSocketContexts:
        return
      let stored = httpMcpServer.webSocketContexts[socket]
      context = RequestContext(transport: WebSocketTransport,
        connectionId: stored.connectionId, auth: parseJson(stored.auth),
        sender: sendWebSocketContext, sendTarget: stored.target)
      if event in {CloseEvent, ErrorEvent}:
        httpMcpServer.webSocketContexts.del(socket)
    case event
    of MessageEvent:
      if message.kind == TextMessage:
        let response = mcpServer.handleRequest(message.data, context)
        if response.isError:
          socket.send(response.error.toJson())
        elif not response.deferred and parseJson(message.data).hasKey("id"):
          socket.send(response.response.toJson())
      elif message.kind == Ping:
        socket.send(message.data, Pong)
      elif message.kind == BinaryMessage:
        socket.close()
    of CloseEvent, ErrorEvent:
      mcpServer.closeSubscriptions(context.connectionId)
      deallocShared(context.sendTarget)
    of OpenEvent:
      discard
  httpMcpServer.httpServer = newServer(router, webSocketHandler)
  return httpMcpServer

proc serve*(httpServer: HttpMcpServer, port: int, address: string = "localhost") =
  ## Start serving the HTTP MCP server on the specified port and address.
  if httpServer.httpServer == nil:
    raise newException(ValueError, "HTTP server is closed")
  let portStr = $port
  httpServer.log(&"Starting HTTP MCP server on {address}:{portStr}")
  httpServer.server.freezeEvents()
  defer:
    httpServer.server.closeSubscriptions()
    withLock httpServer.notifLock:
      for stored in httpServer.webSocketContexts.values:
        deallocShared(stored.target)
      httpServer.webSocketContexts.clear()
      httpServer.httpServer = nil
  httpServer.httpServer.serve(Port(port), address)

proc clearNotifications*(httpServer: HttpMcpServer) =
  ## Clear all pending notifications (useful for testing).
  withLock httpServer.notifLock:
    httpServer.notifications = @[]

proc close*(httpServer: HttpMcpServer) =
  ## Close the HTTP MCP server.
  httpServer.log("Shutting down HTTP MCP server")
  httpServer.server.closeSubscriptions(graceful = true)
  if httpServer.httpServer != nil:
    httpServer.httpServer.close()
    httpServer.httpServer = nil

proc createExampleHttpServer*(): HttpMcpServer =
  ## Create an example HTTP MCP server with a sample tool.
  return newHttpMcpServer(createExampleServer("NimHTTPMCPServer"))

when isMainModule:
  let server = createExampleHttpServer()
  server.serve(8097, "0.0.0.0") 
