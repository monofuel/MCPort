import
  std/[unittest, tables, json, options, strutils],
  mcport/mcp_client_core

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
    check initRequest.params["protocolVersion"].getStr() == "2024-11-05"
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
