import
  std/[algorithm, json, strformat, tables, sets],
  jsony,
  curly,
  ./[mcp_core, mcp_client_core]

type
  HttpMcpClient* = ref object
    client*: McpClient
    curly*: Curly
    baseUrl*: string
    logEnabled*: bool
    connected*: bool
    requestHeaders*: HttpHeaders
    timeoutSeconds*: int

proc log(client: HttpMcpClient, msg: string) =
  ## Log a message if logging is enabled.
  if client.logEnabled:
    echo fmt"[HTTP Client] {msg}"

proc newHttpMcpClient*(name: string, version: string, baseUrl: string, logEnabled: bool = true,
    requestHeaders: HttpHeaders = emptyHttpHeaders(), timeoutSeconds: int = 60): HttpMcpClient =
  ## Create a new HTTP MCP client.
  HttpMcpClient(
    client: newMcpClient(name, version),
    baseUrl: baseUrl,
    logEnabled: logEnabled,
    connected: false,
    requestHeaders: requestHeaders,
    timeoutSeconds: timeoutSeconds
  )

proc connect*(client: HttpMcpClient) =
  ## Initialize the HTTP client connection.
  if client.connected:
    return
  client.curly = newCurly()
  client.connected = true
  client.log(fmt"Connected to: {client.baseUrl}")

proc isConnected*(client: HttpMcpClient): bool =
  ## Check if the client is connected.
  client.connected

proc sendMessage(client: HttpMcpClient, message: string): curly.Response =
  if not client.connected:
    raise newException(CatchableError, "HTTP client not initialized")
  var headers = client.requestHeaders
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "application/json, text/event-stream"
  if client.client.protocolVersion.len > 0:
    headers["MCP-Protocol-Version"] = client.client.protocolVersion
  result = client.curly.post(client.baseUrl, headers, message, timeout = client.timeoutSeconds)
  if result.code < 200 or result.code >= 300:
    let status = result.code
    raise newException(CatchableError, fmt"MCP HTTP request failed with status {status}")

proc sendRequest(client: HttpMcpClient, request: ClientRequest): ClientResult =
  let response = client.sendMessage(request.toJson())
  let parsed = parseJson(response.body)
  if parsed{"jsonrpc"}.getStr() != "2.0" or parsed{"id"} != %request.id:
    raise newException(CatchableError, "Invalid or mismatched MCP response ID")
  if not parsed.hasKey("result") and not parsed.hasKey("error"):
    raise newException(CatchableError, "MCP response has no result or error")
  result = parseResponse(response.body)

proc initialize*(client: HttpMcpClient) =
  ## Initialize the connection with the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  client.log("Initializing connection...")

  # Send initialize request
  let initRequest = client.client.createInitializeRequest()
  let initResult = client.sendRequest(initRequest)

  if initResult.isError:
    let errorMessage = initResult.error.error.message
    client.log(fmt"Initialize failed: {errorMessage}")
    raise newException(CatchableError, fmt"Initialize failed: {errorMessage}")

  if not client.client.handleInitializeResponse(initResult):
    raise newException(CatchableError, "Failed to process initialize response")

  let notification = createNotificationInitialized()
  discard client.sendMessage(notification.toJson())
  client.log("Successfully initialized")

proc listTools*(client: HttpMcpClient) =
  ## List available tools from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  client.log("Listing available tools...")

  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")

  var
    cursor = ""
    cursors = initHashSet[string]()
    discovered = initTable[string, McpTool]()
  while true:
    let
      params = if cursor.len == 0: %*{} else: %*{"cursor": cursor}
      listRequest = client.client.createRequest("tools/list", params)
      listResult = client.sendRequest(listRequest)
    if listResult.isError:
      raise newException(CatchableError, "List tools failed: " & listResult.error.error.message)
    for toolJson in listResult.response.result["tools"]:
      let tool = fromJson($toolJson, McpTool)
      if discovered.hasKey(tool.name):
        raise newException(CatchableError, "Duplicate MCP tool: " & tool.name)
      discovered[tool.name] = tool
    cursor = listResult.response.result{"nextCursor"}.getStr()
    if cursor.len == 0:
      break
    if cursor in cursors:
      raise newException(CatchableError, "Repeated MCP tools/list cursor")
    cursors.incl(cursor)
  client.client.availableTools = discovered
  client.log("Tools list received successfully")

proc callTool*(client: HttpMcpClient, toolName: string, arguments: JsonNode = %*{}): JsonNode =
  ## Call a tool on the server and return the result content.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  client.log(fmt"Calling tool: {toolName}")

  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")

  let callRequest = client.client.createToolCallRequest(toolName, arguments)
  let callResult = client.sendRequest(callRequest)

  if callResult.isError:
    let errorMessage = callResult.error.error.message
    client.log(fmt"Tool call failed: {errorMessage}")
    raise newException(CatchableError, fmt"Tool call '{toolName}' failed: {errorMessage}")

  # Return the actual result content from the server
  return callResult.response.result

proc getAvailableTools*(client: HttpMcpClient): seq[string] =
  ## Get list of available tool names from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")

  client.listTools()
  for name in client.client.availableTools.keys:
    result.add(name)
  result.sort()

proc listPrompts*(client: HttpMcpClient): JsonNode =
  ## List available prompts from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createPromptsListRequest()
  let res = client.sendRequest(req)
  if res.isError:
    raise newException(CatchableError, fmt"List prompts failed: {res.error.error.message}")
  return res.response.result

proc getPrompt*(client: HttpMcpClient, name: string, arguments: JsonNode = %*{}): JsonNode =
  ## Get a prompt by name from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createPromptsGetRequest(name, arguments)
  let res = client.sendRequest(req)
  if res.isError:
    raise newException(CatchableError, fmt"Get prompt failed: {res.error.error.message}")
  return res.response.result

proc listResources*(client: HttpMcpClient): JsonNode =
  ## List available resources from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createResourcesListRequest()
  let res = client.sendRequest(req)
  if res.isError:
    raise newException(CatchableError, fmt"List resources failed: {res.error.error.message}")
  return res.response.result

proc readResource*(client: HttpMcpClient, uri: string): JsonNode =
  ## Read a resource by URI from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createResourcesReadRequest(uri)
  let res = client.sendRequest(req)
  if res.isError:
    raise newException(CatchableError, fmt"Read resource failed: {res.error.error.message}")
  return res.response.result

proc subscribeResource*(client: HttpMcpClient, uri: string): JsonNode =
  ## Subscribe to a resource by URI on the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createResourcesSubscribeRequest(uri)
  let res = client.sendRequest(req)
  if res.isError:
    raise newException(CatchableError, fmt"Subscribe resource failed: {res.error.error.message}")
  return res.response.result

# Note: Server-sent notifications are not supported by the HTTP client.
# HTTP is a request/response protocol with no server-push mechanism, so the
# server cannot send unsolicited notifications to the client.  If you need
# live notification delivery, use the STDIO client instead.

proc close*(client: HttpMcpClient) =
  ## Close the HTTP client connection.
  if client.connected:
    client.log("Closing HTTP connection...")
    client.curly.close()
    client.connected = false
    client.client.initialized = false
    client.log("Connection closed")

proc connectAndInitialize*(client: HttpMcpClient) =
  ## Connect to a server and initialize the connection.
  client.connect()

  try:
    client.initialize()
    client.listTools()
  except Exception as e:
    client.close()
    raise e

# Example usage function
proc createExampleHttpClient*(baseUrl: string = "http://localhost:8080"): HttpMcpClient =
  ## Create an example HTTP client for testing.
  newHttpMcpClient("TestHttpClient", "1.0.0", baseUrl)
