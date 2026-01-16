import
  std/[json, options, tables],
  jsony

const
  MCP_VERSION* = "2025-06-18"  ## MCP protocol version

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
    data*: Option[JsonNode]

  InitParams* = object
    protocolVersion*: string
    capabilities*: JsonNode
    clientInfo*: JsonNode
    
  ServerCapabilities* = object
    tools*: ToolCaps
    prompts*: PromptCaps
    resources*: ResourceCaps
    progress*: bool

  ToolCaps* = object
    listChanged*: bool

  PromptCaps* = object
    listChanged*: bool

  ResourceCaps* = object
    listChanged*: bool
    subscribe*: bool

  ServerInfo* = object
    name*: string
    version*: string

  ListParams* = object
    cursor*: Option[string]  # Optional cursor for pagination

  GetPromptParams* = object
    name*: string
    arguments*: Option[JsonNode]

  CallToolParams* = object
    name*: string
    arguments*: JsonNode

  McpTool* = object
    name*: string
    title*: Option[string]
    description*: string
    inputSchema*: JsonNode
    outputSchema*: Option[JsonNode]
    annotations*: Option[JsonNode]

  ToolHandler* = proc(arguments: JsonNode): JsonNode {.gcsafe.}

  RichToolHandler* = proc(arguments: JsonNode): ToolResult {.gcsafe.}

  ProgressToolHandler* = proc(arguments: JsonNode, progressReporter: ProgressReporter): ToolResult {.gcsafe.}

  McpServer* = ref object
    initialized*: bool
    serverInfo*: ServerInfo
    capabilities*: ServerCapabilities
    tools*: Table[string, McpTool]
    toolHandlers*: Table[string, ToolHandler]
    richToolHandlers*: Table[string, RichToolHandler]
    progressToolHandlers*: Table[string, ProgressToolHandler]
    prompts*: Table[string, McpPrompt]
    promptHandlers*: Table[string, PromptHandler]
    resources*: Table[string, McpResource]
    resourceHandlers*: Table[string, ResourceHandler]
    progressResourceHandlers*: Table[string, ProgressResourceHandler]
    resourceTemplates*: Table[string, McpResourceTemplate]
    resourceSubscriptions*: Table[string, bool]  # URI -> subscribed (true if subscribed)
    notificationCallback*: Option[NotificationCallback]
    progressReporter*: Option[ProgressReporter]

  PromptArgument* = object
    name*: string
    description*: Option[string]
    required*: bool

  McpPrompt* = object
    name*: string
    title*: Option[string]
    description*: Option[string]
    arguments*: seq[PromptArgument]

  PromptMessage* = object
    role*: string  # "user" or "assistant"
    content*: PromptContent

  TextContent* = object
    `type`*: string  # "text"
    text*: string

  ImageContent* = object
    `type`*: string  # "image"
    data*: string  # base64-encoded data
    mimeType*: string
    annotations*: Option[JsonNode]

  AudioContent* = object
    `type`*: string  # "audio"
    data*: string  # base64-encoded data
    mimeType*: string

  ResourceLinkContent* = object
    `type`*: string  # "resource_link"
    uri*: string
    name*: Option[string]
    description*: Option[string]
    mimeType*: Option[string]
    annotations*: Option[JsonNode]

  EmbeddedResourceContent* = object
    `type`*: string  # "resource"
    resource*: JsonNode
    annotations*: Option[JsonNode]

  ToolContentType* = enum
    tctText, tctImage, tctAudio, tctResourceLink, tctResource

  ToolContent* = object
    case kind*: ToolContentType
    of tctText:
      textContent*: TextContent
    of tctImage:
      imageContent*: ImageContent
    of tctAudio:
      audioContent*: AudioContent
    of tctResourceLink:
      resourceLinkContent*: ResourceLinkContent
    of tctResource:
      embeddedResourceContent*: EmbeddedResourceContent

  PromptContentType* = enum
    pctText, pctImage, pctAudio, pctResource

  PromptContent* = object
    case kind*: PromptContentType
    of pctText:
      textContent*: TextContent
    of pctImage:
      imageContent*: ImageContent
    of pctAudio:
      audioContent*: AudioContent
    of pctResource:
      embeddedResourceContent*: EmbeddedResourceContent

  ToolResult* = object
    content*: seq[ToolContent]
    structuredContent*: Option[JsonNode]
    isError*: bool

  PromptHandler* = proc(arguments: JsonNode): seq[PromptMessage] {.gcsafe.}

  McpResource* = object
    uri*: string
    name*: Option[string]
    title*: Option[string]
    description*: Option[string]
    mimeType*: Option[string]
    size*: Option[int]
    annotations*: Option[JsonNode]

  McpResourceTemplate* = object
    uriTemplate*: string
    name*: Option[string]
    title*: Option[string]
    description*: Option[string]
    mimeType*: Option[string]
    annotations*: Option[JsonNode]

  ResourceContent* = object
    case isText*: bool
    of true:
      text*: string
    of false:
      blob*: string  # base64-encoded binary data (TODO: implement)

  ResourceHandler* = proc(uri: string): ResourceContent {.gcsafe.}

  ProgressResourceHandler* = proc(uri: string, progressReporter: ProgressReporter): ResourceContent {.gcsafe.}

  NotificationCallback* = proc(notification: JsonNode) {.gcsafe.}

  ProgressReporter* = proc(
    progressToken: ProgressToken,
    progress: Option[float] = none(float),
    status: Option[string] = none(string),
    total: Option[int] = none(int),
    current: Option[int] = none(int)
  ) {.gcsafe.}

  ReadResourceParams* = object
    uri*: string

  SubscribeResourceParams* = object
    uri*: string

  ProgressToken* = string  # Can be string or int, using string for simplicity

  ProgressParams* = object
    progressToken*: ProgressToken
    progress*: Option[float]  # 0.0 to 1.0, percentage complete
    total*: Option[int]       # Total items/steps
    current*: Option[int]     # Current item/step
    status*: Option[string]   # Status message

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
      tools: ToolCaps(listChanged: true),
      prompts: PromptCaps(listChanged: true),
      resources: ResourceCaps(listChanged: true, subscribe: true),
      progress: false  # Opt-in capability, defaults to false
    ),
    tools: initTable[string, McpTool](),
    toolHandlers: initTable[string, ToolHandler](),
    richToolHandlers: initTable[string, RichToolHandler](),
    progressToolHandlers: initTable[string, ProgressToolHandler](),
    prompts: initTable[string, McpPrompt](),
    promptHandlers: initTable[string, PromptHandler](),
    resources: initTable[string, McpResource](),
    resourceHandlers: initTable[string, ResourceHandler](),
    progressResourceHandlers: initTable[string, ProgressResourceHandler](),
    resourceTemplates: initTable[string, McpResourceTemplate](),
    resourceSubscriptions: initTable[string, bool](),
    notificationCallback: none(NotificationCallback),
    progressReporter: none(ProgressReporter)
  )

proc registerTool*(server: McpServer, tool: McpTool, handler: ToolHandler) =
  ## Register a tool with the MCP server.
  server.tools[tool.name] = tool
  server.toolHandlers[tool.name] = handler
  # Notify that tools list has changed
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/tools/list_changed"
    })

proc registerRichTool*(server: McpServer, tool: McpTool, handler: RichToolHandler) =
  ## Register a rich tool with the MCP server.
  server.tools[tool.name] = tool
  server.richToolHandlers[tool.name] = handler
  # Notify that tools list has changed
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/tools/list_changed"
    })

proc registerProgressTool*(server: McpServer, tool: McpTool, handler: ProgressToolHandler) =
  ## Register a progress-enabled tool with the MCP server.
  server.tools[tool.name] = tool
  server.progressToolHandlers[tool.name] = handler
  # Notify that tools list has changed
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/tools/list_changed"
    })

proc setNotificationCallback*(server: McpServer, callback: NotificationCallback) =
  ## Set the notification callback for sending notifications to clients.
  server.notificationCallback = some(callback)

proc enableProgressCapability*(server: McpServer) =
  ## Enable progress tracking capability for the server.
  server.capabilities.progress = true

proc setProgressReporter*(server: McpServer, reporter: ProgressReporter) =
  ## Set the progress reporter callback for the server.
  server.progressReporter = some(reporter)

proc reportProgress*(
  server: McpServer,
  progressToken: ProgressToken,
  progress: Option[float] = none(float),
  status: Option[string] = none(string),
  total: Option[int] = none(int),
  current: Option[int] = none(int)
) =
  ## Report progress for a long-running operation.
  if server.progressReporter.isSome:
    server.progressReporter.get()(progressToken, progress, status, total, current)

proc notifyToolsListChanged*(server: McpServer) =
  ## Send a tools list changed notification.
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/tools/list_changed"
    })

proc notifyPromptsListChanged*(server: McpServer) =
  ## Send a prompts list changed notification.
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/prompts/list_changed"
    })

proc notifyResourceUpdated*(server: McpServer, uri: string) =
  ## Send a resource updated notification for subscribed resources.
  if server.resourceSubscriptions.contains(uri) and server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/resources/updated",
      "params": {
        "uri": uri
      }
    })

proc notifyProgress*(
  server: McpServer,
  progressToken: ProgressToken,
  progress: Option[float] = none(float),
  status: Option[string] = none(string),
  total: Option[int] = none(int),
  current: Option[int] = none(int)
) =
  ## Send a progress notification.
  if server.notificationCallback.isSome:
    # Validate progress value if provided
    if progress.isSome and (progress.get < 0.0 or progress.get > 1.0):
      # Invalid progress value, skip notification
      return

    var params = %*{
      "progressToken": progressToken
    }

    if progress.isSome:
      params["progress"] = %progress.get
    if status.isSome:
      params["status"] = %status.get
    if total.isSome:
      params["total"] = %total.get
    if current.isSome:
      params["current"] = %current.get

    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/progress",
      "params": params
    })

proc enableProgressNotifications*(server: McpServer) =
  ## Enable progress notifications by setting up a default progress reporter.
  ## This reporter will send progress notifications via the notification callback.
  if server.notificationCallback.isSome:
    let reporter = proc(
      progressToken: ProgressToken,
      progress: Option[float],
      status: Option[string],
      total: Option[int],
      current: Option[int]
    ) =
      notifyProgress(server, progressToken, progress, status, total, current)
    server.progressReporter = some(reporter)

proc notifyResourcesListChanged*(server: McpServer) =
  ## Send a resources list changed notification.
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/resources/list_changed"
    })

proc registerPrompt*(server: McpServer, prompt: McpPrompt, handler: PromptHandler) =
  ## Register a prompt with the MCP server.
  server.prompts[prompt.name] = prompt
  server.promptHandlers[prompt.name] = handler
  # Notify that prompts list has changed
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/prompts/list_changed"
    })

proc registerResource*(server: McpServer, resource: McpResource, handler: ResourceHandler) =
  ## Register a resource with the MCP server.
  server.resources[resource.uri] = resource
  server.resourceHandlers[resource.uri] = handler

proc registerProgressResource*(server: McpServer, resource: McpResource, handler: ProgressResourceHandler) =
  ## Register a progress-enabled resource with the MCP server.
  server.resources[resource.uri] = resource
  server.progressResourceHandlers[resource.uri] = handler
  # Notify that resources list has changed
  if server.notificationCallback.isSome:
    server.notificationCallback.get()(%*{
      "jsonrpc": "2.0",
      "method": "notifications/resources/list_changed"
    })

proc registerResourceTemplate*(server: McpServer, resourceTemplate: McpResourceTemplate) =
  ## Register a resource template with the MCP server.
  server.resourceTemplates[resourceTemplate.uriTemplate] = resourceTemplate

proc createError*(id: int, code: int, message: string, data: Option[JsonNode] = none(JsonNode)): RpcError =
  ## Create an RPC error response.
  RpcError(
    jsonrpc: "2.0",
    id: id,
    error: ErrorDetail(code: code, message: message, data: data)
  )

proc createResponse*(id: int, data: JsonNode): RpcResponse =
  ## Create an RPC success response.
  RpcResponse(
    jsonrpc: "2.0",
    id: id,
    result: data
  )

proc textContent*(text: string): ToolContent =
  ## Create text content for tool results.
  ToolContent(kind: tctText, textContent: TextContent(`type`: "text", text: text))

proc imageContent*(data: string, mimeType: string, annotations: Option[JsonNode] = none(JsonNode)): ToolContent =
  ## Create image content for tool results.
  ToolContent(kind: tctImage, imageContent: ImageContent(`type`: "image", data: data, mimeType: mimeType, annotations: annotations))

proc audioContent*(data: string, mimeType: string): ToolContent =
  ## Create audio content for tool results.
  ToolContent(kind: tctAudio, audioContent: AudioContent(`type`: "audio", data: data, mimeType: mimeType))

proc resourceLinkContent*(uri: string, name: Option[string] = none(string), description: Option[string] = none(string), mimeType: Option[string] = none(string), annotations: Option[JsonNode] = none(JsonNode)): ToolContent =
  ## Create resource link content for tool results.
  ToolContent(kind: tctResourceLink, resourceLinkContent: ResourceLinkContent(`type`: "resource_link", uri: uri, name: name, description: description, mimeType: mimeType, annotations: annotations))

proc embeddedResourceContent*(resource: JsonNode, annotations: Option[JsonNode] = none(JsonNode)): ToolContent =
  ## Create embedded resource content for tool results.
  ToolContent(kind: tctResource, embeddedResourceContent: EmbeddedResourceContent(`type`: "resource", resource: resource, annotations: annotations))

proc toolContentToJson*(content: ToolContent): JsonNode =
  ## Convert ToolContent to JsonNode for serialization.
  case content.kind:
  of tctText:
    return %*{
      "type": "text",
      "text": content.textContent.text
    }
  of tctImage:
    var obj = %*{
      "type": "image",
      "data": content.imageContent.data,
      "mimeType": content.imageContent.mimeType
    }
    if content.imageContent.annotations.isSome:
      obj["annotations"] = content.imageContent.annotations.get
    return obj
  of tctAudio:
    return %*{
      "type": "audio",
      "data": content.audioContent.data,
      "mimeType": content.audioContent.mimeType
    }
  of tctResourceLink:
    var obj = %*{
      "type": "resource_link",
      "uri": content.resourceLinkContent.uri
    }
    if content.resourceLinkContent.name.isSome:
      obj["name"] = %content.resourceLinkContent.name.get
    if content.resourceLinkContent.description.isSome:
      obj["description"] = %content.resourceLinkContent.description.get
    if content.resourceLinkContent.mimeType.isSome:
      obj["mimeType"] = %content.resourceLinkContent.mimeType.get
    if content.resourceLinkContent.annotations.isSome:
      obj["annotations"] = content.resourceLinkContent.annotations.get
    return obj
  of tctResource:
    var obj = %*{
      "type": "resource",
      "resource": content.embeddedResourceContent.resource
    }
    if content.embeddedResourceContent.annotations.isSome:
      obj["annotations"] = content.embeddedResourceContent.annotations.get
    return obj

proc textPromptContent*(text: string): PromptContent =
  ## Create text content for prompt messages.
  PromptContent(kind: pctText, textContent: TextContent(`type`: "text", text: text))

proc imagePromptContent*(data: string, mimeType: string, annotations: Option[JsonNode] = none(JsonNode)): PromptContent =
  ## Create image content for prompt messages.
  PromptContent(kind: pctImage, imageContent: ImageContent(`type`: "image", data: data, mimeType: mimeType, annotations: annotations))

proc audioPromptContent*(data: string, mimeType: string): PromptContent =
  ## Create audio content for prompt messages.
  PromptContent(kind: pctAudio, audioContent: AudioContent(`type`: "audio", data: data, mimeType: mimeType))

proc embeddedResourcePromptContent*(resource: JsonNode, annotations: Option[JsonNode] = none(JsonNode)): PromptContent =
  ## Create embedded resource content for prompt messages.
  PromptContent(kind: pctResource, embeddedResourceContent: EmbeddedResourceContent(`type`: "resource", resource: resource, annotations: annotations))

proc promptContentToJson*(content: PromptContent): JsonNode =
  ## Convert PromptContent to JsonNode for serialization.
  case content.kind:
  of pctText:
    return %*{
      "type": "text",
      "text": content.textContent.text
    }
  of pctImage:
    var obj = %*{
      "type": "image",
      "data": content.imageContent.data,
      "mimeType": content.imageContent.mimeType
    }
    if content.imageContent.annotations.isSome:
      obj["annotations"] = content.imageContent.annotations.get
    return obj
  of pctAudio:
    return %*{
      "type": "audio",
      "data": content.audioContent.data,
      "mimeType": content.audioContent.mimeType
    }
  of pctResource:
    var obj = %*{
      "type": "resource",
      "resource": content.embeddedResourceContent.resource
    }
    if content.embeddedResourceContent.annotations.isSome:
      obj["annotations"] = content.embeddedResourceContent.annotations.get
    return obj

proc handleRequest*(server: McpServer, line: string): McpResult =
  ## Handle an incoming MCP request and return the result.
  try:
    # First, try to determine if this is a notification or request
    let parsed = line.parseJson()
    
    # Check if it has an 'id' field - if not, it's a notification
    if not parsed.hasKey("id"):
      # This is a notification - validate minimal JSON-RPC shape
      if not parsed.hasKey("jsonrpc") or parsed["jsonrpc"].kind != JString or parsed["jsonrpc"].getStr() != "2.0" or
         not parsed.hasKey("method") or parsed["method"].kind != JString:
        # Invalid Request (syntactically JSON, but not a valid JSON-RPC object)
        return McpResult(
          isError: true,
          error: createError(0, -32600, "Invalid Request")
        )

      # Now it's safe to parse as a proper RpcNotification
      let notification = line.fromJson(RpcNotification)

      case notification.`method`
      of "notifications/initialized":
        if not server.initialized:
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
      # NB. some clients seem to send initialize requests multiple times.
      # if server.initialized:
      #   return McpResult(
      #     isError: true,
      #     error: createError(request.id, -32000, "Already initialized")
      #   )
      
      discard request.params.toJson().fromJson(InitParams)  # Validate params
      let response = createResponse(request.id, %*{
        "protocolVersion": MCP_VERSION,
        "capabilities": {
          "tools": {
            "listChanged": true
          },
          "prompts": {
            "listChanged": true
          },
          "resources": {
            "listChanged": true,
            "subscribe": true
          },
          "progress": server.capabilities.progress
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
        var toolObj = %*{
          "name": tool.name,
          "description": tool.description,
          "inputSchema": tool.inputSchema
        }
        if tool.title.isSome:
          toolObj["title"] = %tool.title.get
        if tool.outputSchema.isSome:
          toolObj["outputSchema"] = tool.outputSchema.get
        if tool.annotations.isSome:
          toolObj["annotations"] = tool.annotations.get
        toolsArray.add(toolObj)
      
      # Since MCPort doesn't implement pagination, omit nextCursor when there's no cursor
      let response = createResponse(request.id, %*{"tools": toolsArray})
      return McpResult(isError: false, response: response)
    
    of "tools/call":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )
        
      let params = request.params.toJson().fromJson(CallToolParams)
      let progressToken = $request.id  # Use request ID as progress token
      if params.name in server.progressToolHandlers and server.progressReporter.isSome:
        # Use progress-enabled tool handler
        try:
          let toolResult = server.progressToolHandlers[params.name](params.arguments, server.progressReporter.get())
          var contentArray = newJArray()
          for content in toolResult.content:
            contentArray.add(toolContentToJson(content))

          var responseObj = %*{
            "content": contentArray,
            "isError": toolResult.isError
          }
          if toolResult.structuredContent.isSome:
            responseObj["structuredContent"] = toolResult.structuredContent.get

          let response = createResponse(request.id, responseObj)
          return McpResult(isError: false, response: response)
        except Exception as e:
          return McpResult(
            isError: true,
            error: createError(request.id, -32603, "Tool execution failed: " & e.msg)
          )
      elif params.name in server.toolHandlers:
        # Use regular tool handler
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
      elif params.name in server.richToolHandlers:
        # Use rich tool handler
        try:
          let toolResult = server.richToolHandlers[params.name](params.arguments)
          var contentArray = newJArray()
          for content in toolResult.content:
            contentArray.add(toolContentToJson(content))

          var responseObj = %*{
            "content": contentArray,
            "isError": toolResult.isError
          }
          if toolResult.structuredContent.isSome:
            responseObj["structuredContent"] = toolResult.structuredContent.get

          let response = createResponse(request.id, responseObj)
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
    
    of "prompts/list":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )

      discard request.params.toJson().fromJson(ListParams)  # Validate params
      # TODO: Add pagination support with cursor
      var promptsArray = newJArray()

      for prompt in server.prompts.values:
        var argsArray = newJArray()
        for arg in prompt.arguments:
          argsArray.add(%*{
            "name": arg.name,
            "description": arg.description.get(""),
            "required": arg.required
          })

        var promptObj = %*{
          "name": prompt.name,
          "description": prompt.description.get(""),
          "arguments": argsArray
        }
        if prompt.title.isSome:
          promptObj["title"] = %prompt.title.get
        promptsArray.add(promptObj)

      # Since MCPort doesn't implement pagination, omit nextCursor when there's no cursor
      let response = createResponse(request.id, %*{"prompts": promptsArray})
      return McpResult(isError: false, response: response)

    of "prompts/get":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )

      let params = request.params.toJson().fromJson(GetPromptParams)
      if params.name in server.promptHandlers:
        # Validate required arguments
        let prompt = server.prompts[params.name]
        for arg in prompt.arguments:
          if arg.required and (params.arguments.isNone or not params.arguments.get().hasKey(arg.name)):
            return McpResult(
              isError: true,
              error: createError(request.id, -32602, "Missing required argument: " & arg.name)
            )

        try:
          let messages = server.promptHandlers[params.name](params.arguments.get(%*{}))
          var messagesArray = newJArray()
          for msg in messages:
            messagesArray.add(%*{
              "role": msg.role,
              "content": promptContentToJson(msg.content)
            })

          let response = createResponse(request.id, %*{
            "description": prompt.description.get(""),
            "messages": messagesArray
          })
          return McpResult(isError: false, response: response)
        except Exception as e:
          return McpResult(
            isError: true,
            error: createError(request.id, -32603, "Prompt execution failed: " & e.msg)
          )
      else:
        return McpResult(
          isError: true,
          error: createError(request.id, -32602, "Unknown prompt name")
        )

    of "resources/list":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )

      discard request.params.toJson().fromJson(ListParams)  # Validate params
      # TODO: Add pagination support with cursor
      var resourcesArray = newJArray()

      for resource in server.resources.values:
        var resourceObj = %*{
          "uri": resource.uri,
          "name": resource.name.get(""),
          "description": resource.description.get(""),
          "mimeType": resource.mimeType.get("")
        }
        if resource.title.isSome:
          resourceObj["title"] = %resource.title.get
        if resource.size.isSome:
          resourceObj["size"] = %resource.size.get
        if resource.annotations.isSome:
          resourceObj["annotations"] = resource.annotations.get
        resourcesArray.add(resourceObj)

      # Since MCPort doesn't implement pagination, omit nextCursor when there's no cursor
      let response = createResponse(request.id, %*{"resources": resourcesArray})
      return McpResult(isError: false, response: response)

    of "resources/read":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )

      let params = request.params.toJson().fromJson(ReadResourceParams)
      let progressToken = $request.id  # Use request ID as progress token
      if params.uri in server.progressResourceHandlers and server.progressReporter.isSome:
        # Use progress-enabled resource handler
        try:
          let content = server.progressResourceHandlers[params.uri](params.uri, server.progressReporter.get())
          let resource = server.resources[params.uri]
          var contentObj = %*{
            "uri": params.uri,
            "mimeType": resource.mimeType.get("")
          }
          if content.isText:
            contentObj["text"] = %content.text
          else:
            contentObj["blob"] = %content.blob  # base64-encoded binary data

          let response = createResponse(request.id, %*{
            "contents": [contentObj]
          })
          return McpResult(isError: false, response: response)
        except Exception as e:
          return McpResult(
            isError: true,
            error: createError(request.id, -32603, "Resource read failed: " & e.msg)
          )
      elif params.uri in server.resourceHandlers:
        # Use regular resource handler
        try:
          let content = server.resourceHandlers[params.uri](params.uri)
          let resource = server.resources[params.uri]
          var contentObj = %*{
            "uri": params.uri,
            "mimeType": resource.mimeType.get("")
          }
          if content.isText:
            contentObj["text"] = %content.text
          else:
            contentObj["blob"] = %content.blob  # base64-encoded binary data

          let response = createResponse(request.id, %*{
            "contents": [contentObj]
          })
          return McpResult(isError: false, response: response)
        except Exception as e:
          return McpResult(
            isError: true,
            error: createError(request.id, -32603, "Resource read failed: " & e.msg)
          )
      else:
        return McpResult(
          isError: true,
          error: createError(request.id, -32002, "Resource not found", some(%*{"uri": params.uri}))
        )

    of "resources/templates/list":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )

      var templatesArray = newJArray()

      for resourceTemplate in server.resourceTemplates.values:
        var templateObj = %*{
          "uriTemplate": resourceTemplate.uriTemplate
        }
        if resourceTemplate.name.isSome:
          templateObj["name"] = %resourceTemplate.name.get
        if resourceTemplate.title.isSome:
          templateObj["title"] = %resourceTemplate.title.get
        if resourceTemplate.description.isSome:
          templateObj["description"] = %resourceTemplate.description.get
        if resourceTemplate.mimeType.isSome:
          templateObj["mimeType"] = %resourceTemplate.mimeType.get
        if resourceTemplate.annotations.isSome:
          templateObj["annotations"] = resourceTemplate.annotations.get
        templatesArray.add(templateObj)

      let response = createResponse(request.id, %*{
        "resourceTemplates": templatesArray
      })
      return McpResult(isError: false, response: response)

    of "resources/subscribe":
      if not server.initialized:
        return McpResult(
          isError: true,
          error: createError(request.id, -32001, "Server not initialized")
        )

      let params = request.params.toJson().fromJson(SubscribeResourceParams)
      if params.uri in server.resources:
        # Mark the resource as subscribed
        server.resourceSubscriptions[params.uri] = true
        let response = createResponse(request.id, %*{})  # Empty response for subscription confirmation
        return McpResult(isError: false, response: response)
      else:
        return McpResult(
          isError: true,
          error: createError(request.id, -32002, "Resource not found", some(%*{"uri": params.uri}))
        )

    of "get_resource":
      # TODO do this! (legacy method, might be deprecated)
      return McpResult(
        isError: true,
        error: createError(request.id, -32601, "get_resource method not implemented")
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
