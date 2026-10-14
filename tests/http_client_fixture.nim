import
  std/[json, net, os, osproc, strutils, times],
  curly, mummy

const
  FixtureAccountId* = "0123456789abcdef0123456789abcdef"
  FixtureToken* = "fixture-token"

proc runHttpFixture*(port: int) =
  proc handle(request: Request) {.gcsafe.} =
    if request.httpMethod == "GET":
      request.respond(200, body = "ready")
      return
    if request.uri == "/denied":
      request.respond(401)
      return
    if request.headers["Authorization"] != "Bearer " & FixtureToken or
        not request.headers["Accept"].contains("application/json"):
      request.respond(400, body = "Missing required headers")
      return
    let
      message = parseJson(request.body)
      methodName = message["method"].getStr()
    if methodName != "initialize" and request.headers["MCP-Protocol-Version"] != "2025-06-18":
      request.respond(400, body = "Missing protocol header")
      return
    if methodName == "notifications/initialized":
      if message.hasKey("id") or request.uri == "/notification-error":
        request.respond(400)
      else:
        request.respond(202)
      return
    let id = if request.uri == "/badid": %9999 else: message["id"]
    var result = newJObject()
    case methodName
    of "initialize":
      result = %*{"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
    of "tools/list":
      let
        firstPage = message["params"]{"cursor"}.getStr().len == 0
        names = if firstPage: @["echo"] else: @["whoami", "fail", "create_post", "reply"]
      var definitions = newJArray()
      for name in names:
        definitions.add(%*{"name": name, "description": name, "inputSchema": {"type": "object", "properties": {"value": {"type": "string"}}}})
      result = %*{"tools": definitions}
      if firstPage:
        result["nextCursor"] = %"next"
    of "tools/call":
      let name = message["params"]["name"].getStr()
      if name == "rpc-error":
        request.respond(200, body = $(%*{"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "fixture error"}}))
        return
      if name == "slow":
        sleep(1500)
      let
        accountId = if request.uri == "/wrong-identity": "different" else: FixtureAccountId
        content = if name == "whoami": %*{"id": accountId, "name": "Racha Logomo", "role": "bot"}
          else: %*{"tool": name, "arguments": message["params"]["arguments"]}
      result = %*{"content": [{"type": "text", "text": $content}], "structuredContent": content, "isError": name == "fail"}
    else:
      request.respond(400)
      return
    request.respond(200, @[("Content-Type", "application/json")], $(%*{"jsonrpc": "2.0", "id": id, "result": result}))
  let server = newServer(handle)
  server.serve(Port(port), "127.0.0.1")

proc startHttpFixture*(): tuple[process: Process, url: string] =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  let port = socket.getLocalAddr()[1].int
  socket.close()
  result.process = startProcess(getAppFilename(), args = @["--fixture", $port], options = {poParentStreams})
  result.url = "http://127.0.0.1:" & $port
  let
    curl = newCurly()
    deadline = epochTime() + 5
  defer: curl.close()
  while true:
    try:
      if curl.get(result.url, timeout = 1).code == 200:
        break
    except CatchableError:
      if epochTime() >= deadline:
        result.process.terminate()
        discard result.process.waitForExit()
        result.process.close()
        raise
    sleep(10)

proc stopHttpFixture*(process: Process) =
  process.terminate()
  discard process.waitForExit()
  process.close()
