import
  std/[json, strformat, httpclient],
  jsony,
  ./[mcp_core, mcp_client_core]

type
  HttpMcpClient* = ref object
    client*: McpClient
    httpClient*: HttpClient
    baseUrl*: string
    logEnabled*: bool

proc log(client: HttpMcpClient, msg: string) =
  ## Log a message if logging is enabled.
  if client.logEnabled:
    echo fmt"[HTTP Client] {msg}"

proc newHttpMcpClient*(name: string, version: string, baseUrl: string, logEnabled: bool = true): HttpMcpClient =
  ## Create a new HTTP MCP client.
  HttpMcpClient(
    client: newMcpClient(name, version),
    baseUrl: baseUrl,
    logEnabled: logEnabled
  )

proc connect*(client: HttpMcpClient): bool =
  ## Initialize the HTTP client connection.
  client.httpClient = newHttpClient()
  client.httpClient.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  client.log(fmt"Connected to: {client.baseUrl}")
  return true

proc sendRequest(client: HttpMcpClient, request: ClientRequest): ClientResult =
  ## Send a JSON-RPC request via HTTP.
  if client.httpClient == nil:
    return ClientResult(
      isError: true,
      error: createError(0, -32603, "HTTP client not initialized")
    )
  
  try:
    let jsonRequest = request.toJson()
    client.log(fmt"Sending: {jsonRequest}")
    
    let response = client.httpClient.postContent(client.baseUrl, body = jsonRequest)
    client.log(fmt"Received: {response}")
    
    return parseResponse(response)
  except HttpRequestError as e:
    client.log(fmt"HTTP request failed: {e.msg}")
    return ClientResult(
      isError: true,
      error: createError(0, -32603, fmt"HTTP request failed: {e.msg}")
    )
  except Exception as e:
    client.log(fmt"Request failed: {e.msg}")
    return ClientResult(
      isError: true,
      error: createError(0, -32603, fmt"Request failed: {e.msg}")
    )

proc initialize*(client: HttpMcpClient): bool =
  ## Initialize the connection with the server.
  client.log("Initializing connection...")
  
  # Send initialize request
  let initRequest = client.client.createInitializeRequest()
  let initResult = client.sendRequest(initRequest)
  
  if initResult.isError:
    client.log(fmt"Initialize failed: {initResult.error.error.message}")
    return false
  
  if not client.client.handleInitializeResponse(initResult):
    client.log("Failed to process initialize response")
    return false
  
  # For HTTP, we typically don't send the initialized notification
  # but let's send it for protocol compliance
  let notification = createNotificationInitialized()
  let notificationResult = client.sendRequest(notification)
  
  if notificationResult.isError:
    client.log(fmt"Initialized notification failed: {notificationResult.error.error.message}")
    # Don't fail on notification error - it's not critical for HTTP
  
  client.log("Successfully initialized")
  return true

proc listTools*(client: HttpMcpClient): bool =
  ## List available tools from the server.
  client.log("Listing available tools...")
  
  if not client.client.initialized:
    client.log("Client not initialized")
    return false
  
  let listRequest = client.client.createToolsListRequest()
  let listResult = client.sendRequest(listRequest)
  
  if listResult.isError:
    client.log(fmt"List tools failed: {listResult.error.error.message}")
    return false
  
  # For now, just log success - we'll implement tool processing later
  client.log("Tools list received successfully")
  return true

proc callTool*(client: HttpMcpClient, toolName: string, arguments: JsonNode = %*{}): ToolCallResult =
  ## Call a tool on the server.
  client.log(fmt"Calling tool: {toolName}")
  
  if not client.client.initialized:
    return ToolCallResult(
      isError: true,
      errorMessage: "Client not initialized"
    )
  
  # For now, just try to call the tool without checking availability
  let callRequest = client.client.createToolCallRequest(toolName, arguments)
  let callResult = client.sendRequest(callRequest)
  
  # Simple result handling
  if callResult.isError:
    return ToolCallResult(
      isError: true,
      errorMessage: callResult.error.error.message
    )
  else:
    return ToolCallResult(
      isError: false,
      content: @[ContentItem(`type`: "text", text: "Tool called successfully")]
    )

proc getAvailableTools*(client: HttpMcpClient): seq[string] =
  ## Get list of available tool names.
  @[]  # Return empty list for now

proc isConnected*(client: HttpMcpClient): bool =
  ## Check if the client is connected.
  client.httpClient != nil

proc close*(client: HttpMcpClient) =
  ## Close the HTTP client connection.
  if client.httpClient != nil:
    client.log("Closing HTTP connection...")
    client.httpClient.close()
    
    client.httpClient = nil
    client.log("Connection closed")

proc connectAndInitialize*(client: HttpMcpClient): bool =
  ## Connect to a server and initialize the connection.
  if not client.connect():
    return false
  
  if not client.initialize():
    client.close()
    return false
  
  return client.listTools()

# Example usage function
proc createExampleHttpClient*(baseUrl: string = "http://localhost:8080"): HttpMcpClient =
  ## Create an example HTTP client for testing.
  newHttpMcpClient("TestHttpClient", "1.0.0", baseUrl) 
