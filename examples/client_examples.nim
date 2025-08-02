## Example usage of MCPort client functionality
## This shows how to create MCP clients for both STDIO and HTTP transports

import
  std/[json, os, strformat, strutils, osproc],
  ../src/mcport/[mcp_client_stdio, mcp_client_http, mcp_client_core]

proc demonstrateStdioClient() =
  ## Example of using the STDIO client to connect to an MCP server.
  echo "\n=== STDIO Client Example ==="
  
  let client = newStdioMcpClient("ExampleStdioClient", "1.0.0")
  
  # Compile the server first to avoid mixing compilation output with MCP communication
  echo "Compiling STDIO MCP server..."
  let compileResult = execCmd("nim c src/mcport/mcp_server_stdio.nim")
  if compileResult != 0:
    raise newException(CatchableError, "Failed to compile STDIO MCP server")
  
  # Now run the compiled binary
  let serverPath = "src/mcport/mcp_server_stdio"
  let serverArgs: seq[string] = @[]
  
  echo fmt"Attempting to connect to server: {serverPath}"
  
  # Connect and initialize - throws exceptions on failure
  client.connectAndInitialize(serverPath, serverArgs)
  echo "✅ Successfully connected and initialized!"
  
  # List available tools - throws exception on failure
  let toolList = client.getAvailableTools().join(", ")
  echo fmt"Available tools: {toolList}"
  
  # Call the secret_fetcher tool with default recipient - throws exception on failure
  echo "\n--- Calling secret_fetcher with default recipient ---"
  let result1 = client.callTool("secret_fetcher")
  echo fmt"Response: {result1}"
  
  # Call with custom recipient - throws exception on failure
  echo "\n--- Calling secret_fetcher with custom recipient ---"
  let result2 = client.callTool("secret_fetcher", %*{"recipient": "Alice"})
  echo fmt"Response: {result2}"
  
  # Clean up
  client.close()
  echo "Connection closed."
    

proc demonstrateHttpClient() =
  ## Example of using the HTTP client to connect to an MCP server.
  echo "\n=== HTTP Client Example ==="
  
  # Compile the HTTP server first
  echo "Compiling HTTP MCP server..."
  let compileResult = execCmd("nim c src/mcport/mcp_server_http.nim")
  if compileResult != 0:
    raise newException(CatchableError, "Failed to compile HTTP MCP server")
  
  # Start the HTTP server using the compiled binary
  echo "Starting HTTP MCP server..."
  let serverProcess = startProcess("src/mcport/mcp_server_http", 
                                   options = {poUsePath, poStdErrToStdOut})
  
  # Give the server time to start up - 3 seconds should be enough since it's pre-compiled
  echo "Waiting for server to start..."
  sleep(3000)  # 3 seconds
  
  # Use the correct port that the server actually runs on (8097)
  let client = newHttpMcpClient("ExampleHttpClient", "1.0.0", "http://localhost:8097")
  
  let serverUrl = client.baseUrl
  echo fmt"Attempting to connect to HTTP server: {serverUrl}"
  
  try:
    # Connect and initialize - throws exceptions on failure
    client.connectAndInitialize()
    echo "✅ Successfully connected and initialized!"
    
    # List available tools - throws exception on failure
    let availableTools = client.getAvailableTools().join(", ")
    echo fmt"Available tools: {availableTools}"
    
    # Call the secret_fetcher tool with default recipient - throws exception on failure
    echo "\n--- Calling secret_fetcher with default recipient ---"
    let result1 = client.callTool("secret_fetcher")
    echo fmt"Response: {result1}"
    
    # Call with custom recipient - throws exception on failure
    echo "\n--- Calling secret_fetcher with custom recipient ---"
    let result2 = client.callTool("secret_fetcher", %*{"recipient": "Bob"})
    echo fmt"Response: {result2}"
    
    # Clean up client
    client.close()
    echo "Connection closed."
    
  except Exception as e:
    client.close()
    raise newException(CatchableError, fmt"HTTP client example failed: {e.msg}")
  finally:
    # Clean up server process
    echo "Stopping HTTP MCP server..."
    serverProcess.terminate()
    serverProcess.close()

proc demonstrateClientCore() =
  ## Example of using the core client functionality.
  echo "\n=== Client Core Example ==="
  
  let client = newMcpClient("ExampleCoreClient", "1.0.0")
  
  let clientName = client.clientInfo.name
  let clientVersion = client.clientInfo.version
  let isInitialized = client.initialized
  echo fmt"Created client: {clientName} v{clientVersion}"
  echo fmt"Initialized: {isInitialized}"
  
  # Create some example requests
  let initRequest = client.createInitializeRequest()
  echo fmt"Initialize request method: {initRequest.`method`}"
  echo fmt"Initialize request ID: {initRequest.id}"
  
  let listRequest = client.createToolsListRequest()
  echo fmt"Tools list request method: {listRequest.`method`}"
  
  let callRequest = client.createToolCallRequest("example_tool", %*{
    "param1": "value1",
    "param2": 42
  })
  echo fmt"Tool call request method: {callRequest.`method`}"
  let toolName = callRequest.params["name"].getStr()
  echo fmt"Tool call request tool name: {toolName}"
  
  # Example of parsing responses
  echo "\n--- Response Parsing Examples ---"
  
  # Success response
  let successJson = """{"jsonrpc":"2.0","id":1,"result":{"message":"success"}}"""
  let successResult = parseResponse(successJson)
  if not successResult.isError:
    echo "✅ Parsed success response correctly"
  
  # Error response
  let errorJson = """{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params"}}"""
  let errorResult = parseResponse(errorJson)
  if errorResult.isError:
    let errorMessage = errorResult.error.error.message
    echo fmt"✅ Parsed error response: {errorMessage}"

proc main() =
  ## Main function demonstrating all client examples.
  echo "MCPort Client Examples"
  echo "====================="
  
  # Core functionality (always works)
  demonstrateClientCore()
  
  # Transport examples (these now start their own servers)
  echo "\nRunning transport examples with real MCP servers:"
  
  # Each example will fail fast and loud if there are issues
  demonstrateStdioClient()
  demonstrateHttpClient()
  
  echo "\n=== All Examples Complete ==="
  echo "Both examples now automatically start their own MCP servers:"
  echo "1. STDIO: Compiles and runs src/mcport/mcp_server_stdio.nim"
  echo "2. HTTP: Compiles and runs src/mcport/mcp_server_http.nim on localhost:8097"

when isMainModule:
  main() 
