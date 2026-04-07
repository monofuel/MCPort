import
  std/[unittest, tables, json, options, strutils],
  mcport/[mcp_client_core, mcp_core]

var testNotifBuffer {.threadvar.}: seq[JsonNode]

proc testNotifCallback(n: JsonNode) {.gcsafe.} =
  ## Append notification to the module-level buffer.
  testNotifBuffer.add(n)

suite "MCP Client Core Tests":
  
  test "client creation":
    let client = newMcpClient("TestClient", "1.0.0")
    
    check client.clientInfo.name == "TestClient"
    check client.clientInfo.version == "1.0.0"
    check not client.initialized
    check client.serverInfo.isNone
    check client.serverCapabilities.isNone
    check client.availableTools.len == 0

  test "request creation":
    let client = newMcpClient("TestClient", "1.0.0")
    
    # Test initialize request
    let initRequest = client.createInitializeRequest()
    check initRequest.jsonrpc == "2.0"
    check initRequest.`method` == "initialize"
    check initRequest.id > 0
    check initRequest.params["protocolVersion"].getStr() == "2025-06-18"
    check initRequest.params["clientInfo"]["name"].getStr() == "TestClient"
    
    # Test tools/list request
    let listRequest = client.createToolsListRequest()
    check listRequest.`method` == "tools/list"
    check listRequest.id > initRequest.id  # Should increment
    
    # Test tools/call request
    let callRequest = client.createToolCallRequest("test_tool", %*{"arg": "value"})
    check callRequest.`method` == "tools/call"
    check callRequest.params["name"].getStr() == "test_tool"
    check callRequest.params["arguments"]["arg"].getStr() == "value"
    
    # Test notification
    let notification = createNotificationInitialized()
    check notification.`method` == "notifications/initialized"
    check notification.id == 0  # Notifications use id 0

  test "response parsing success":
    let successResponse = """{"jsonrpc":"2.0","id":1,"result":{"test":"value"}}"""
    let result = parseResponse(successResponse)
    
    check not result.isError
    check result.response.jsonrpc == "2.0"
    check result.response.id == 1
    check result.response.result["test"].getStr() == "value"

  test "response parsing error":
    let errorResponse = """{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params"}}"""
    let result = parseResponse(errorResponse)
    
    check result.isError
    check result.error.jsonrpc == "2.0"
    check result.error.id == 2
    check result.error.error.code == -32602
    check result.error.error.message == "Invalid params"

  test "initialize response handling":
    let client = newMcpClient("TestClient", "1.0.0")
    
    # Test successful initialize response
    let successResponse = """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"TestServer","version":"1.0.0"}}}"""
    let result = parseResponse(successResponse)
    
    let success = handleInitializeResponse(client, result)
    check success
    check client.initialized

  test "tools list response handling":
    # Just test that we can parse a tools list response
    let toolsResponse = """{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"secret_fetcher","description":"Test tool","inputSchema":{"type":"object"}}]}}"""
    let result = parseResponse(toolsResponse)
    
    check not result.isError
    check result.response.result.hasKey("tools")

  test "tool call response parsing":
    # Test successful tool call response parsing
    let successResponse = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Hello, World!"}],"isError":false}}"""
    let result = parseResponse(successResponse)

    check not result.isError
    check result.response.result.hasKey("content")

    # Test error response parsing
    let errorResponse = """{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Tool not found"}}"""
    let errorResult = parseResponse(errorResponse)

    check errorResult.isError
    check errorResult.error.error.message.contains("Tool not found")

  test "rich content tool call response parsing - image":
    let imageResponse = """{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"image","data":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==","mimeType":"image/png"}],"isError":false}}"""
    let result = parseResponse(imageResponse)

    check not result.isError
    check result.response.result["content"][0]["type"].getStr() == "image"
    check result.response.result["content"][0]["data"].getStr().startsWith("data:image/png;base64,")
    check result.response.result["content"][0]["mimeType"].getStr() == "image/png"

  test "rich content tool call response parsing - audio":
    let audioResponse = """{"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"audio","data":"data:audio/wav;base64,UklGRnoGAABXQVZFZm10IAAAAAEAAQARAAAAEAAAAAEACABkYXRhAgAAAAEA","mimeType":"audio/wav"}],"isError":false}}"""
    let result = parseResponse(audioResponse)

    check not result.isError
    check result.response.result["content"][0]["type"].getStr() == "audio"
    check result.response.result["content"][0]["data"].getStr().startsWith("data:audio/wav;base64,")
    check result.response.result["content"][0]["mimeType"].getStr() == "audio/wav"

  test "rich content tool call response parsing - resource_link":
    let resourceLinkResponse = """{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"resource_link","uri":"test://linked-resource","name":"Linked Resource","description":"A linked resource"}],"isError":false}}"""
    let result = parseResponse(resourceLinkResponse)

    check not result.isError
    check result.response.result["content"][0]["type"].getStr() == "resource_link"
    check result.response.result["content"][0]["uri"].getStr() == "test://linked-resource"
    check result.response.result["content"][0]["name"].getStr() == "Linked Resource"
    check result.response.result["content"][0]["description"].getStr() == "A linked resource"

  test "rich content tool call response parsing - embedded_resource":
    let embeddedResourceResponse = """{"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"resource","resource":{"uri":"test://embedded","mimeType":"text/plain","text":"Embedded content"}}],"isError":false}}"""
    let result = parseResponse(embeddedResourceResponse)

    check not result.isError
    check result.response.result["content"][0]["type"].getStr() == "resource"
    let resource = result.response.result["content"][0]["resource"]
    check resource["uri"].getStr() == "test://embedded"
    check resource["mimeType"].getStr() == "text/plain"
    check resource["text"].getStr() == "Embedded content"

  test "tool call response parsing with structured content":
    let structuredResponse = """{"jsonrpc":"2.0","id":9,"result":{"content":[{"type":"text","text":"Result"}],"structuredContent":{"key":"value"},"isError":false}}"""
    let result = parseResponse(structuredResponse)

    check not result.isError
    check result.response.result.hasKey("structuredContent")
    check result.response.result["structuredContent"]["key"].getStr() == "value"

  test "tool call response parsing with error flag":
    let errorToolResponse = """{"jsonrpc":"2.0","id":10,"result":{"content":[{"type":"text","text":"Error occurred"}],"isError":true}}"""
    let result = parseResponse(errorToolResponse)

    check not result.isError  # This is not an RPC error, just a tool error
    check result.response.result["isError"].getBool() == true
    check result.response.result["content"][0]["text"].getStr() == "Error occurred"

  test "handleToolCallResponse success":
    let client = newMcpClient("TestClient", "1.0.0")
    let successResponse = """{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Success!"}],"isError":false}}"""
    let result = parseResponse(successResponse)
    let toolResult = handleToolCallResponse(result)

    check not toolResult.isError
    check toolResult.content.len == 1
    check toolResult.content[0].`type` == "text"
    check toolResult.content[0].text == "Success!"

  test "handleToolCallResponse error":
    let client = newMcpClient("TestClient", "1.0.0")
    let errorResponse = """{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Tool execution failed"}}"""
    let result = parseResponse(errorResponse)
    let toolResult = handleToolCallResponse(result)

    check toolResult.isError
    check toolResult.errorMessage == "Tool execution failed"

  test "handleToolsListResponse":
    let client = newMcpClient("TestClient", "1.0.0")
    let toolsResponse = """{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"tool1","description":"First tool","inputSchema":{"type":"object"}},{"name":"tool2","description":"Second tool","inputSchema":{"type":"object"},"title":"Tool 2"}]}}"""
    let result = parseResponse(toolsResponse)

    let success = handleToolsListResponse(client, result)
    check success
    check client.availableTools.len == 2
    check client.availableTools.hasKey("tool1")
    check client.availableTools.hasKey("tool2")
    check client.availableTools["tool1"].description == "First tool"
    check client.availableTools["tool2"].title.get() == "Tool 2"

  test "isToolAvailable":
    let client = newMcpClient("TestClient", "1.0.0")

    # Initially no tools available
    check not client.isToolAvailable("test_tool")

    # Add a tool manually for testing
    client.availableTools["test_tool"] = McpTool(
      name: "test_tool",
      description: "A test tool",
      inputSchema: %*{"type": "object"}
    )

    check client.isToolAvailable("test_tool")
    check not client.isToolAvailable("nonexistent_tool")

  test "getAvailableTools":
    let client = newMcpClient("TestClient", "1.0.0")

    # Initially empty
    check client.getAvailableTools().len == 0

    # Add tools manually for testing
    client.availableTools["tool1"] = McpTool(name: "tool1", description: "Tool 1", inputSchema: %*{"type": "object"})
    client.availableTools["tool2"] = McpTool(name: "tool2", description: "Tool 2", inputSchema: %*{"type": "object"})

    let toolNames = client.getAvailableTools()
    check toolNames.len == 2
    check "tool1" in toolNames
    check "tool2" in toolNames

  test "prompts/list request":
    let client = newMcpClient("TestClient", "1.0.0")
    let req = client.createPromptsListRequest()
    check req.jsonrpc == "2.0"
    check req.`method` == "prompts/list"
    check req.id > 0

  test "prompts/get request":
    let client = newMcpClient("TestClient", "1.0.0")
    let req = client.createPromptsGetRequest("my-prompt", %*{"key": "val"})
    check req.jsonrpc == "2.0"
    check req.`method` == "prompts/get"
    check req.params["name"].getStr() == "my-prompt"
    check req.params["arguments"]["key"].getStr() == "val"

  test "prompts/get request without arguments":
    let client = newMcpClient("TestClient", "1.0.0")
    let req = client.createPromptsGetRequest("bare-prompt")
    check req.`method` == "prompts/get"
    check req.params["name"].getStr() == "bare-prompt"

  test "resources/list request":
    let client = newMcpClient("TestClient", "1.0.0")
    let req = client.createResourcesListRequest()
    check req.jsonrpc == "2.0"
    check req.`method` == "resources/list"
    check req.id > 0

  test "resources/read request":
    let client = newMcpClient("TestClient", "1.0.0")
    let req = client.createResourcesReadRequest("file:///path/to/res")
    check req.jsonrpc == "2.0"
    check req.`method` == "resources/read"
    check req.params["uri"].getStr() == "file:///path/to/res"

  test "resources/subscribe request":
    let client = newMcpClient("TestClient", "1.0.0")
    let req = client.createResourcesSubscribeRequest("file:///path/to/res")
    check req.jsonrpc == "2.0"
    check req.`method` == "resources/subscribe"
    check req.params["uri"].getStr() == "file:///path/to/res"

  test "request ID increment":
    let client = newMcpClient("TestClient", "1.0.0")

    let req1 = client.createToolsListRequest()
    let req2 = client.createToolsListRequest()
    let req3 = client.createToolCallRequest("test", %*{})

    check req2.id == req1.id + 1
    check req3.id == req2.id + 1

  test "request ID increment across new builders":
    let client = newMcpClient("TestClient", "1.0.0")
    let r1 = client.createPromptsListRequest()
    let r2 = client.createPromptsGetRequest("p")
    let r3 = client.createResourcesListRequest()
    let r4 = client.createResourcesReadRequest("x://y")
    let r5 = client.createResourcesSubscribeRequest("x://y")
    check r2.id == r1.id + 1
    check r3.id == r2.id + 1
    check r4.id == r3.id + 1
    check r5.id == r4.id + 1

  test "malformed JSON response parsing":
    expect JsonParsingError:
      discard parseResponse("""{"invalid":"json" malformed}""")

  test "response with missing required fields":
    # Response missing 'id' field - this should work since 'id' is optional in notifications
    let incompleteResponse = """{"jsonrpc":"2.0","result":{}}"""
    let result = parseResponse(incompleteResponse)
    # This should succeed as it's a valid but incomplete response
    check not result.isError

  test "initialize response with missing server info":
    let client = newMcpClient("TestClient", "1.0.0")
    let malformedResponse = """{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}"""
    let result = parseResponse(malformedResponse)

    # Currently this throws KeyError due to missing required fields
    expect KeyError:
      discard handleInitializeResponse(client, result)
    check not client.initialized

  test "tools list response with empty tools array":
    let client = newMcpClient("TestClient", "1.0.0")
    let emptyToolsResponse = """{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"""
    let result = parseResponse(emptyToolsResponse)

    let success = handleToolsListResponse(client, result)
    check success
    check client.availableTools.len == 0

  test "setNotificationCallback registers callback":
    let client = newMcpClient("TestClient", "1.0.0")
    check client.notificationCallback.isNone

    testNotifBuffer = @[]
    client.setNotificationCallback(testNotifCallback)
    check client.notificationCallback.isSome

    client.notificationCallback.get()(%*{"method": "notifications/progress"})
    check testNotifBuffer.len == 1
    check testNotifBuffer[0]["method"].getStr() == "notifications/progress"

  test "tool call response with multiple content items":
    let multiContentResponse = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"First"},{"type":"text","text":"Second"}],"isError":false}}"""
    let result = parseResponse(multiContentResponse)
    let toolResult = handleToolCallResponse(result)

    check not toolResult.isError
    check toolResult.content.len == 2
    check toolResult.content[0].text == "First"
    check toolResult.content[1].text == "Second"

  test "handleInitializeResponse with error response":
    let client = newMcpClient("TestClient", "1.0.0")
    let errResponse = """{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Internal error"}}"""
    let result = parseResponse(errResponse)

    let success = handleInitializeResponse(client, result)
    check not success
    check not client.initialized
    check client.serverInfo.isNone

  test "handleToolsListResponse with error response":
    let client = newMcpClient("TestClient", "1.0.0")
    let errResponse = """{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error"}}"""
    let result = parseResponse(errResponse)

    let success = handleToolsListResponse(client, result)
    check not success
    check client.availableTools.len == 0

  test "handleToolsListResponse replaces previous tools":
    let client = newMcpClient("TestClient", "1.0.0")
    let firstResponse = """{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"tool_a","description":"A","inputSchema":{"type":"object"}}]}}"""
    discard handleToolsListResponse(client, parseResponse(firstResponse))
    check client.availableTools.len == 1
    check client.availableTools.hasKey("tool_a")

    let secondResponse = """{"jsonrpc":"2.0","id":4,"result":{"tools":[{"name":"tool_b","description":"B","inputSchema":{"type":"object"}},{"name":"tool_c","description":"C","inputSchema":{"type":"object"}}]}}"""
    let success = handleToolsListResponse(client, parseResponse(secondResponse))
    check success
    check client.availableTools.len == 2
    check not client.availableTools.hasKey("tool_a")
    check client.availableTools.hasKey("tool_b")
    check client.availableTools.hasKey("tool_c")

  test "handleToolCallResponse with empty content array":
    let emptyContentResponse = """{"jsonrpc":"2.0","id":5,"result":{"content":[],"isError":false}}"""
    let result = parseResponse(emptyContentResponse)
    let toolResult = handleToolCallResponse(result)

    check not toolResult.isError
    check toolResult.content.len == 0

  test "parseResponse with notification-style response (no id, no error)":
    let notificationResponse = """{"jsonrpc":"2.0","result":{}}"""
    let result = parseResponse(notificationResponse)

    check not result.isError
    check result.response.id == 0
