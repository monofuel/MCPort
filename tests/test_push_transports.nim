import
  std/[json, net, options, os, osproc, streams, tempfiles, unittest],
  mcport

let
  fixtureDirectory = createTempDir("mcport-events-", "")
  fixture = fixtureDirectory / "server"
  buildLog = fixtureDirectory / "build.log"
  compileCode = execCmd("nim c --out:" & quoteShell(fixture) & " tests/fixtures/events_server.nim > " & quoteShell(buildLog) & " 2>&1")
doAssert compileCode == 0, readFile(buildLog)

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = socket.getLocalAddr()[1].int
  socket.close()

proc exercise[T](client: T) =
  let
    notifications = client.listenNotifications(SubscriptionFilter(toolsListChanged: true))
    events = client.subscribeEvents(EventPollRequest(name: "message"))
  defer:
    events.close()
    notifications.close()
  doAssert notifications.receive(1000).message["method"].getStr() == "notifications/subscriptions/acknowledged"
  doAssert events.receive(1000).message["method"].getStr() == "notifications/events/active"
  discard client.callTool("publish", %*{"text": "hello"})
  doAssert notifications.receive(2000).message["method"].getStr() == "notifications/tools/list_changed"
  var found = false
  for i in 0..<30:
    let update = events.receive(200)
    if update.kind == SubscriptionMessage and update.message["method"].getStr() == "notifications/events/event":
      doAssert update.message["params"]["data"]["text"].getStr() == "hello"
      found = true
      break
  doAssert found
  doAssert client.listEvents()["events"][1]["name"].getStr() == "message"

suite "Blocking push transports":
  test "stdio receives continuously while requests run":
    let client = newStdioMcpClient("tests", "1", logEnabled = false, modernProtocol = true)
    client.connect(fixture)
    defer: client.close()
    client.initialize()
    exercise(client)

  test "WebSocket push and HTTP polling use upstream Mummy":
    let
      port = freePort()
      process = startProcess(fixture, args = @[$port])
    defer:
      if not process.running():
        stderr.writeLine(process.errorStream.readAll())
      else:
        process.terminate()
      discard process.waitForExit()
      process.close()
    sleep(300)
    let client = newWebSocketMcpClient("tests", "1", "ws://127.0.0.1:" & $port & "/mcp/ws",
      requestHeaders = @[("Authorization", "Bearer test")])
    defer: client.close()
    client.connectAndInitialize()
    exercise(client)
    for i in 0..<20:
      let temporary = client.subscribeEvents(EventPollRequest(name: "message"))
      check temporary.receive(1000).kind == SubscriptionMessage
      temporary.close()
    check client.pollEvents(EventPollRequest(name: "checked")).cursor == some("start")
    let http = newHttpMcpClient("tests", "1", "http://127.0.0.1:" & $port & "/mcp",
      logEnabled = false, requestHeaders = @[ ("Authorization", "Bearer test") ], modernProtocol = true)
    defer: http.close()
    http.connectAndInitialize()
    check http.listEvents()["events"][0]["delivery"] == %*["poll"]
    let bootstrap = http.pollEvents(EventPollRequest(name: "message"))
    discard http.callTool("publish", %*{"text": "poll"})
    let events = http.pollEvents(EventPollRequest(name: "message", cursor: bootstrap.cursor))
    check events.events.len == 1
    check events.events[0].data["text"].getStr() == "poll"
    let limited = newWebSocketMcpClient("tests", "1", "ws://127.0.0.1:" & $port & "/mcp/ws",
      requestHeaders = @[("Authorization", "Bearer test")], maxMessageBytes = 1)
    defer: limited.close()
    expect SubscriptionLostError:
      limited.connectAndInitialize()

  test "check streams heartbeat and end gracefully":
    let client = newStdioMcpClient("tests", "1", logEnabled = false, modernProtocol = true)
    client.connect(fixture)
    defer: client.close()
    client.initialize()
    let subscription = client.subscribeEvents(EventPollRequest(name: "checked"))
    defer: subscription.close()
    check subscription.receive(1000).message["method"].getStr() == "notifications/events/active"
    check subscription.receive(1500).message["params"]["eventId"].getStr() == "checked"
    check subscription.receive(1500).message["method"].getStr() == "notifications/events/heartbeat"
    discard client.callTool("shutdown")
    var ended = false
    for i in 0..<20:
      if subscription.receive(100).kind == SubscriptionClosed:
        ended = true
        break
    check ended

  test "overflow affects one subscription and does not stop ordinary requests":
    let client = newStdioMcpClient("tests", "1", logEnabled = false, modernProtocol = true, queueCapacity = 1)
    client.connect(fixture)
    defer: client.close()
    client.initialize()
    let subscription = client.listenNotifications(SubscriptionFilter(toolsListChanged: true))
    defer: subscription.close()
    discard client.callTool("publish", %*{"text": "overflow"})
    expect SubscriptionLostError:
      discard subscription.receive(100)
    check client.listEvents()["events"].len == 2

  test "authorization denial leaves the connection usable":
    let client = newStdioMcpClient("tests", "1", logEnabled = false, modernProtocol = true)
    client.connect(fixture)
    defer: client.close()
    client.initialize()
    expect SubscriptionLostError:
      discard client.subscribeEvents(EventPollRequest(name: "checked", arguments: %*{"deny": true}))
    check client.listEvents()["events"].len == 2

removeDir(fixtureDirectory)
