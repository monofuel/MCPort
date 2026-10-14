import
  std/[json, locks, options, tables],
  jsony,
  ./[mcp_core, mcp_extensions]

type
  McpClient* = ref object
    initialized*: bool
    clientInfo*: ClientInfo
    serverInfo*: Option[ServerInfo]
    serverCapabilities*: Option[ServerCapabilities]
    availableTools*: Table[string, McpTool]
    notificationCallback*: Option[NotificationCallback]
    protocolVersion*: string
    modernProtocol*: bool
    requestLock: Lock
    nextRequestId: int

  ClientInfo* = object
    name*: string
    version*: string

  ClientRequest* = object
    jsonrpc*: string
    id*: int
    `method`*: string
    params*: JsonNode

  ClientNotification* = object
    jsonrpc*: string
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

proc newMcpClient*(name: string, version: string, modernProtocol = false): McpClient =
  ## Create a new MCP client instance.
  result = McpClient(
    initialized: false,
    modernProtocol: modernProtocol,
    clientInfo: ClientInfo(name: name, version: version),
    serverInfo: none(ServerInfo),
    serverCapabilities: none(ServerCapabilities),
    availableTools: initTable[string, McpTool](),
    notificationCallback: none(NotificationCallback)
  )
  result.nextRequestId = 1
  initLock(result.requestLock)

proc setNotificationCallback*(client: McpClient, callback: NotificationCallback) =
  ## Register a callback invoked when the server sends an unsolicited notification.
  client.notificationCallback = some(callback)

proc getNextRequestId(client: McpClient): int =
  ## Get the next request ID for JSON-RPC requests.
  withLock client.requestLock:
    result = client.nextRequestId
    inc client.nextRequestId

proc createRequest*(client: McpClient, `method`: string, params: JsonNode): ClientRequest =
  ## Create a JSON-RPC request.
  if params == nil or params.kind != JObject:
    raise newException(ValueError, "MCP request parameters must be an object")
  result = ClientRequest(jsonrpc: "2.0", id: client.getNextRequestId(),
    `method`: `method`, params: params.copy())
  if client.modernProtocol:
    if not result.params.hasKey("_meta"):
      result.params["_meta"] = %*{}
    elif result.params["_meta"].kind != JObject:
      raise newException(ValueError, "Request metadata must be an object")
    result.params["_meta"][ProtocolVersionKey] = %ModernProtocolVersion
    result.params["_meta"][ClientInfoKey] = %client.clientInfo
    result.params["_meta"][ClientCapabilitiesKey] = %*{}

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

proc createNotificationInitialized*(): ClientNotification =
  ## Create the initialized notification (no ID for notifications).
  ClientNotification(
    jsonrpc: "2.0",
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

proc createPromptsListRequest*(client: McpClient): ClientRequest =
  ## Create a prompts/list request.
  client.createRequest("prompts/list", %*{})

proc createPromptsGetRequest*(client: McpClient, name: string, arguments: JsonNode = %*{}): ClientRequest =
  ## Create a prompts/get request.
  client.createRequest("prompts/get", %*{
    "name": name,
    "arguments": arguments
  })

proc createResourcesListRequest*(client: McpClient): ClientRequest =
  ## Create a resources/list request.
  client.createRequest("resources/list", %*{})

proc createResourcesReadRequest*(client: McpClient, uri: string): ClientRequest =
  ## Create a resources/read request.
  client.createRequest("resources/read", %*{
    "uri": uri
  })

proc createResourcesSubscribeRequest*(client: McpClient, uri: string): ClientRequest =
  ## Create a resources/subscribe request.
  client.createRequest("resources/subscribe", %*{
    "uri": uri
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
    var response = jsonResponse.fromJson(RpcResponse)
    if response.id == nil: response.id = %0
    return ClientResult(isError: false, response: response)

proc handleInitializeResponse*(client: McpClient, response: ClientResult): bool =
  ## Handle the response to an initialize request. Returns true if successful.
  if response.isError:
    return false
  
  let serverInfo = response.response.result["serverInfo"].toJson().fromJson(ServerInfo)
  let capabilities = response.response.result["capabilities"].toJson().fromJson(ServerCapabilities)
  
  client.serverInfo = some(serverInfo)
  client.serverCapabilities = some(capabilities)
  client.protocolVersion = response.response.result["protocolVersion"].getStr()
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

proc handleDiscoveryResponse*(client: McpClient, response: ClientResult) =
  if response.isError:
    raise newException(IOError, response.error.error.message)
  let body = response.response.result
  var supported = false
  for version in body["supportedVersions"]:
    if version.getStr() == ModernProtocolVersion:
      supported = true
  if not supported:
    raise newException(IOError, "Server does not support the requested protocol")
  client.protocolVersion = ModernProtocolVersion
  client.serverCapabilities = some(($body["capabilities"]).fromJson(ServerCapabilities))
  if body.hasKey("serverInfo"):
    client.serverInfo = some(($body["serverInfo"]).fromJson(ServerInfo))
  client.initialized = true
