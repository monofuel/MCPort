import
  std/[json, locks, options, strutils, strformat, osproc, streams],
  jsony,
  ./[mcp_core, mcp_client_core, mcp_client_runtime]

export mcp_client_runtime

type
  StdioMcpClient* = ref object
    client*: McpClient
    process*: Process
    inputStream*: Stream
    outputStream*: Stream
    errorStream: Stream
    logEnabled*: bool
    inbox: ClientInbox
    reader: Thread[pointer]
    errorReader: Thread[pointer]
    writeLock: Lock
    reading: bool

proc log(client: StdioMcpClient, msg: string) =
  ## Log a message if logging is enabled.
  if client.logEnabled:
    echo fmt"[STDIO Client] {msg}"

proc newStdioMcpClient*(name: string, version: string, logEnabled: bool = true, modernProtocol = false, queueCapacity = DefaultSubscriptionQueueCapacity): StdioMcpClient =
  ## Create a new STDIO MCP client.
  result = StdioMcpClient(
    client: newMcpClient(name, version, modernProtocol),
    logEnabled: logEnabled, inbox: newClientInbox(queueCapacity)
  )
  initLock(result.writeLock)

proc stdioReader(data: pointer) {.thread.} =
  {.cast(gcsafe).}:
    let client {.cursor.} = cast[StdioMcpClient](data)
    try:
      while true:
        let line = client.inputStream.readLine()
        if line.len == 0:
          client.inbox.disconnect()
          break
        let message = parseJson(line)
        if not client.inbox.route(message):
          client.inbox.bufferNotification(message)
    except CatchableError as error:
      client.inbox.disconnect(error.msg)

proc stderrReader(data: pointer) {.thread.} =
  {.cast(gcsafe).}:
    let client {.cursor.} = cast[StdioMcpClient](data)
    let stream {.cursor.} = client.errorStream
    while not stream.atEnd:
      let line = stream.readLine()
      if client.logEnabled:
        stderr.writeLine(line)

proc connect*(client: StdioMcpClient, command: string, args: seq[string] = @[]) =
  ## Connect to an MCP server by launching a process.
  if client.reading:
    raise newException(ValueError, "Client already started; construct a new client to reconnect")
  let argsStr = args.join(" ")
  client.log(fmt"Launching server: {command} {argsStr}")
  
  try:
    client.process = startProcess(command, args = args, options = {poUsePath})
    client.inputStream = client.process.outputStream
    client.outputStream = client.process.inputStream
    client.errorStream = client.process.errorStream
    client.reading = true
    createThread(client.reader, stdioReader, cast[pointer](client))
    createThread(client.errorReader, stderrReader, cast[pointer](client))
  except Exception as e:
    raise newException(CatchableError, fmt"Failed to start MCP server process: {e.msg}")

proc isConnected*(client: StdioMcpClient): bool =
  ## Check if the client is connected to a server.
  client.process != nil and client.process.running()

proc sendRequest(client: StdioMcpClient, request: ClientRequest | ClientNotification) =
  ## Send a JSON-RPC request to the server.
  let jsonRequest = request.toJson()
  client.log(fmt"Sending: {jsonRequest}")
  
  try:
    withLock client.writeLock:
      client.outputStream.writeLine(jsonRequest)
      client.outputStream.flush()
  except Exception as e:
    raise newException(CatchableError, fmt"Failed to send request: {e.msg}")

proc sendAndReceive(client: StdioMcpClient, request: ClientRequest): ClientResult =
  client.sendRequest(request)
  let response = client.inbox.waitResponse(%request.id)
  client.inbox.dispatchNotifications(client.client.notificationCallback)
  parseResponse($response)

proc initialize*(client: StdioMcpClient) =
  ## Initialize the connection with the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  if client.client.modernProtocol:
    let response = client.sendAndReceive(client.client.createRequest("server/discover", %*{}))
    client.client.handleDiscoveryResponse(response)
    return
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
  client.client.initialized = false
  client.sendRequest(notification)
  client.client.initialized = true
  
  client.log("Successfully initialized")

proc listTools*(client: StdioMcpClient) =
  ## List available tools from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

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

proc callTool*(client: StdioMcpClient, toolName: string, arguments: JsonNode = %*{}): JsonNode =
  ## Call a tool on the server and return the result content.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  client.log(fmt"Calling tool: {toolName}")

  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")

  let callRequest = client.client.createToolCallRequest(toolName, arguments)
  let callResult = client.sendAndReceive(callRequest)
  
  if callResult.isError:
    let errorMessage = callResult.error.error.message
    client.log(fmt"Tool call failed: {errorMessage}")
    raise newException(CatchableError, fmt"Tool call '{toolName}' failed: {errorMessage}")
  
  # Return the actual result content from the server
  return callResult.response.result

proc getAvailableTools*(client: StdioMcpClient): seq[string] =
  ## Get list of available tool names from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")

  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")

  let listRequest = client.client.createToolsListRequest()
  let listResult = client.sendAndReceive(listRequest)
  
  if listResult.isError:
    let errorMessage = listResult.error.error.message
    client.log(fmt"List tools failed: {errorMessage}")
    raise newException(CatchableError, fmt"Failed to list tools: {errorMessage}")
  
  # Parse the tools from the response
  var toolNames: seq[string] = @[]
  if listResult.response.result.hasKey("tools"):
    for tool in listResult.response.result["tools"]:
      if tool.hasKey("name"):
        toolNames.add(tool["name"].getStr())
  
  return toolNames

proc listPrompts*(client: StdioMcpClient): JsonNode =
  ## List available prompts from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createPromptsListRequest()
  let res = client.sendAndReceive(req)
  if res.isError:
    raise newException(CatchableError, fmt"List prompts failed: {res.error.error.message}")
  return res.response.result

proc getPrompt*(client: StdioMcpClient, name: string, arguments: JsonNode = %*{}): JsonNode =
  ## Get a prompt by name from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createPromptsGetRequest(name, arguments)
  let res = client.sendAndReceive(req)
  if res.isError:
    raise newException(CatchableError, fmt"Get prompt failed: {res.error.error.message}")
  return res.response.result

proc listResources*(client: StdioMcpClient): JsonNode =
  ## List available resources from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createResourcesListRequest()
  let res = client.sendAndReceive(req)
  if res.isError:
    raise newException(CatchableError, fmt"List resources failed: {res.error.error.message}")
  return res.response.result

proc readResource*(client: StdioMcpClient, uri: string): JsonNode =
  ## Read a resource by URI from the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createResourcesReadRequest(uri)
  let res = client.sendAndReceive(req)
  if res.isError:
    raise newException(CatchableError, fmt"Read resource failed: {res.error.error.message}")
  return res.response.result

proc subscribeResource*(client: StdioMcpClient, uri: string): JsonNode =
  ## Subscribe to a resource by URI on the server.
  if not client.isConnected():
    raise newException(CatchableError, "Client not connected to server")
  if not client.client.initialized:
    raise newException(CatchableError, "Client not initialized")
  let req = client.client.createResourcesSubscribeRequest(uri)
  let res = client.sendAndReceive(req)
  if res.isError:
    raise newException(CatchableError, fmt"Subscribe resource failed: {res.error.error.message}")
  return res.response.result

proc close*(client: StdioMcpClient) =
  ## Close the connection to the server.
  if client.process != nil:
    client.log("Closing connection...")
    client.process.terminate()
    if client.reading:
      joinThread(client.reader)
      joinThread(client.errorReader)
      client.reading = false
    if client.inputStream != nil:
      client.inputStream.close()
    if client.outputStream != nil:
      client.outputStream.close()
    discard client.process.waitForExit(timeout = 1000)  # Wait 1 second
    client.process.close()
    
    client.inbox.closeInbox()
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

proc request*(client: StdioMcpClient, methodName: string, params: JsonNode = %*{}): JsonNode =
  let response = client.sendAndReceive(client.client.createRequest(methodName, params))
  if response.isError:
    raise newException(IOError, response.error.error.message)
  response.response.result

proc openSubscription*(client: StdioMcpClient, methodName: string, params: JsonNode): Subscription =
  let req = client.client.createRequest(methodName, params)
  result = client.inbox.registerSubscription(%req.id, proc(id: JsonNode) =
    client.sendRequest(ClientNotification(jsonrpc: "2.0", `method`: "notifications/cancelled",
      params: %*{"requestId": id})))
  client.sendRequest(req)
  try:
    result.waitAcknowledged()
  except CatchableError:
    result.close()
    raise
