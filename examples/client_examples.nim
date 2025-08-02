## Example usage of MCPort client functionality
## This shows how to create MCP clients for both STDIO and HTTP transports

import
  std/[json, os, strformat],
  mcport

proc demonstrateStdioClient() =
  ## Example of using the STDIO client to connect to an MCP server.
  echo "\n=== STDIO Client Example ==="
  
  let client = newStdioMcpClient("ExampleStdioClient", "1.0.0")
  
  # For this example, we'd connect to a server process
  # In a real scenario, you'd have the path to your MCP server executable
  let serverPath = "path/to/your/mcp/server"
  
  echo fmt"Attempting to connect to server: {serverPath}"
  
  # Connect and initialize (this launches the server process)
  if client.connectAndInitialize(serverPath, @[]):
    echo "✅ Successfully connected and initialized!"
    
    # List available tools
    let toolList = client.getAvailableTools().join(", ")
    echo fmt"Available tools: {toolList}"
    
    # Call the secret_fetcher tool with default recipient
    echo "\n--- Calling secret_fetcher with default recipient ---"
    let result1 = client.callTool("secret_fetcher")
    if not result1.isError:
      for item in result1.content:
        echo fmt"Response: {item.text}"
    else:
      echo fmt"Error: {result1.errorMessage}"
    
    # Call with custom recipient
    echo "\n--- Calling secret_fetcher with custom recipient ---"
    let result2 = client.callTool("secret_fetcher", %*{"recipient": "Alice"})
    if not result2.isError:
      for item in result2.content:
        echo fmt"Response: {item.text}"
    else:
      echo fmt"Error: {result2.errorMessage}"
    
    # Try to call an unknown tool
    echo "\n--- Trying to call unknown tool ---"
    let result3 = client.callTool("unknown_tool")
    if result3.isError:
      echo fmt"Expected error: {result3.errorMessage}"
    
    # Clean up
    client.close()
    echo "Connection closed."
  else:
    echo "❌ Failed to connect to server (server not found for demo)"

proc demonstrateHttpClient() =
  ## Example of using the HTTP client to connect to an MCP server.
  echo "\n=== HTTP Client Example ==="
  
  let client = newHttpMcpClient("ExampleHttpClient", "1.0.0", "http://localhost:8080")
  
  echo fmt"Attempting to connect to HTTP server: {client.baseUrl}"
  
  # Connect and initialize
  if client.connectAndInitialize():
    echo "✅ Successfully connected and initialized!"
    
    # List available tools
    echo fmt"Available tools: {client.getAvailableTools().join(\", \")}"
    
    # Call the secret_fetcher tool with default recipient
    echo "\n--- Calling secret_fetcher with default recipient ---"
    let result1 = client.callTool("secret_fetcher")
    if not result1.isError:
      for item in result1.content:
        echo fmt"Response: {item.text}"
    else:
      echo fmt"Error: {result1.errorMessage}"
    
    # Call with custom recipient
    echo "\n--- Calling secret_fetcher with custom recipient ---"
    let result2 = client.callTool("secret_fetcher", %*{"recipient": "Bob"})
    if not result2.isError:
      for item in result2.content:
        echo fmt"Response: {item.text}"
    else:
      echo fmt"Error: {result2.errorMessage}"
    
    # Clean up
    client.close()
    echo "Connection closed."
  else:
    echo "❌ Failed to connect to HTTP server (server not running for demo)"

proc demonstrateClientCore() =
  ## Example of using the core client functionality.
  echo "\n=== Client Core Example ==="
  
  let client = newMcpClient("ExampleCoreClient", "1.0.0")
  
  echo fmt"Created client: {client.clientInfo.name} v{client.clientInfo.version}"
  echo fmt"Initialized: {client.initialized}"
  
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
  echo fmt"Tool call request tool name: {callRequest.params[\"name\"].getStr()}"
  
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
    echo fmt"✅ Parsed error response: {errorResult.error.error.message}"

proc stepByStepStdioExample() =
  ## Detailed step-by-step example for STDIO client.
  echo "\n=== Step-by-Step STDIO Client Example ==="
  
  # Step 1: Create client
  echo "Step 1: Creating STDIO client..."
  let client = newStdioMcpClient("StepByStepClient", "1.0.0")
  
  # Step 2: Connect (this would launch server process)
  echo "Step 2: Connecting to server process..."
  # In a real scenario: client.connect("your-server-command", @["arg1", "arg2"])
  echo "  (Would execute: your-server-command arg1 arg2)"
  
  # Step 3: Initialize connection
  echo "Step 3: Initializing MCP connection..."
  # In a real scenario: client.initialize()
  echo "  (Sends initialize request and waits for response)"
  
  # Step 4: List tools
  echo "Step 4: Listing available tools..."
  # In a real scenario: client.listTools()
  echo "  (Sends tools/list request and caches results)"
  
  # Step 5: Call tools
  echo "Step 5: Calling tools..."
  # In a real scenario: 
  # let result = client.callTool("secret_fetcher", %*{"recipient": "User"})
  echo "  (Sends tools/call request with parameters)"
  
  # Step 6: Handle results
  echo "Step 6: Processing results..."
  echo "  (Parse response content and handle errors)"
  
  # Step 7: Cleanup
  echo "Step 7: Cleaning up..."
  client.close()
  echo "  (Terminates server process and closes streams)"

proc main() =
  ## Main function demonstrating all client examples.
  echo "MCPort Client Examples"
  echo "====================="
  
  # Core functionality (always works)
  demonstrateClientCore()
  
  # Step-by-step guide
  stepByStepStdioExample()
  
  # Transport examples (these require actual servers running)
  echo "\nNote: The following examples require running MCP servers:"
  demonstrateStdioClient()
  demonstrateHttpClient()
  
  echo "\n=== All Examples Complete ==="
  echo "To run these examples with real servers:"
  echo "1. For STDIO: Compile an MCP server and update the serverPath"
  echo "2. For HTTP: Start an HTTP MCP server on localhost:8080"

when isMainModule:
  main() 
