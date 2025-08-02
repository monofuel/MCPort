import
  std/[unittest, json],
  mcport/[mcp_core, mcp_server_stdio]

suite "STDIO Server Tests":
  
  test "create example server":
    let server = createExampleServer()
    
    check server.serverInfo.name == "NimMCPServer"
    check server.serverInfo.version == "1.0.0"
    check "secret_fetcher" in server.tools
    check "secret_fetcher" in server.toolHandlers

  test "example server tool functionality":
    let server = createExampleServer()
    
    # Initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    let initResult = server.handleRequest(initRequest)
    check not initResult.isError
    
    # Test the secret_fetcher tool
    let callRequest = """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"secret_fetcher","arguments":{"recipient":"TestUser"}}}"""
    let callResult = server.handleRequest(callRequest)
    
    check not callResult.isError
    let content = callResult.response.result["content"][0]["text"].getStr()
    check "Shibboleet says: Leet greetings from the universe! Hello, TestUser!" in content

  test "example server with default recipient":
    let server = createExampleServer()
    
    # Initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    discard server.handleRequest(initRequest)
    
    # Test the secret_fetcher tool with no recipient
    let callRequest = """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"secret_fetcher","arguments":{}}}"""
    let callResult = server.handleRequest(callRequest)
    
    check not callResult.isError
    let content = callResult.response.result["content"][0]["text"].getStr()
    check "Shibboleet says: Leet greetings from the universe! Hello, friend!" in content

  test "stdio server handles multiple requests":
    let server = createExampleServer()
    
    # Initialize
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    let initResult = server.handleRequest(initRequest)
    check not initResult.isError
    
    # List tools
    let listRequest = """{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"""
    let listResult = server.handleRequest(listRequest)
    check not listResult.isError
    check listResult.response.result["tools"].len == 1
    
    # Call tool multiple times
    for i in 1..3:
      let callRequest = """{"jsonrpc":"2.0","id":""" & $(i + 2) & ""","method":"tools/call","params":{"name":"secret_fetcher","arguments":{"recipient":"User""" & $i & """"}}}"""
      let callResult = server.handleRequest(callRequest)
      check not callResult.isError
      let content = callResult.response.result["content"][0]["text"].getStr()
      check ("Hello, User" & $i & "!") in content 
