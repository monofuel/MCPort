import
  std/[json, strformat],
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

proc log(client: HttpMcpClient, msg: string) =
  ## Log a message if logging is enabled.
  if client.logEnabled:
    echo fmt"[HTTP Client] {msg}"

proc newHttpMcpClient*(name: string, version: string, baseUrl: string, logEnabled: bool = true): HttpMcpClient =
  ## Create a new HTTP MCP client.
  HttpMcpClient(
    client: newMcpClient(name, version),
    baseUrl: baseUrl,
    logEnabled: logEnabled,
    connected: false
  )

proc connect*(client: HttpMcpClient) =
  ## Initialize the HTTP client connection.
  client.curly = newCurly()
  client.connected = true
  client.log(fmt"Connected to: {client.baseUrl}")

proc isConnected*(client: HttpMcpClient): bool =
  ## Check if the client is connected.
  client.connected

proc sendRequest(client: HttpMcpClient, request: ClientRequest): ClientResult =
  ## Send a JSON-RPC request via HTTP.
  if not client.connected:
    raise newException(CatchableError, "HTTP client not initialized")

  try:
    let jsonRequest = request.toJson()
    client.log(fmt"Sending: {jsonRequest}")

    var headers: curly.HttpHeaders
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json"

    let resp = client.curly.post(
      client.baseUrl,
      headers,
      jsonRequest
    )

    if resp.code != 200:
      client.log(fmt"HTTP error: status {resp.code}")
      raise newException(CatchableError, fmt"HTTP request failed with status {resp.code}: {resp.body}")

    client.log(fmt"Received: {resp.body}")
    return parseResponse(resp.body)
  except CatchableError as e:
    client.log(fmt"Request failed: {e.msg}")
    raise

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

  # For HTTP, notifications don't expect responses - just send and continue
  let notification = createNotificationInitialized()
  try:
    let jsonRequest = notification.toJson()
    client.log(fmt"Sending notification: {jsonRequest}")

    var headers: curly.HttpHeaders
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json"

    let resp = client.curly.post(
      client.baseUrl,
      headers,
      jsonRequest
    )
    client.log(fmt"Notification response: {resp.body}")
    # Don't parse response for notifications - just log success
  except CatchableError as e:
    client.log(fmt"Notification failed: {e.msg}")
    # Don't fail on notification error - it's not critical for HTTP

  client.log("Successfully initialized")

proc listTools*(client: HttpMcpClient) =
  ## List available tools from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  client.log("Listing available tools...")

  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")

  let listRequest = client.client.createToolsListRequest()
  let listResult = client.sendRequest(listRequest)

  if listResult.isError:
    let errorMessage = listResult.error.error.message
    client.log(fmt"List tools failed: {errorMessage}")
    raise newException(CatchableError, fmt"List tools failed: {errorMessage}")

  discard client.client.handleToolsListResponse(listResult)
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

  let listRequest = client.client.createToolsListRequest()
  let listResult = client.sendRequest(listRequest)

  if listResult.isError:
    let errorMessage = listResult.error.error.message
    client.log(fmt"List tools failed: {errorMessage}")
    raise newException(CatchableError, fmt"Failed to list tools: {errorMessage}")

  # Parse the tools from the response
  var toolNames: seq[string] = @[]
  if listResult.response.result.hasKey("tools"):
    for tool in listResult.response.result["tools"]:
      if tool.hasKey("name"):
        toolNames.add(tool["name"].getStr())

  return toolNames

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
