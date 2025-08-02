import
  std/[json, options, tables],
  jsony,
  ./mcp_core

type
  McpClient* = ref object
    initialized*: bool
    clientInfo*: ClientInfo
    serverInfo*: Option[ServerInfo]
    serverCapabilities*: Option[ServerCapabilities]
    availableTools*: Table[string, McpTool]
    nextRequestId: int

  ClientInfo* = object
    name*: string
    version*: string

  ClientRequest* = object
    jsonrpc*: string
    id*: int
    `method`*: string
    params*: JsonNode

  ClientResult* = object
    case isError*: bool
    of true:
      error*: RpcError
    of false:
      response*: RpcResponse

  ToolCallResult* = object
    case isError*: bool
    of true:
      errorMessage*: string
    of false:
      content*: seq[ContentItem]

  ContentItem* = object
    `type`*: string
    text*: string

proc newMcpClient*(name: string, version: string): McpClient =
  ## Create a new MCP client instance.
  result = McpClient(
    initialized: false,
    clientInfo: ClientInfo(name: name, version: version),
    serverInfo: none(ServerInfo),
    serverCapabilities: none(ServerCapabilities),
    availableTools: initTable[string, McpTool]()
  )
  result.nextRequestId = 1

proc getNextRequestId(client: McpClient): int =
  ## Get the next request ID for JSON-RPC requests.
  result = client.nextRequestId
  inc client.nextRequestId

proc createRequest*(client: McpClient, `method`: string, params: JsonNode): ClientRequest =
  ## Create a JSON-RPC request.
  ClientRequest(
    jsonrpc: "2.0",
    id: client.getNextRequestId(),
    `method`: `method`,
    params: params
  )

proc createInitializeRequest*(client: McpClient): ClientRequest =
  ## Create an initialize request.
  client.createRequest("initialize", %*{
    "protocolVersion": MCP_VERSION,
    "capabilities": {},
    "clientInfo": {
      "name": client.clientInfo.name,
      "version": client.clientInfo.version
    }
  })

proc createNotificationInitialized*(): ClientRequest =
  ## Create the initialized notification (no ID for notifications).
  ClientRequest(
    jsonrpc: "2.0",
    id: 0,  # Notifications use id 0
    `method`: "notifications/initialized",
    params: %*{}
  )

proc createToolsListRequest*(client: McpClient): ClientRequest =
  ## Create a tools/list request.
  client.createRequest("tools/list", %*{})

proc createToolCallRequest*(client: McpClient, toolName: string, arguments: JsonNode): ClientRequest =
  ## Create a tools/call request.
  client.createRequest("tools/call", %*{
    "name": toolName,
    "arguments": arguments
  })

proc parseResponse*(jsonResponse: string): ClientResult =
  ## Parse a JSON-RPC response string.
  let parsed = jsonResponse.parseJson()
  
  if parsed.hasKey("error"):
    # This is an error response
    let errorResponse = jsonResponse.fromJson(RpcError)
    return ClientResult(isError: true, error: errorResponse)
  else:
    # This is a success response
    let response = jsonResponse.fromJson(RpcResponse)
    return ClientResult(isError: false, response: response)

proc handleInitializeResponse*(client: McpClient, response: ClientResult): bool =
  ## Handle the response to an initialize request. Returns true if successful.
  if response.isError:
    return false
  
  let serverInfo = response.response.result["serverInfo"].toJson().fromJson(ServerInfo)
  let capabilities = response.response.result["capabilities"].toJson().fromJson(ServerCapabilities)
  
  client.serverInfo = some(serverInfo)
  client.serverCapabilities = some(capabilities)
  client.initialized = true
  return true

proc handleToolsListResponse*(client: McpClient, response: ClientResult): bool =
  ## Handle the response to a tools/list request. Returns true if successful.
  if response.isError:
    return false
  
  client.availableTools.clear()
  let tools = response.response.result["tools"]
  
  for toolJson in tools:
    let tool = toolJson.toJson().fromJson(McpTool)
    client.availableTools[tool.name] = tool
  
  return true

proc handleToolCallResponse*(response: ClientResult): ToolCallResult =
  ## Handle the response to a tools/call request.
  if response.isError:
    return ToolCallResult(
      isError: true,
      errorMessage: response.error.error.message
    )
  
  var content: seq[ContentItem] = @[]
  let contentArray = response.response.result["content"]
  
  for item in contentArray:
    content.add(ContentItem(
      `type`: item["type"].getStr(),
      text: item["text"].getStr()
    ))
  
  return ToolCallResult(isError: false, content: content)

proc isToolAvailable*(client: McpClient, toolName: string): bool =
  ## Check if a tool is available on the server.
  toolName in client.availableTools

proc getAvailableTools*(client: McpClient): seq[string] =
  ## Get list of available tool names.
  result = @[]
  for name in client.availableTools.keys:
    result.add(name) 
