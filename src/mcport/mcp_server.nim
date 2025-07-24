import
  std/[streams, times, strformat, strutils, os, json, options],
  jsony

const
  MCP_VERSION = "2024-11-05"  ## MCP protocol version (updated to match client)
  TOOL_SHIBBOLEET = "secret_fetcher"  ## Name of our tool
  SHIBBOLEET_RESPONSE = "Shibboleet says: Leet greetings from the universe!"  ## Tool response
  LOG_FILE = "C:\\Users\\monofuel\\Documents\\Code\\nim_mcp_server\\mcp_server.log" ## Log file absolute path

var
  logFile: File
  initialized = false  ## Track initialization state

proc logToFile(stream: char, msg: string) =
  ## Log a message to file and stderr with stream prefix
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  let formattedMsg = fmt"[{timestamp}] {stream} {msg}"
  
  if logFile.isNil:
    logFile = open(LOG_FILE, fmAppend)
  logFile.writeLine(formattedMsg)
  logFile.flushFile()
  

proc log*(msg: string) =
  ## Log to stderr and file with 'E' prefix
  logToFile('E', msg)
  stderr.writeLine(msg)
  stderr.flushFile()

type
  RpcRequest = object
    jsonrpc: string
    id: int
    `method`: string
    params: JsonNode
    
  RpcNotification = object
    jsonrpc: string
    `method`: string
    
  RpcResponse = object
    jsonrpc: string
    id: int
    result: JsonNode
    
  RpcError = object
    jsonrpc: string
    id: int
    error: ErrorDetail
    
  ErrorDetail = object
    code: int
    message: string

  InitParams = object
    protocolVersion: string
    capabilities: JsonNode
    clientInfo: JsonNode
    
  ServerCapabilities = object
    tools: ToolCaps
  ToolCaps = object
    listChanged: bool
    
  ServerInfo = object
    name: string
    version: string

  ListParams = object
    cursor: Option[string]  # Optional cursor for pagination

  CallToolParams = object
    name: string
    arguments: JsonNode

proc sendMcpMessage[T](msg: T) =
  ## Send a properly formatted JSON-RPC message to stdout and log it
  let jsonMsg = msg.toJson()
  stdout.write(jsonMsg)
  stdout.write("\n")
  stdout.flushFile()
  logToFile('O', "Sent: " & jsonMsg)

proc handleRequest(line: string) =
  ## Handle an incoming MCP request from stdin
  logToFile('I', line)
  
  try:
    let request = line.fromJson(RpcRequest)
    if request.jsonrpc != "2.0":
      let error = RpcError(
        jsonrpc: "2.0",
        id: request.id,
        error: ErrorDetail(code: -32600, message: "Invalid JSON-RPC version")
      )
      sendMcpMessage(error)
      return

    case request.`method`
    of "initialize":
      if initialized:
        let error = RpcError(
          jsonrpc: "2.0",
          id: request.id,
          error: ErrorDetail(code: -32000, message: "Already initialized")
        )
        sendMcpMessage(error)
        return
      
      let params = request.params.toJson().fromJson(InitParams)
      let response = RpcResponse(
        jsonrpc: "2.0",
        id: request.id,
        result: %*{
          "protocolVersion": MCP_VERSION,
          "capabilities": {
            "tools": {
              "listChanged": true
            }
          },
          "serverInfo": {
            "name": "NimMCPServer",
            "version": "1.0.0"
          }
        }
      )
      sendMcpMessage(response)
      initialized = true
    
    of "notifications/initialized":
      let notification = line.fromJson(RpcNotification)
      if not initialized:
        log("Warning: Received initialized notification before initialization")
      log("Client confirmed initialization")
    
    of "tools/list":
      if not initialized:
        let error = RpcError(
          jsonrpc: "2.0",
          id: request.id,
          error: ErrorDetail(code: -32001, message: "Server not initialized")
        )
        sendMcpMessage(error)
        return
        
      let params = request.params.toJson().fromJson(ListParams)
      let response = RpcResponse(
        jsonrpc: "2.0",
        id: request.id,
        result: %*{
          "tools": [
            {
              "name": TOOL_SHIBBOLEET,
              "description": "Delivers a secret leet greeting from the universe",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "recipient": {
                    "type": "string",
                    "description": "Who to greet (optional)"
                  }
                },
                "required": [],
                "additionalProperties": false,
                "$schema": "http://json-schema.org/draft-07/schema#"
              }
            }
          ],
          # "nextCursor": nil
        }
      )
      sendMcpMessage(response)
    
    of "tools/call":
      if not initialized:
        let error = RpcError(
          jsonrpc: "2.0",
          id: request.id,
          error: ErrorDetail(code: -32001, message: "Server not initialized")
        )
        sendMcpMessage(error)
        return
        
      let params = request.params.toJson().fromJson(CallToolParams)
      if params.name == TOOL_SHIBBOLEET:
        let recipient = if params.arguments.hasKey("recipient"): params.arguments["recipient"].getStr() else: "friend"
        let response = RpcResponse(
          jsonrpc: "2.0",
          id: request.id,
          result: %*{
            "content": [
              {
                "type": "text",
                "text": SHIBBOLEET_RESPONSE & " Hello, " & recipient & "!"
              }
            ],
            "isError": false
          }
        )
        sendMcpMessage(response)
      else:
        let error = RpcError(
          jsonrpc: "2.0",
          id: request.id,
          error: ErrorDetail(code: -32602, message: "Unknown tool name")
        )
        sendMcpMessage(error)
    
    of "resources/list", "prompts/list", "resources/read", "get_resource":
      let error = RpcError(
        jsonrpc: "2.0",
        id: request.id,
        error: ErrorDetail(code: -32601, message: "Method not supported")
      )
      sendMcpMessage(error)
    
    else:
      let error = RpcError(
        jsonrpc: "2.0",
        id: request.id,
        error: ErrorDetail(code: -32601, message: "Method not found")
      )
      sendMcpMessage(error)
  
  except jsony.JsonError:
    let error = RpcError(
      jsonrpc: "2.0",
      id: 0,
      error: ErrorDetail(code: -32700, message: "Invalid JSON")
    )
    sendMcpMessage(error)

proc runServer() =
  ## Run the MCP server main loop
  log("Server starting...")
  
  for line in stdin.lines:
    if line.len > 0:
      log("Received: " & line)
      handleRequest(line.strip())
  
  if not logFile.isNil:
    log("Server shutting down...")
    logFile.close()

when isMainModule:
  runServer()