import
  std/[json, options, tables, unittest],
  jsony,
  mcport/[mcp_client_core, mcp_core]

const
  ToggleToolName = "toggle_category"
  FinanceCategory = "finance"
  FinanceToolName = "fetch_bitcoin_price"

var
  toggleServerPtr: pointer = nil
  seenNotificationCount {.threadvar.}: int

proc financeToolDef(): McpTool =
  ## Build the finance tool definition used by toggle tests.
  McpTool(
    name: FinanceToolName,
    description: "Fetch a mocked bitcoin price.",
    inputSchema: %*{
      "type": "object",
      "properties": {},
      "required": [],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

proc toggleToolDef(): McpTool =
  ## Build the category toggle tool definition used by toggle tests.
  McpTool(
    name: ToggleToolName,
    description: "Enable or disable a tool category.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "category": {
          "type": "string"
        },
        "enabled": {
          "type": "boolean"
        }
      },
      "required": ["category", "enabled"],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

proc financeToolHandler(arguments: JsonNode): JsonNode {.gcsafe.} =
  ## Return a deterministic mocked finance value.
  discard arguments
  %*("BTC/USD: 123456.78")

proc onNotification(notification: JsonNode) {.gcsafe.} =
  ## Capture notifications emitted by the server.
  discard notification
  inc seenNotificationCount

proc toggleServer(): McpServer =
  ## Return the current toggle test server instance.
  cast[McpServer](toggleServerPtr)

proc toggleToolHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
  ## Toggle finance category tools and return tool-list version metadata.
  let category = arguments["category"].getStr()
  let enabled = arguments["enabled"].getBool()

  if category != FinanceCategory:
    raise newException(ValueError, "Unknown category: " & category)

  if enabled:
    if not toggleServer().tools.hasKey(FinanceToolName):
      toggleServer().registerTool(financeToolDef(), financeToolHandler)
  else:
    toggleServer().unregisterTool(FinanceToolName)

  let isFinanceEnabled = toggleServer().tools.hasKey(FinanceToolName)
  let enabledCategories = if isFinanceEnabled: @[FinanceCategory] else: @[]

  ToolResult(
    content: @[textContent("category toggled")],
    structuredContent: some(%*{
      "enabled": enabledCategories,
      "tool_list_version": toggleServer().toolListVersion
    }),
    isError: false
  )

proc sendRequest(server: McpServer, request: ClientRequest): ClientResult =
  ## Send a client request to the server and parse a JSON-RPC result.
  let serverResult = server.handleRequest(request.toJson())
  if serverResult.isError:
    return parseResponse(serverResult.error.toJson())

  return parseResponse(serverResult.response.toJson())

suite "Toggle Tools Tests":

  test "toggle workflow with deterministic relist fallback":
    let server = newMcpServer("ToggleTestServer", "1.0.0")
    toggleServerPtr = cast[pointer](server)
    seenNotificationCount = 0

    server.registerRichTool(toggleToolDef(), toggleToolHandler)
    let initialVersion = server.toolListVersion
    check initialVersion >= 1

    server.setNotificationCallback(onNotification)

    let client = newMcpClient("ToggleTestClient", "1.0.0")

    let initResult = server.sendRequest(client.createInitializeRequest())
    check not initResult.isError
    check client.handleInitializeResponse(initResult)

    let initialListResult = server.sendRequest(client.createToolsListRequest())
    check not initialListResult.isError
    check client.handleToolsListResponse(initialListResult)
    check client.isToolAvailable(ToggleToolName)
    check not client.isToolAvailable(FinanceToolName)

    let enableResult = server.sendRequest(
      client.createToolCallRequest(
        ToggleToolName,
        %*{"category": FinanceCategory, "enabled": true}
      )
    )
    check not enableResult.isError

    let enableVersion = enableResult.response.result["structuredContent"]["tool_list_version"].getInt()
    check enableVersion > initialVersion

    check seenNotificationCount == 1

    check not client.isToolAvailable(FinanceToolName)

    let relistAfterEnable = server.sendRequest(client.createToolsListRequest())
    check not relistAfterEnable.isError
    check client.handleToolsListResponse(relistAfterEnable)
    check client.isToolAvailable(FinanceToolName)

    let financeCallResult = server.sendRequest(client.createToolCallRequest(FinanceToolName, %*{}))
    check not financeCallResult.isError
    let financeText = financeCallResult.response.result["content"][0]["text"].getStr()
    check financeText == "BTC/USD: 123456.78"

    let disableResult = server.sendRequest(
      client.createToolCallRequest(
        ToggleToolName,
        %*{"category": FinanceCategory, "enabled": false}
      )
    )
    check not disableResult.isError

    let disableVersion = disableResult.response.result["structuredContent"]["tool_list_version"].getInt()
    check disableVersion > enableVersion

    check seenNotificationCount == 2

    let relistAfterDisable = server.sendRequest(client.createToolsListRequest())
    check not relistAfterDisable.isError
    check client.handleToolsListResponse(relistAfterDisable)
    check not client.isToolAvailable(FinanceToolName)

    let removedToolCall = server.sendRequest(client.createToolCallRequest(FinanceToolName, %*{}))
    check removedToolCall.isError
    check removedToolCall.error.error.code == -32602

    let disableAgainResult = server.sendRequest(
      client.createToolCallRequest(
        ToggleToolName,
        %*{"category": FinanceCategory, "enabled": false}
      )
    )
    check not disableAgainResult.isError

    let disableAgainVersion = disableAgainResult.response.result["structuredContent"]["tool_list_version"].getInt()
    check disableAgainVersion == disableVersion
    check seenNotificationCount == 2
