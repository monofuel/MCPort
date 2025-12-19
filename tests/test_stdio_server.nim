import
  std/[unittest, json, tables, strutils, options],
  mcport/[mcp_core, mcp_server_stdio],
  ./test_helpers

suite "STDIO Server Tests":
  
  test "create example server":
    let server = createExampleServer()
    
    check server.serverInfo.name == "NimMCPServer"
    check server.serverInfo.version == "1.0.0"
    check server.tools.hasKey("secret_fetcher")
    check server.toolHandlers.hasKey("secret_fetcher")

  test "example server tool functionality":
    let server = createExampleServer()
    initializeTestServer(server)

    # Test the secret_fetcher tool
    let callRequest = makeToolCallRequest(2, "secret_fetcher", %*{"recipient": "TestUser"})
    let callResult = server.handleRequest(callRequest)

    check not callResult.isError
    let content = callResult.response.result["content"][0]["text"].getStr()
    check content.contains("Shibboleet says: Leet greetings from the universe! Hello, TestUser!")

  test "example server with default recipient":
    let server = createExampleServer()
    initializeTestServer(server)

    # Test the secret_fetcher tool with no recipient
    let callRequest = makeToolCallRequest(2, "secret_fetcher")
    let callResult = server.handleRequest(callRequest)

    check not callResult.isError
    let content = callResult.response.result["content"][0]["text"].getStr()
    check content.contains("Shibboleet says: Leet greetings from the universe! Hello, friend!")

  test "stdio server handles multiple requests":
    let server = createExampleServer()
    initializeTestServer(server)

    # List tools
    let listRequest = makeToolsListRequest(2)
    let listResult = server.handleRequest(listRequest)
    check not listResult.isError
    check listResult.response.result["tools"].len == 1

    # Call tool multiple times
    for i in 1..3:
      let callRequest = makeToolCallRequest(i + 2, "secret_fetcher", %*{"recipient": "User" & $i})
      let callResult = server.handleRequest(callRequest)
      check not callResult.isError
      let content = callResult.response.result["content"][0]["text"].getStr()
      check content.contains("Hello, User" & $i & "!")

  test "stdio server notification callback setup":
    let server = createExampleServer()

    # Just verify the server can have a notification callback set
    # (We avoid testing actual notification capture due to GC-safety constraints)
    check server.notificationCallback.isNone

    server.setNotificationCallback(proc(notification: JsonNode) {.gcsafe.} =
      discard # Just a dummy callback for testing
    )

    check server.notificationCallback.isSome 
