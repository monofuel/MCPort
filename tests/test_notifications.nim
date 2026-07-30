import
  std/[json, options, unittest],
  mcport/mcp_core,
  ./test_helpers

var capturedNotifications {.threadvar.}: seq[JsonNode]

proc clearCapture() =
  ## Reset the captured notifications buffer before each test.
  capturedNotifications = @[]

proc captureCallback(n: JsonNode) {.gcsafe.} =
  ## Append incoming notifications to the module-level buffer.
  capturedNotifications.add(n)

suite "Notification Delivery and Ordering":

  test "tool registration emits notifications/tools/list_changed":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    registerTestTool(server, "my_tool")

    check capturedNotifications.len == 1
    check capturedNotifications[0]["method"].getStr() == "notifications/tools/list_changed"

  test "tool unregistration emits notifications/tools/list_changed":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    registerTestTool(server, "my_tool")
    server.unregisterTool("my_tool")

    check capturedNotifications.len == 2
    check capturedNotifications[1]["method"].getStr() == "notifications/tools/list_changed"

  test "idempotent unregister does not emit notification":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    registerTestTool(server, "my_tool")
    let countAfterRegister = capturedNotifications.len
    server.unregisterTool("nonexistent_tool")

    check capturedNotifications.len == countAfterRegister

  test "prompt registration emits notifications/prompts/list_changed":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    registerTestPrompt(server, "my_prompt")

    check capturedNotifications.len == 1
    check capturedNotifications[0]["method"].getStr() == "notifications/prompts/list_changed"

  test "resource subscription + update emits notifications/resources/updated":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    registerTestResource(server, "res://example")

    let subscribeRequest = makeResourceSubscribeRequest(1, "res://example")
    let result = server.handleRequest(subscribeRequest)
    check not result.isError

    server.notifyResourceUpdated("res://example")

    var updatedNotifs: seq[JsonNode]
    for n in capturedNotifications:
      if n["method"].getStr() == "notifications/resources/updated":
        updatedNotifs.add(n)

    check updatedNotifs.len == 1
    check updatedNotifs[0]["params"]["uri"].getStr() == "res://example"

  test "resource update notification skipped for unsubscribed resource":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    server.notifyResourceUpdated("res://not-subscribed")

    for n in capturedNotifications:
      check n["method"].getStr() != "notifications/resources/updated"

  test "progress notification contains correct fields":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    server.notifyProgress("tok-1", some(0.5), some("halfway"))

    check capturedNotifications.len == 1
    let n = capturedNotifications[0]
    check n["method"].getStr() == "notifications/progress"
    check n["params"]["progressToken"].getStr() == "tok-1"
    check n["params"]["progress"].getFloat() == 0.5
    check n["params"]["status"].getStr() == "halfway"

  test "progress notification with value > 1.0 is not emitted":
    clearCapture()
    let server = newMcpServer("TestServer", "1.0.0")
    server.setNotificationCallback(captureCallback)
    server.notifyProgress("tok-2", some(1.5), some("over"))

    check capturedNotifications.len == 0
