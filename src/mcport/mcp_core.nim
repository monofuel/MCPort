import
  std/[json, options, tables],
  jsony

const
  MCP_VERSION* = "2024-11-05"  ## MCP protocol version

type
  RpcRequest* = object
    jsonrpc*: string
    id*: int
    `method`*: string
    params*: JsonNode
    
  RpcNotification* = object
    jsonrpc*: string
    `method`*: string
    
  RpcResponse* = object
    jsonrpc*: string
    id*: int
    result*: JsonNode
    
  RpcError* = object
    jsonrpc*: string
    id*: int
    error*: ErrorDetail
    
  ErrorDetail* = object
    code*: int
    message*: string

  InitParams* = object
    protocolVersion*: string
    capabilities*: JsonNode
    clientInfo*: JsonNode
    
  ServerCapabilities* = object
    tools*: ToolCaps
    
  ToolCaps* = object
    listChanged*: bool
    
  ServerInfo* = object
    name*: string
    version*: string

  ListParams* = object
    cursor*: Option[string]  # Optional cursor for pagination

  CallToolParams* = object
    name*: string
    arguments*: JsonNode

  McpTool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode

  ToolHandler* = proc(arguments: JsonNode): JsonNode {.gcsafe.}

  McpServer* = ref object
    initialized*: bool
    serverInfo*: ServerInfo
    capabilities*: ServerCapabilities
    tools*: Table[string, McpTool]
    toolHandlers*: Table[string, ToolHandler]

  McpResult* = object
    case isError*: bool
    of true:
      error*: RpcError
    of false:
      response*: RpcResponse

proc newMcpServer*(name: string, version: string): McpServer =
  ## Create a new MCP server instance.
  result = McpServer(
    initialized: false,
    serverInfo: ServerInfo(name: name, version: version),
    capabilities: ServerCapabilities(
      tools: ToolCaps(listChanged: true)
    ),
    tools: initTable[string, McpTool](),
    toolHandlers: initTable[string, ToolHandler]()
  )

proc registerTool*(server: McpServer, tool: McpTool, handler: ToolHandler) =
  ## Register a tool with the MCP server.
  server.tools[tool.name] = tool
  server.toolHandlers[tool.name] = handler

proc createError*(id: int, code: int, message: string): RpcError =
  ## Create an RPC error response.
  RpcError(
    jsonrpc: "2.0",
    id: id,
    error: ErrorDetail(code: code, message: message)
  )

proc createResponse*(id: int, data: JsonNode): RpcResponse =
  ## Create an RPC success response.
  RpcResponse(
    jsonrpc: "2.0",
    id: id,
    result: data
  )

proc handleRequest*(server: McpServer, line: string): McpResult =
  ## Handle an incoming MCP request and return the result.
  try:
    # First, try to determine if this is a notification or request
    let parsed = line.parseJson()
    
    # Check if it has an 'id' field - if not, it's a notification
    if not parsed.hasKey("id"):
      # This is a notification - handle it but don't return a response
      # Just validate it's a proper notification and return empty result
      let notification = line.fromJson(RpcNotification)
      if notification.jsonrpc != "2.0":
        # For malformed notifications, we still shouldn't respond
        return McpResult(isError: false, response: createResponse(0, %*{}))
      
      case notification.`method`
      of "notifications/initialized":
        if not server.initialized:
          # Log warning but don't return error for notifications
          discard
      else:
        # Unknown notification method - just ignore it
        discard
      
      # For notifications, return a dummy response that won't be sent
      return McpResult(isError: false, response: createResponse(0, %*{}))
    
    # This is a request (has 'id' field) - parse as RpcRequest
    let request = line.fromJson(RpcRequest)
    if request.jsonrpc != "2.0":
      return McpResult(
        isError: true,
        error: createError(request.id, -32600, "Invalid JSON-RPC version")
      )

    case request.`method`
    of "initialize":
      if server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32000, "Already initialized")
        )
      
      discard request.params.toJson().fromJson(InitParams)  # Validate params
      let response = createResponse(request.id, %*{
        "protocolVersion": MCP_VERSION,
        "capabilities": {
          "tools": {
            "listChanged": true
          }
        },
        "serverInfo": {
          "name": server.serverInfo.name,
          "version": server.serverInfo.version
        }
      })
      server.initialized = true
      return McpResult(isError: false, response: response)
    
    of "tools/list":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )
        
      discard request.params.toJson().fromJson(ListParams)  # Validate params
      var toolsArray = newJArray()
      
      for tool in server.tools.values:
        toolsArray.add(%*{
          "name": tool.name,
          "description": tool.description,
          "inputSchema": tool.inputSchema
        })
      
      let response = createResponse(request.id, %*{
        "tools": toolsArray
      })
      return McpResult(isError: false, response: response)
    
    of "tools/call":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )
        
      let params = request.params.toJson().fromJson(CallToolParams)
      if params.name in server.toolHandlers:
        try:
          let toolResult = server.toolHandlers[params.name](params.arguments)
          let response = createResponse(request.id, %*{
            "content": [
              {
                "type": "text",
                "text": toolResult.getStr()
              }
            ],
            "isError": false
          })
          return McpResult(isError: false, response: response)
        except Exception as e:
          return McpResult(
            isError: true,
            error: createError(request.id, -32603, "Tool execution failed: " & e.msg)
          )
      else:
        return McpResult(
          isError: true,
          error: createError(request.id, -32602, "Unknown tool name")
        )
    
    of "resources/list", "prompts/list", "resources/read", "get_resource":
      return McpResult(
        isError: true,
        error: createError(request.id, -32601, "Method not supported")
      )
    
    else:
      return McpResult(
        isError: true,
        error: createError(request.id, -32601, "Method not found")
      )
  
  except jsony.JsonError:
    return McpResult(
      isError: true,
      error: createError(0, -32700, "Invalid JSON")
    ) 
