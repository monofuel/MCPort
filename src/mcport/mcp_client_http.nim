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

proc connect*(client: HttpMcpClient) =
  ## Initialize the HTTP client connection.
  client.httpClient = newHttpClient()
  client.httpClient.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  client.log(fmt"Connected to: {client.baseUrl}")

proc sendRequest(client: HttpMcpClient, request: ClientRequest): ClientResult =
  ## Send a JSON-RPC request via HTTP.
  if client.httpClient == nil:
    raise newException(CatchableError, "HTTP client not initialized")
  
  try:
    let jsonRequest = request.toJson()
    client.log(fmt"Sending: {jsonRequest}")
    
    let response = client.httpClient.postContent(client.baseUrl, body = jsonRequest)
    client.log(fmt"Received: {response}")
    
    return parseResponse(response)
  except HttpRequestError as e:
    client.log(fmt"HTTP request failed: {e.msg}")
    raise newException(CatchableError, fmt"HTTP request failed: {e.msg}")
  except Exception as e:
    client.log(fmt"Request failed: {e.msg}")
    raise newException(CatchableError, fmt"Request failed: {e.msg}")

proc initialize*(client: HttpMcpClient) =
  ## Initialize the connection with the server.
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
    
    let response = client.httpClient.postContent(client.baseUrl, body = jsonRequest)
    client.log(fmt"Notification response: {response}")
    # Don't parse response for notifications - just log success
  except HttpRequestError as e:
    client.log(fmt"Notification request failed: {e.msg}")
    # Don't fail on notification error - it's not critical for HTTP
  except Exception as e:
    client.log(fmt"Notification failed: {e.msg}")
    # Don't fail on notification error - it's not critical for HTTP
  
  client.log("Successfully initialized")

proc listTools*(client: HttpMcpClient) =
  ## List available tools from the server.
  client.log("Listing available tools...")
  
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  
  let listRequest = client.client.createToolsListRequest()
  let listResult = client.sendRequest(listRequest)
  
  if listResult.isError:
    let errorMessage = listResult.error.error.message
    client.log(fmt"List tools failed: {errorMessage}")
    raise newException(CatchableError, fmt"List tools failed: {errorMessage}")
  
  # For now, just log success - we'll implement tool processing later
  client.log("Tools list received successfully")

proc callTool*(client: HttpMcpClient, toolName: string, arguments: JsonNode = %*{}): ToolCallResult =
  ## Call a tool on the server.
  client.log(fmt"Calling tool: {toolName}")
  
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  
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
