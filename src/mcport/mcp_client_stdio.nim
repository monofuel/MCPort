import
  std/[json, strutils, strformat, osproc, streams],
  jsony,
  ./[mcp_core, mcp_client_core]

type
  StdioMcpClient* = ref object
    client*: McpClient
    process*: Process
    inputStream*: Stream
    outputStream*: Stream
    logEnabled*: bool

proc log(client: StdioMcpClient, msg: string) =
  ## Log a message if logging is enabled.
  if client.logEnabled:
    echo fmt"[STDIO Client] {msg}"

proc newStdioMcpClient*(name: string, version: string, logEnabled: bool = true): StdioMcpClient =
  ## Create a new STDIO MCP client.
  StdioMcpClient(
    client: newMcpClient(name, version),
    logEnabled: logEnabled
  )

proc connect*(client: StdioMcpClient, command: string, args: seq[string] = @[]) =
  ## Connect to an MCP server by launching a process.
  let argsStr = args.join(" ")
  client.log(fmt"Launching server: {command} {argsStr}")
  
  try:
    client.process = startProcess(command, args = args, options = {poUsePath})
    client.inputStream = client.process.outputStream
    client.outputStream = client.process.inputStream
  except Exception as e:
    raise newException(CatchableError, fmt"Failed to start MCP server process: {e.msg}")

proc sendRequest(client: StdioMcpClient, request: ClientRequest) =
  ## Send a JSON-RPC request to the server.
  let jsonRequest = request.toJson()
  client.log(fmt"Sending: {jsonRequest}")
  
  try:
    client.outputStream.writeLine(jsonRequest)
    client.outputStream.flush()
  except Exception as e:
    raise newException(CatchableError, fmt"Failed to send request: {e.msg}")

proc readResponse(client: StdioMcpClient): string =
  ## Read a JSON-RPC response from the server.
  try:
    let response = client.inputStream.readLine()
    client.log(fmt"Received: {response}")
    return response
  except Exception as e:
    client.log(fmt"Failed to read response: {e.msg}")
    raise newException(CatchableError, fmt"Failed to read response: {e.msg}")

proc sendAndReceive(client: StdioMcpClient, request: ClientRequest): ClientResult =
  ## Send a request and receive the response.
  client.sendRequest(request)
  
  let responseStr = client.readResponse()
  if responseStr == "":
    raise newException(CatchableError, "Received empty response from server")
  
  return parseResponse(responseStr)

proc initialize*(client: StdioMcpClient) =
  ## Initialize the connection with the server.
  client.log("Initializing connection...")
  
  # Send initialize request
  let initRequest = client.client.createInitializeRequest()
  let initResult = client.sendAndReceive(initRequest)
  
  if initResult.isError:
    let errorMessage = initResult.error.error.message
    client.log(fmt"Initialize failed: {errorMessage}")
    raise newException(CatchableError, fmt"Initialize failed: {errorMessage}")
  
  if not client.client.handleInitializeResponse(initResult):
    raise newException(CatchableError, "Failed to process initialize response")
  
  # Send initialized notification (no response expected)
  let notification = createNotificationInitialized()
  client.sendRequest(notification)
  
  client.log("Successfully initialized")

proc listTools*(client: StdioMcpClient) =
  ## List available tools from the server.
  client.log("Listing available tools...")
  
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  
  let listRequest = client.client.createToolsListRequest()
  let listResult = client.sendAndReceive(listRequest)
  
  if listResult.isError:
    let errorMessage = listResult.error.error.message
    client.log(fmt"List tools failed: {errorMessage}")
    raise newException(CatchableError, fmt"List tools failed: {errorMessage}")
  
  # For now, just log success - we'll implement tool processing later
  client.log("Tools list received successfully")

proc callTool*(client: StdioMcpClient, toolName: string, arguments: JsonNode = %*{}): ToolCallResult =
  ## Call a tool on the server.
  client.log(fmt"Calling tool: {toolName}")
  
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  
  # For now, just try to call the tool without checking availability
  let callRequest = client.client.createToolCallRequest(toolName, arguments)
  let callResult = client.sendAndReceive(callRequest)
  
  # Simple result handling
  if callResult.isError:
    return ToolCallResult(
      isError: true,
      errorMessage: callResult.error.error.message
    )
  else:
    return ToolCallResult(
      isError: false,
      content: @[ContentItem(`type`: "text", text: "Tool called successfully")]
    )

proc getAvailableTools*(client: StdioMcpClient): seq[string] =
  ## Get list of available tool names.
  @[]  # Return empty list for now

proc isConnected*(client: StdioMcpClient): bool =
  ## Check if the client is connected to a server.
  client.process != nil and client.process.running()

proc close*(client: StdioMcpClient) =
  ## Close the connection to the server.
  if client.process != nil:
    client.log("Closing connection...")
    if client.inputStream != nil:
      client.inputStream.close()
    if client.outputStream != nil:
      client.outputStream.close()
    client.process.terminate()
    discard client.process.waitForExit(timeout = 1000)  # Wait 1 second
    client.process.close()
    
    client.process = nil
    client.inputStream = nil
    client.outputStream = nil
    client.log("Connection closed")

proc connectAndInitialize*(client: StdioMcpClient, command: string, args: seq[string] = @[]) =
  ## Connect to a server and initialize the connection.
  client.connect(command, args)
  
  try:
    client.initialize()
    client.listTools()
  except Exception as e:
    client.close()
    raise e

# Example usage function
proc createExampleStdioClient*(): StdioMcpClient =
  ## Create an example STDIO client for testing.
  newStdioMcpClient("TestStdioClient", "1.0.0") 
