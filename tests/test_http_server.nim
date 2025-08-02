import
  std/[unittest, json, tables, strutils],
  mcport/[mcp_core, mcp_server_http]

suite "HTTP Server Tests":
  
  test "create http server wrapper":
    let mcpServer = newMcpServer("TestHTTPServer", "1.0.0")
    let httpServer = newHttpMcpServer(mcpServer)
    
    check httpServer.server == mcpServer
    check httpServer.logEnabled == true
    check httpServer.httpServer != nil

  test "create http server with logging disabled":
    let mcpServer = newMcpServer("TestHTTPServer", "1.0.0")
    let httpServer = newHttpMcpServer(mcpServer, logEnabled = false)
    
    check not httpServer.logEnabled

  test "create example http server":
    let httpServer = createExampleHttpServer()
    
    check httpServer.server.serverInfo.name == "NimHTTPMCPServer"
    check httpServer.server.serverInfo.version == "1.0.0"
    check httpServer.server.tools.hasKey("secret_fetcher")
    check httpServer.server.toolHandlers.hasKey("secret_fetcher")

  test "example http server tool functionality":
    let httpServer = createExampleHttpServer()
    let server = httpServer.server
    
    # Initialize the server
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    let initResult = server.handleRequest(initRequest)
    check not initResult.isError
    
    # Test the secret_fetcher tool
    let callRequest = """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"secret_fetcher","arguments":{"recipient":"HTTPUser"}}}"""
    let callResult = server.handleRequest(callRequest)
    
    check not callResult.isError
    let content = callResult.response.result["content"][0]["text"].getStr()
    check content.contains("Shibboleet says: Leet greetings from the universe! Hello, HTTPUser!")

  test "http server json-rpc protocol compliance":
    let httpServer = createExampleHttpServer()
    let server = httpServer.server
    
    # Test JSON-RPC version validation
    let invalidVersionRequest = """{"jsonrpc":"1.0","id":1,"method":"initialize","params":{}}"""
    let invalidResult = server.handleRequest(invalidVersionRequest)
    check invalidResult.isError
    check invalidResult.error.error.code == -32600
    
    # Test proper JSON-RPC response format
    let initRequest = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"""
    let initResult = server.handleRequest(initRequest)
    check not initResult.isError
    check initResult.response.jsonrpc == "2.0"
    check initResult.response.id == 1

# Note: Integration tests with real HTTP servers are complex to implement in unit tests
# For now, we focus on unit testing the core functionality
# Integration testing can be done manually or in separate test suites 
