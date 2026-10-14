import
  std/[json, os, strutils, tables, unittest],
  curly, mcport,
  ./http_client_fixture

if paramCount() == 2 and paramStr(1) == "--fixture":
  runHttpFixture(parseInt(paramStr(2)))
  quit(0)

let fixture = startHttpFixture()

proc fixtureClient(path = ""): HttpMcpClient =
  var headers = emptyHttpHeaders()
  headers["Authorization"] = "Bearer " & FixtureToken
  result = newHttpMcpClient("test", "1", fixture.url & path, logEnabled = false, requestHeaders = headers, timeoutSeconds = 1)
  result.connect()

suite "authenticated JSON HTTP MCP":
  test "initialization, notification, pagination and complete tool results":
    let client = fixtureClient()
    defer: client.close()
    client.initialize()
    client.listTools()
    check client.client.protocolVersion == "2025-06-18"
    check client.client.availableTools.len == 5
    check client.getAvailableTools().len == 5
    let response = client.callTool("echo", %*{"value": "hello"})
    check response["structuredContent"]["arguments"]["value"].getStr() == "hello"
    check response["content"][0]["text"].getStr().contains("hello")
    check not response["isError"].getBool()
    check client.callTool("fail")["isError"].getBool()

  test "HTTP authentication errors propagate":
    let client = fixtureClient("/denied")
    defer: client.close()
    expect CatchableError:
      client.initialize()

  test "notification errors propagate":
    let client = fixtureClient("/notification-error")
    defer: client.close()
    expect CatchableError:
      client.initialize()
    check not client.client.initialized

  test "mismatched response IDs fail":
    let client = fixtureClient("/badid")
    defer: client.close()
    expect CatchableError:
      client.initialize()

  test "RPC errors and timeouts propagate without replay":
    let client = fixtureClient()
    defer: client.close()
    client.initialize()
    expect CatchableError:
      discard client.callTool("rpc-error")
    expect CatchableError:
      discard client.callTool("slow")

stopHttpFixture(fixture.process)
