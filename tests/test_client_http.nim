import
  std/[unittest, json, options, strutils, strformat, httpclient, net],
  mcport/[mcp_client_http, mcp_client_core, mcp_core],
  ./test_helpers

suite "HTTP Client Tests":

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

  # Note: Private methods like sendRequest are not tested directly.
  # Public methods that depend on connection will fail appropriately.

  test "initialize when not connected fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    expect CatchableError:
      client.initialize()

  test "listTools when not connected fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    expect CatchableError:
      client.listTools()

  test "callTool when not connected fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    expect CatchableError:
      discard client.callTool("test_tool")

  test "getAvailableTools when not connected fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    expect CatchableError:
      discard client.getAvailableTools()

  test "getAvailableTools when not initialized fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")
    client.connect()  # Connect but don't initialize

    expect CatchableError:
      discard client.getAvailableTools()

    client.close()

  test "callTool when not initialized fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")
    client.connect()  # Connect but don't initialize

    expect CatchableError:
      discard client.callTool("test_tool")

    client.close()

  test "listTools when not initialized fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")
    client.connect()  # Connect but don't initialize

    expect CatchableError:
      client.listTools()

    client.close()

  test "connectAndInitialize cleanup on error":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")

    expect CatchableError:
      client.connectAndInitialize()

    # Should be cleaned up
    check not client.isConnected()

  test "createExampleHttpClient":
    let client = createExampleHttpClient()

    check client.client.clientInfo.name == "TestHttpClient"
    check client.client.clientInfo.version == "1.0.0"
    check client.baseUrl == "http://localhost:8080"
    check client.logEnabled == true

  # Mock HTTP client for testing without real server
  test "initialize with unreachable server fails":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")
    client.connect()

    expect CatchableError:
      client.initialize()

    client.close()

  # Test error handling for HTTP request failures
  test "initialize handles HTTP errors":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")
    client.connect()

    expect CatchableError:
      client.initialize()

    client.close()

  test "listTools handles HTTP errors":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")
    client.connect()
    client.client.initialized = true  # Mock initialization

    expect CatchableError:
      client.listTools()

    client.close()

  test "callTool handles HTTP errors":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")
    client.connect()
    client.client.initialized = true  # Mock initialization

    expect CatchableError:
      discard client.callTool("test_tool")

    client.close()

  test "getAvailableTools handles HTTP errors":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://nonexistent-server:9999")
    client.connect()
    client.client.initialized = true  # Mock initialization

    expect CatchableError:
      discard client.getAvailableTools()

    client.close()

  # Test content-type validation (though this is more of a server concern)
  test "client sets correct content-type headers":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")
    client.connect()

    check client.httpClient.headers["Content-Type"] == "application/json"
    check client.httpClient.headers["Accept"] == "application/json"

    client.close()

  # Test request creation (can't easily test actual HTTP sending without a server)
  test "request creation":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080", logEnabled = false)

    let request = ClientRequest(
      jsonrpc: "2.0",
      id: 123,
      `method`: "test_method",
      params: %*{"key": "value"}
    )

    # Verify the request structure is correct
    check request.jsonrpc == "2.0"
    check request.id == 123
    check request.`method` == "test_method"
    check request.params["key"].getStr() == "value"

  test "multiple close calls are safe":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")
    client.connect()

    client.close()
    check not client.isConnected()

    # Second close should be safe
    client.close()
    check not client.isConnected()

  test "connect after close":
    let client = newHttpMcpClient("TestHttpClient", "1.0.0", "http://localhost:8080")

    client.connect()
    check client.isConnected()

    client.close()
    check not client.isConnected()

    client.connect()
    check client.isConnected()

    client.close()

  # Test URL handling
  test "client handles various URL formats":
    let client1 = newHttpMcpClient("Test", "1.0", "http://localhost:8080")
    check client1.baseUrl == "http://localhost:8080"

    let client2 = newHttpMcpClient("Test", "1.0", "https://example.com/api")
    check client2.baseUrl == "https://example.com/api"

    let client3 = newHttpMcpClient("Test", "1.0", "http://localhost:8080/mcp")
    check client3.baseUrl == "http://localhost:8080/mcp"

  # Test notification handling (though notifications are fire-and-forget in HTTP)
  test "notification request creation":
    let notification = createNotificationInitialized()
    check notification.`method` == "notifications/initialized"
    check notification.id == 0  # Notifications have id 0
