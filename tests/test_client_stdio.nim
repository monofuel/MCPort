import
  std/[unittest, json, options, strutils, strformat, osproc, streams, os],
  mcport/[mcp_client_stdio, mcp_core],
  ./test_helpers

suite "STDIO Client Tests":

  test "client creation":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    check client.client.clientInfo.name == "TestStdioClient"
    check client.client.clientInfo.version == "1.0.0"
    check not client.client.initialized
    check client.process == nil
    check client.inputStream == nil
    check client.outputStream == nil
    check client.logEnabled == true

  test "client creation with logging disabled":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0", logEnabled = false)

    check not client.logEnabled

  test "isConnected when not connected":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    check not client.isConnected()

  test "connect with invalid command fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    expect CatchableError:
      client.connect("nonexistent_command")

    check client.process == nil

  test "close when not connected":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    # Should not raise an error
    client.close()

  # Note: Private methods like sendAndReceive are not tested directly.
  # Public methods that depend on connection will fail appropriately.


  test "initialize when not connected fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    expect CatchableError:
      client.initialize()

  test "listTools when not connected fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    expect CatchableError:
      client.listTools()

  test "callTool when not connected fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    expect CatchableError:
      discard client.callTool("test_tool")

  test "getAvailableTools when not connected fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    expect CatchableError:
      discard client.getAvailableTools()

  test "getAvailableTools when not initialized fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")
    # Mock connection without initialization
    client.process = Process()  # This is just for testing, not a real process

    expect CatchableError:
      discard client.getAvailableTools()

  test "callTool when not initialized fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")
    # Mock connection without initialization
    client.process = Process()  # This is just for testing, not a real process

    expect CatchableError:
      discard client.callTool("test_tool")

  test "listTools when not initialized fails":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")
    # Mock connection without initialization
    client.process = Process()  # This is just for testing, not a real process

    expect CatchableError:
      client.listTools()

  # Integration tests that require actual server processes
  # These would need to be run separately as they require external processes

  test "connectAndInitialize with invalid command":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0")

    expect CatchableError:
      client.connectAndInitialize("nonexistent_command")

  test "createExampleStdioClient":
    let client = createExampleStdioClient()

    check client.client.clientInfo.name == "TestStdioClient"
    check client.client.clientInfo.version == "1.0.0"
    check client.logEnabled == true

  # Test with a mock server process (echo server for testing)
  test "basic stdio communication with echo server":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0", logEnabled = false)

    # Start an echo server process
    let echoProcess = startProcess("echo", args = ["test response"], options = {poUsePath, poStdErrToStdOut})
    defer: echoProcess.close()

    # Mock the client's streams to use the echo process
    client.process = echoProcess
    client.inputStream = echoProcess.outputStream
    client.outputStream = echoProcess.inputStream

    # Test basic stream operations
    check client.isConnected()

    # Clean up
    client.close()
    check not client.isConnected()

  # Test with a simple test server script
  when defined(windows):
    const testServerCmd = "cmd"
    const testServerArgs = @["/c", "echo {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"TestServer\",\"version\":\"1.0.0\"}}}"]
  else:
    const testServerCmd = "sh"
    const testServerArgs = @["-c", "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"TestServer\",\"version\":\"1.0.0\"}}}'"]

  # Skip integration test that requires private method access
  # In a real testing scenario, this would test against an actual MCP server

  test "connectAndInitialize cleanup on error":
    let client = newStdioMcpClient("TestStdioClient", "1.0.0", logEnabled = false)

    # Connect to a command that will fail during initialization
    when defined(windows):
      expect CatchableError:
        client.connectAndInitialize("cmd", @["/c", "echo {\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Test error\"}}"])
    else:
      expect CatchableError:
        client.connectAndInitialize("sh", @["-c", "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Test error\"}}'"])

    # Verify cleanup happened
    check not client.isConnected()
    check client.process == nil
