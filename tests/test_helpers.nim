import
  std/[json, options, strformat, osproc],
  jsony,
  mcport/[mcp_core, mcp_server_http]

const
  TestProtocolVersion = "2025-06-18"

proc makeJsonRequest*(id: int, `method`: string, params: JsonNode = newJObject()): string =
  ## Create a properly formatted JSON-RPC request using std/json.
  let request = %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": `method`,
    "params": params
  }
  return request.toJson()

proc makeInitRequest*(id: int = 1, capabilities: JsonNode = newJObject()): string =
  ## Create an initialize request.
  let params = %*{
    "protocolVersion": TestProtocolVersion,
    "capabilities": capabilities,
    "clientInfo": {
      "name": "test",
      "version": "1.0"
    }
  }
  return makeJsonRequest(id, "initialize", params)

proc makeToolsListRequest*(id: int = 2): string =
  ## Create a tools/list request.
  return makeJsonRequest(id, "tools/list")

proc makeToolCallRequest*(id: int = 3, name: string, arguments: JsonNode = newJObject()): string =
  ## Create a tools/call request.
  let params = %*{
    "name": name,
    "arguments": arguments
  }
  return makeJsonRequest(id, "tools/call", params)

proc makeResourcesListRequest*(id: int = 4): string =
  ## Create a resources/list request.
  return makeJsonRequest(id, "resources/list")

proc makeResourceReadRequest*(id: int = 5, uri: string): string =
  ## Create a resources/read request.
  let params = %*{"uri": uri}
  return makeJsonRequest(id, "resources/read", params)

proc makeResourceSubscribeRequest*(id: int = 6, uri: string): string =
  ## Create a resources/subscribe request.
  let params = %*{"uri": uri}
  return makeJsonRequest(id, "resources/subscribe", params)

proc makeResourceTemplatesListRequest*(id: int = 7): string =
  ## Create a resources/templates/list request.
  return makeJsonRequest(id, "resources/templates/list")

proc makePromptsListRequest*(id: int = 8): string =
  ## Create a prompts/list request.
  return makeJsonRequest(id, "prompts/list")

proc makePromptsGetRequest*(id: int = 9, name: string, arguments: JsonNode = newJObject()): string =
  ## Create a prompts/get request.
  let params = %*{
    "name": name,
    "arguments": arguments
  }
  return makeJsonRequest(id, "prompts/get", params)

proc registerTestTool*(server: McpServer, name: string = "test_tool", description: string = "A test tool"): void =
  ## Register a standard test tool that returns a simple message.
  let testTool = McpTool(
    name: name,
    description: description,
    inputSchema: %*{
      "type": "object",
      "properties": {
        "message": {
          "type": "string",
          "description": "Message to process"
        }
      },
      "required": [],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc testHandler(arguments: JsonNode): JsonNode =
    if arguments.hasKey("recipient"):
      let recipient = arguments["recipient"].getStr()
      return %*("Hello, " & recipient & "!")
    else:
      let message = if arguments.hasKey("message"): arguments["message"].getStr() else: "default"
      return %*("Test tool processed: " & message)

  server.registerTool(testTool, testHandler)

proc registerTestResource*(server: McpServer, uri: string = "test://example", name: string = "Test Resource"): void =
  ## Register a standard test resource.
  let testResource = McpResource(
    uri: uri,
    name: some(name),
    description: some("A test resource for testing"),
    mimeType: some("application/json")
  )

  proc testHandler(uri: string): ResourceContent =
    let data = %*{
      "uri": uri,
      "content": "test data",
      "timestamp": "2024-01-01T00:00:00Z"
    }
    return ResourceContent(isText: true, text: $data)

  server.registerResource(testResource, testHandler)

proc registerTestPrompt*(server: McpServer, name: string = "test_prompt", description: string = "A test prompt"): void =
  ## Register a standard test prompt.
  let testPrompt = McpPrompt(
    name: name,
    description: some(description),
    arguments: @[
      PromptArgument(name: "topic", description: some("The topic to discuss"), required: true)
    ]
  )

  proc testHandler(arguments: JsonNode): seq[PromptMessage] =
    let topic = arguments["topic"].getStr()
    return @[
      PromptMessage(
        role: "user",
        content: textPromptContent("Please discuss the topic: " & topic)
      )
    ]

  server.registerPrompt(testPrompt, testHandler)

proc createTestServer*(): McpServer =
  ## Create a standard test server with common fixtures.
  let server = newMcpServer("TestServer", "1.0.0")

  # Register standard test fixtures
  registerTestTool(server, "secret_fetcher", "Delivers a secret leet greeting from the universe")
  registerTestResource(server, "config://test-server", "Test Server Config")
  registerTestPrompt(server, "code_review", "Asks the LLM to analyze code quality and suggest improvements")

  return server

proc initializeTestServer*(server: McpServer): void =
  ## Initialize the test server (call after creating).
  let initRequest = makeInitRequest()
  let result = server.handleRequest(initRequest)
  if result.isError:
    raise newException(ValueError, "Failed to initialize test server: " & $result.error)

proc createAndInitializeTestServer*(): McpServer =
  ## Create and initialize a standard test server.
  let server = createTestServer()
  initializeTestServer(server)
  return server

proc registerProgressTestTool*(server: McpServer): void =
  ## Register a test tool that reports progress.
  let progressTool = McpTool(
    name: "progress_test",
    description: "A tool that reports progress during execution",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "steps": {
          "type": "integer",
          "description": "Number of progress steps",
          "default": 3
        }
      },
      "required": [],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc progressHandler(arguments: JsonNode, progressReporter: ProgressReporter): ToolResult =
    let steps = if arguments.hasKey("steps"): arguments["steps"].getInt() else: 3
    let progressToken = "test_progress_token"

    # Report progress through the steps
    for i in 1..steps:
      let progressPercent = (i.float / steps.float) * 100.0
      progressReporter(progressToken, some(progressPercent), some(fmt"Step {i} of {steps} completed"))

    return ToolResult(
      content: @[textContent(fmt"Progress test completed with {steps} steps")]
    )

  server.registerProgressTool(progressTool, progressHandler)

proc registerRichContentTestTool*(server: McpServer): void =
  ## Register a tool that returns rich content types.
  let richTool = McpTool(
    name: "rich_content_test",
    description: "A tool that returns different types of rich content",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "content_type": {
          "type": "string",
          "enum": ["text", "image", "audio", "resource_link", "embedded_resource"],
          "description": "Type of content to return"
        }
      },
      "required": ["content_type"],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc richHandler(arguments: JsonNode): ToolResult =
    let contentType = arguments["content_type"].getStr()

    case contentType:
      of "text":
        return ToolResult(
          content: @[textContent("This is plain text content")]
        )
      of "image":
        return ToolResult(
          content: @[imageContent("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "image/png")]
        )
      of "audio":
        return ToolResult(
          content: @[audioContent("data:audio/wav;base64,UklGRnoGAABXQVZFZm10IAAAAAEAAQARAAAAEAAAAAEACABkYXRhAgAAAAEA", "audio/wav")]
        )
      of "resource_link":
        return ToolResult(
          content: @[resourceLinkContent("test://linked-resource", name = some("Linked Resource"))]
        )
      of "embedded_resource":
        let resource = %*{
          "uri": "test://embedded",
          "mimeType": "text/plain",
          "text": "Embedded content"
        }
        return ToolResult(
          content: @[embeddedResourceContent(resource)]
        )
      else:
        return ToolResult(
          content: @[textContent("Unknown content type")]
        )

  server.registerRichTool(richTool, richHandler)

proc registerTestResourceTemplate*(server: McpServer): void =
  ## Register a test resource template.
  let tmpl = McpResourceTemplate(
    uriTemplate: "test://template/{category}/{id}",
    name: some("Test Template"),
    description: some("A parameterized resource template"),
    mimeType: some("application/json")
  )

  server.registerResourceTemplate(tmpl)

proc registerRichContentTestPrompt*(server: McpServer): void =
  ## Register a prompt that returns rich content.
  let richPrompt = McpPrompt(
    name: "rich_prompt_test",
    description: some("A prompt that returns rich content"),
    arguments: @[
      PromptArgument(name: "content_type", description: some("Type of content to return"), required: true)
    ]
  )

  proc richPromptHandler(arguments: JsonNode): seq[PromptMessage] =
    let contentType = arguments["content_type"].getStr()

    case contentType:
      of "text":
        return @[
          PromptMessage(
            role: "user",
            content: textPromptContent("This is text content")
          )
        ]
      of "image":
        return @[
          PromptMessage(
            role: "user",
            content: imagePromptContent("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "image/png", some(%*{"alt": "test image"}))
          )
        ]
      of "audio":
        return @[
          PromptMessage(
            role: "user",
            content: audioPromptContent("data:audio/wav;base64,UklGRnoGAABXQVZFZm10IAAAAAEAAQARAAAAEAAAAAEACABkYXRhAgAAAAEA", "audio/wav")
          )
        ]
      of "embedded_resource":
        let resource = %*{
          "uri": "test://example",
          "mimeType": "text/plain",
          "text": "Example content"
        }
        return @[
          PromptMessage(
            role: "user",
            content: embeddedResourcePromptContent(resource, some(%*{"source": "test"}))
          )
        ]
      else:
        return @[
          PromptMessage(
            role: "user",
            content: textPromptContent("Unknown content type")
          )
        ]

  server.registerPrompt(richPrompt, richPromptHandler)

# Client-specific test helpers

proc makeClientSuccessResponse*(id: int, responseResult: JsonNode): string =
  ## Create a successful client response.
  let response = %*{
    "jsonrpc": "2.0",
    "id": id,
    "result": responseResult
  }
  return response.toJson()

proc makeClientErrorResponse*(id: int, code: int, message: string, data: JsonNode = nil): string =
  ## Create an error client response.
  let error = %*{
    "code": code,
    "message": message
  }
  if data != nil:
    error["data"] = data

  let response = %*{
    "jsonrpc": "2.0",
    "id": id,
    "error": error
  }
  return response.toJson()

proc makeInitializeSuccessResponse*(id: int = 1): string =
  ## Create a successful initialize response.
  let result = %*{
    "protocolVersion": TestProtocolVersion,
    "capabilities": {
      "tools": {"listChanged": true},
      "prompts": {"listChanged": true},
      "resources": {"listChanged": true, "subscribe": true},
      "progress": true
    },
    "serverInfo": {
      "name": "TestServer",
      "version": "1.0.0"
    }
  }
  return makeClientSuccessResponse(id, result)

proc makeToolsListSuccessResponse*(id: int = 2): string =
  ## Create a successful tools/list response.
  let result = %*{
    "tools": [
      {
        "name": "test_tool",
        "description": "A test tool",
        "inputSchema": {
          "type": "object",
          "properties": {
            "arg": {"type": "string"}
          }
        }
      }
    ],
    "nextCursor": nil
  }
  return makeClientSuccessResponse(id, result)

proc makeToolCallSuccessResponse*(id: int = 3, content: JsonNode = %*[{"type": "text", "text": "Tool executed"}]): string =
  ## Create a successful tools/call response.
  let result = %*{
    "content": content,
    "isError": false
  }
  return makeClientSuccessResponse(id, result)

proc makeToolCallRichContentResponse*(id: int = 3, contentType: string): string =
  ## Create a rich content tool call response.
  var content: JsonNode

  case contentType:
    of "text":
      content = %*[{"type": "text", "text": "Rich text content"}]
    of "image":
      content = %*[{"type": "image", "data": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "mimeType": "image/png"}]
    of "audio":
      content = %*[{"type": "audio", "data": "data:audio/wav;base64,UklGRnoGAABXQVZFZm10IAAAAAEAAQARAAAAEAAAAAEACABkYXRhAgAAAAEA", "mimeType": "audio/wav"}]
    of "resource_link":
      content = %*[{"type": "resource_link", "uri": "test://linked", "name": "Linked Resource"}]
    of "embedded_resource":
      content = %*[{"type": "resource", "resource": {"uri": "test://embedded", "mimeType": "text/plain", "text": "Embedded content"}}]
    else:
      content = %*[{"type": "text", "text": "Unknown content type"}]

  return makeToolCallSuccessResponse(id, content)

proc makePromptsListSuccessResponse*(id: int = 4): string =
  ## Create a successful prompts/list response.
  let result = %*{
    "prompts": [
      {
        "name": "test_prompt",
        "description": "A test prompt",
        "arguments": [
          {"name": "topic", "description": "The topic", "required": true}
        ]
      }
    ],
    "nextCursor": nil
  }
  return makeClientSuccessResponse(id, result)

proc makePromptsGetSuccessResponse*(id: int = 5): string =
  ## Create a successful prompts/get response.
  let result = %*{
    "description": "A test prompt",
    "messages": [
      {
        "role": "user",
        "content": {"type": "text", "text": "Test prompt content"}
      }
    ]
  }
  return makeClientSuccessResponse(id, result)

proc makeResourcesListSuccessResponse*(id: int = 6): string =
  ## Create a successful resources/list response.
  let result = %*{
    "resources": [
      {
        "uri": "test://resource",
        "name": "Test Resource",
        "description": "A test resource",
        "mimeType": "application/json"
      }
    ],
    "nextCursor": nil
  }
  return makeClientSuccessResponse(id, result)

proc makeResourceReadSuccessResponse*(id: int = 7): string =
  ## Create a successful resources/read response.
  let result = %*{
    "contents": [
      {
        "uri": "test://resource",
        "mimeType": "application/json",
        "text": "{\"data\": \"test content\"}"
      }
    ]
  }
  return makeClientSuccessResponse(id, result)

proc makeResourceTemplatesListSuccessResponse*(id: int = 8): string =
  ## Create a successful resources/templates/list response.
  let result = %*{
    "resourceTemplates": [
      {
        "uriTemplate": "test://{category}/{id}",
        "name": "Test Template",
        "description": "A test template"
      }
    ]
  }
  return makeClientSuccessResponse(id, result)

proc makeResourceSubscribeSuccessResponse*(id: int = 9): string =
  ## Create a successful resources/subscribe response.
  return makeClientSuccessResponse(id, %*{})

# Error response helpers
proc makeMethodNotFoundErrorResponse*(id: int = 3): string =
  ## Create a method not found error response.
  return makeClientErrorResponse(id, -32601, "Method not found")

proc makeInvalidParamsErrorResponse*(id: int = 3): string =
  ## Create an invalid params error response.
  return makeClientErrorResponse(id, -32602, "Invalid params")

proc makeInternalErrorResponse*(id: int = 3): string =
  ## Create an internal error response.
  return makeClientErrorResponse(id, -32603, "Internal error")

proc makeServerNotInitializedErrorResponse*(id: int = 3): string =
  ## Create a server not initialized error response.
  return makeClientErrorResponse(id, -32001, "Server not initialized")

proc createTestStdioServerProcess*(): Process =
  ## Create a test stdio server process that responds with predefined responses.
  ## This is a helper for integration testing - returns a process that echoes test responses.
  when defined(windows):
    return startProcess("cmd", args = ["/c", "echo {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"TestServer\",\"version\":\"1.0.0\"}}}"])
  else:
    return startProcess("sh", args = ["-c", "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"TestServer\",\"version\":\"1.0.0\"}}}'"])

proc createTestHttpServer*(): HttpMcpServer =
  ## Create a test HTTP server for integration testing.
  let server = createAndInitializeTestServer()
  return newHttpMcpServer(server)

proc waitForHttpServer*(server: HttpMcpServer, port: int = 8081): void =
  ## Start HTTP server in background for testing.
  ## Note: This is for integration testing - in unit tests you may want to use a different approach.
  server.serve(port)

proc createMockHttpResponse*(statusCode: int, body: string, contentType: string = "application/json"): string =
  ## Create a mock HTTP response for testing (simplified).
  ## In real testing, you'd use a proper HTTP mocking library.
  body
