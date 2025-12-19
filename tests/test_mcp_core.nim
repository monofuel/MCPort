import
  std/[unittest, json, tables, strutils, options],
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

    # Register a test prompt
    let codeReviewPrompt = McpPrompt(
      name: "code_review",
      description: some("Asks the LLM to analyze code quality and suggest improvements"),
      arguments: @[
        PromptArgument(name: "code", description: some("The code to review"), required: true)
      ]
    )

    proc codeReviewHandler(arguments: JsonNode): seq[PromptMessage] =
      let code = arguments["code"].getStr()
      return @[
        PromptMessage(
          role: "user",
          content: TextContent(`type`: "text", text: "Please review this code and provide feedback on quality, potential improvements, and best practices:\n\n" & code)
        )
      ]

    server.registerPrompt(codeReviewPrompt, codeReviewHandler)

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

  test "prompt registration":
    check server.prompts.hasKey("code_review")
    check server.promptHandlers.hasKey("code_review")

  test "prompts/list request":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)

    let listRequest = """{"jsonrpc":"2.0","id":7,"method":"prompts/list","params":{}}"""
    let result = server.handleRequest(listRequest)

    check not result.isError
    let prompts = result.response.result["prompts"]
    check prompts.len == 1
    check prompts[0]["name"].getStr() == "code_review"
    check prompts[0]["arguments"].len == 1
    check prompts[0]["arguments"][0]["name"].getStr() == "code"
    check prompts[0]["arguments"][0]["required"].getBool() == true

  test "prompts/get request with arguments":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)

    let getRequest = """{"jsonrpc":"2.0","id":8,"method":"prompts/get","params":{"name":"code_review","arguments":{"code":"def hello(): pass"}}}"""
    let result = server.handleRequest(getRequest)

    check not result.isError
    let messages = result.response.result["messages"]
    check messages.len == 1
    check messages[0]["role"].getStr() == "user"
    check messages[0]["content"]["type"].getStr() == "text"
    check messages[0]["content"]["text"].getStr().contains("def hello(): pass")

  test "prompts/get request without optional arguments":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)

    let getRequest = """{"jsonrpc":"2.0","id":9,"method":"prompts/get","params":{"name":"code_review"}}"""
    let result = server.handleRequest(getRequest)

    check result.isError
    check result.error.error.code == -32602
    check result.error.error.message.contains("Missing required argument")

  test "error on uninitialized server for prompts":
    let listRequest = """{"jsonrpc":"2.0","id":10,"method":"prompts/list","params":{}}"""
    let result = server.handleRequest(listRequest)

    check result.isError
    check result.error.error.code == -32001
    check result.error.error.message.contains("not initialized")

  test "error on unknown prompt name":
    # First initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)

    let getRequest = """{"jsonrpc":"2.0","id":11,"method":"prompts/get","params":{"name":"unknown_prompt","arguments":{}}}"""
    let result = server.handleRequest(getRequest)

    check result.isError
    check result.error.error.code == -32602
    check result.error.error.message.contains("Unknown prompt name") 
