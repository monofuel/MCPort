import
  std/[unittest, json, tables, strutils],
  mcport/mcp_core

suite "MCP Core Tests":
  
  setup:
    let server = newMcpServer("TestServer", "1.0.0")
    
    # Register the shibboleet tool
    let shibboleetTool = McpTool(
      name: "secret_fetcher",
      description: "Delivers a secret leet greeting from the universe",
      inputSchema: %*{
        "type": "object",
        "properties": {
          "recipient": {
            "type": "string",
            "description": "Who to greet (optional)"
          }
        },
        "required": [],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
    )
    
    proc shibboleetHandler(arguments: JsonNode): JsonNode =
      let recipient = if arguments.hasKey("recipient"): arguments["recipient"].getStr() else: "friend"
      return %*("Shibboleet says: Leet greetings from the universe! Hello, " & recipient & "!")
    
    server.registerTool(shibboleetTool, shibboleetHandler)

  test "server creation":
    check server.serverInfo.name == "TestServer"
    check server.serverInfo.version == "1.0.0"
    check not server.initialized

  test "tool registration":
    check server.tools.hasKey("secret_fetcher")
    check server.toolHandlers.hasKey("secret_fetcher")

  test "initialize request":
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    let result = server.handleRequest(initRequest)
    
    check not result.isError
    check server.initialized
    check result.response.result["serverInfo"]["name"].getStr() == "TestServer"

  test "tools/list request":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)
    
    let listRequest = """{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"""
    let result = server.handleRequest(listRequest)
    
    check not result.isError
    let tools = result.response.result["tools"]
    check tools.len == 1
    check tools[0]["name"].getStr() == "secret_fetcher"

  test "tools/call with default recipient":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)
    
    let callRequest = """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"secret_fetcher","arguments":{}}}"""
    let result = server.handleRequest(callRequest)
    
    check not result.isError
    let content = result.response.result["content"][0]["text"].getStr()
    check content.contains("Shibboleet says: Leet greetings from the universe! Hello, friend!")

  test "tools/call with custom recipient":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)
    
    let callRequest = """{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"secret_fetcher","arguments":{"recipient":"Monofuel"}}}"""
    let result = server.handleRequest(callRequest)
    
    check not result.isError
    let content = result.response.result["content"][0]["text"].getStr()
    check content.contains("Shibboleet says: Leet greetings from the universe! Hello, Monofuel!")

  test "error on uninitialized server":
    let listRequest = """{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}"""
    let result = server.handleRequest(listRequest)
    
    check result.isError
    check result.error.error.code == -32001
    check result.error.error.message.contains("not initialized")

  test "error on unknown tool":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)
    
    let callRequest = """{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"unknown_tool","arguments":{}}}"""
    let result = server.handleRequest(callRequest)
    
    check result.isError
    check result.error.error.code == -32602
    check result.error.error.message.contains("Unknown tool name")

  test "error on invalid JSON":
    let invalidRequest = """{"invalid":"json","missing":"required fields"}"""
    let result = server.handleRequest(invalidRequest)
    
    check result.isError
    check result.error.error.code == -32600 
