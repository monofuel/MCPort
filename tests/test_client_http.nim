import
  std/[unittest, httpclient, json, strformat, options, strutils],
  mcport/[mcp_client_http, mcp_client_core, mcp_server_http],
  ./test_helpers

suite "HTTP Client Tests":

  # Basic unit tests for client creation and state management
  test "client creation":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    check client.client.clientInfo.name == "TestHttpClient"
    check client.client.clientInfo.version == "1.0.0"
    check not client.client.initialized
    check client.baseUrl == "http://localhost:8080"
    check client.httpClient == nil
    check client.logEnabled == true

  test "client creation with logging disabled":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080", logEnabled = false)

    check not client.logEnabled

  test "connect sets up HTTP client":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    client.connect()

    check client.httpClient != nil
    check client.httpClient.headers != nil
    check client.httpClient.headers["Content-Type"] == "application/json"
    check client.httpClient.headers["Accept"] == "application/json"

  test "close cleans up HTTP client":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")
    client.connect()

    check client.httpClient != nil

    client.close()

    check client.httpClient == nil

  test "isConnected":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    check not client.isConnected()

    client.connect()

    check client.isConnected()

    client.close()

    check not client.isConnected()

  test "createExampleHttpClient":
    let client = createExampleHttpClient()

    check client.client.clientInfo.name == "TestHttpClient"
    check client.client.clientInfo.version == "1.0.0"
    check client.baseUrl == "http://localhost:8080"
    check client.logEnabled == true

  # Error handling tests (minimal, focused)
  test "initialize when not connected fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    expect CatchableError:
      client.initialize()

  test "initialize fails with invalid server":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")
    client.connect()

    expect CatchableError:
      client.initialize()

    client.close()

# Integration tests with a shared test server
# Global state for server management
var
  integrationTestServer: HttpMcpServer
  integrationTestServerThread: Thread[ServerThreadData]
  integrationTestServerPort: int
  integrationTestServerStarted: bool = false

proc ensureIntegrationTestServer() =
  ## Start the integration test server if not already running
  if not integrationTestServerStarted:
    let (srv, thread, port) = startTestHttpServer(0)
    integrationTestServer = srv
    integrationTestServerThread = thread
    integrationTestServerPort = port
    integrationTestServerStarted = true

proc cleanupIntegrationTestServer() =
  ## Clean up the integration test server
  if integrationTestServerStarted:
    stopTestHttpServer(integrationTestServer, integrationTestServerThread)
    integrationTestServerStarted = false

suite "HTTP Client Integration Tests":
  setup:
    ensureIntegrationTestServer()

  test "full workflow - initialize and list tools":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")
    defer: client.close()

    client.connect()
    client.initialize()

    check client.client.initialized
    check client.client.serverInfo.isSome
    check client.client.serverCapabilities.isSome

    client.listTools()

    let tools = client.getAvailableTools()
    check tools.len >= 1
    check "secret_fetcher" in tools

  test "full workflow - call tool":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")
    defer: client.close()

    client.connect()
    client.initialize()

    let result = client.callTool("secret_fetcher", %*{"recipient": "HTTPTest"})

    check result.hasKey("content")
    let content = result["content"]
    check content.len >= 1
    check content[0]["text"].getStr().contains("Hello, HTTPTest!")
    check result["isError"].getBool() == false

  test "full workflow - get available tools":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")
    defer: client.close()

    client.connect()
    client.initialize()

    let tools = client.getAvailableTools()

    check tools.len >= 1
    check "secret_fetcher" in tools

  test "multiple tool calls":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")
    defer: client.close()

    client.connect()
    client.initialize()

    for i in 1..3:
      let result = client.callTool("secret_fetcher", %*{"recipient": &"User{i}"})
      check result["content"][0]["text"].getStr().contains(&"Hello, User{i}!")

  test "reconnect after close":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")

    client.connect()
    client.initialize()
    check client.isConnected()
    check client.client.initialized

    client.close()
    check not client.isConnected()
    check not client.client.initialized

    client.connect()
    client.initialize()
    check client.isConnected()
    check client.client.initialized

    client.close()

  test "callTool fails when not initialized":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")
    defer: client.close()

    client.connect()

    expect CatchableError:
      discard client.callTool("secret_fetcher")

  test "server error handling":
    let client = newHttpMcpClient("TestClient", "1.0.0", &"http://localhost:{integrationTestServerPort}")
    defer: client.close()

    client.connect()
    client.initialize()

    expect CatchableError:
      discard client.callTool("non_existent_tool")
    
    # Clean up server after last test
    cleanupIntegrationTestServer()
    
    # Force clean exit to avoid background thread issues
    quit(0)
