import
  std/[json, options, os, unittest],
  mcport,
  mcport/mcp_http_metadata

proc modernRequest(id: JsonNode, methodName: string, params = %*{}): string =
  let body = params.copy()
  body["_meta"] = %*{}
  body["_meta"][ProtocolVersionKey] = %ModernProtocolVersion
  body["_meta"][ClientInfoKey] = %*{"name": "tests", "version": "1"}
  body["_meta"][ClientCapabilitiesKey] = %*{}
  $(%*{"jsonrpc": "2.0", "id": id, "method": methodName, "params": body})

suite "Modern notifications and events":
  test "opt in, discovery and isolated metadata":
    let server = newMcpServer("test", "1")
    check server.handleRequest(modernRequest(%1, "server/discover")).isError
    server.enableModernProtocol()
    server.initialized = false
    let discovery = server.handleRequest(modernRequest(%1, "server/discover"))
    check not discovery.isError
    check discovery.response.result["supportedVersions"][1].getStr() == ModernProtocolVersion
    check not server.handleRequest(modernRequest(%2, "tools/list")).isError
    check server.handleRequest(modernRequest(%3, "initialize")).error.error.code == -32601

  test "subscriptions acknowledge and filter by connection and request ID":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol()
    var first, second: seq[JsonNode]
    let
      contextA = RequestContext(connectionId: "a", transport: LocalTransport,
        send: proc(node: JsonNode) {.gcsafe.} =
          {.cast(gcsafe).}: first.add(node))
      contextB = RequestContext(connectionId: "b", transport: LocalTransport,
        send: proc(node: JsonNode) {.gcsafe.} =
          {.cast(gcsafe).}: second.add(node))
    check server.handleRequest(modernRequest(%"same", "subscriptions/listen",
      %*{"notifications": {"toolsListChanged": true}}), contextA).deferred
    check server.handleRequest(modernRequest(%"same", "subscriptions/listen",
      %*{"notifications": {"resourceSubscriptions": ["test://one"]}}), contextB).deferred
    check first[0]["method"].getStr() == "notifications/subscriptions/acknowledged"
    server.notifyToolsListChanged()
    server.notifyResourceUpdated("test://one")
    server.notifyResourceUpdated("test://two")
    check first.len == 2
    check second.len == 2
    check second[1]["params"]["_meta"][SubscriptionIdKey] == %"same"
    discard server.handleRequest($(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
      "params": {"requestId": "same"}}), contextA)
    server.notifyToolsListChanged()
    check first.len == 2
    server.closeSubscriptions(graceful = true)
    check second[^1]["id"] == %"same"

  test "emit history bootstraps, paginates, filters and truncates":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol(experimentalEvents = true, historyMaxEvents = 2)
    server.registerEvent(EventDefinition(name: "message", inputSchema: %*{}, payloadSchema: %*{}))
    let boot = server.handleRequest(modernRequest(%1, "events/poll", %*{"name": "message"})).response.result
    check boot["events"].len == 0
    for i in 1..3:
      server.emitEvent(EventOccurrence(name: "message", eventId: $i, data: %*{"value": i}))
    let batch = server.handleRequest(modernRequest(%2, "events/poll",
      %*{"name": "message", "cursor": boot["cursor"], "maxEvents": 1})).response.result
    check batch["truncated"].getBool()
    check batch["hasMore"].getBool()
    check batch["events"][0]["eventId"].getStr() == "2"
    let next = server.handleRequest(modernRequest(%3, "events/poll",
      %*{"name": "message", "cursor": batch["cursor"]})).response.result
    check next["events"][0]["eventId"].getStr() == "3"
    check not next["hasMore"].getBool()
    let http = RequestContext(transport: HttpTransport)
    let listing = server.handleRequest(modernRequest(%4, "events/list"), http).response.result
    check listing["events"][0]["delivery"] == %*["poll"]
    check server.handleRequest(modernRequest(%5, "events/stream", %*{"name": "message"}), http).error.error.code == -32601

  test "bounded client queues and graceful completion":
    let inbox = newClientInbox(1)
    var cancellations = 0
    let subscription = inbox.registerSubscription(%1, proc(id: JsonNode) = inc cancellations)
    discard inbox.route(%*{"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
      "params": {"_meta": {SubscriptionIdKey: 1}}})
    check subscription.receive(0).kind == SubscriptionMessage
    check subscription.receive(0).kind == SubscriptionTimeout
    discard inbox.route(%*{"jsonrpc": "2.0", "id": 1, "result": {}})
    check subscription.receive(0).kind == SubscriptionClosed
    subscription.close()

  test "check handlers and authorization errors":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol(experimentalEvents = true)
    server.registerEvent(EventDefinition(name: "checked", inputSchema: %*{}, payloadSchema: %*{}),
      check = proc(context: RequestContext, request: EventPollRequest): EventBatch =
        EventBatch(cursor: some("upstream"), nextPollMs: 3),
      authorize = proc(context: RequestContext, arguments: JsonNode) =
        if arguments{"allowed"}.getBool() == false:
          raise eventError(-32024, "Forbidden"))
    check server.handleRequest(modernRequest(%1, "events/poll", %*{"name": "checked"})).error.error.code == -32024
    let response = server.handleRequest(modernRequest(%2, "events/poll", %*{"name": "checked", "arguments": {"allowed": true}}))
    check response.response.result["cursor"].getStr() == "upstream"
    check response.response.result["nextPollMs"].getInt() == DefaultPollMs

  test "invalid metadata and event envelopes return protocol errors":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol(experimentalEvents = true)
    for params in [%*{}, %*{"name": 3}, %*{"name": "missing", "maxEvents": -1}, %*{"name": "missing", "cursor": 2}]:
      check server.handleRequest(modernRequest(%1, "events/poll", params)).isError
    let body = parseJson(modernRequest(%2, "tools/list"))
    body["params"]["_meta"].delete(ClientInfoKey)
    check server.handleRequest($body).error.error.code == -32600
    body["params"]["_meta"][ProtocolVersionKey] = %"unknown"
    check server.handleRequest($body).error.error.code == -32022
    check server.handleRequest("[]").error.error.code == -32600

  test "overflow cancels once and connection errors retain their cause":
    let inbox = newClientInbox(1)
    var count = 0
    let subscription = inbox.registerSubscription(%1, proc(id: JsonNode) = inc count)
    let message = %*{"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
      "params": {"_meta": {SubscriptionIdKey: 1}}}
    discard inbox.route(message)
    discard inbox.route(message)
    check count == 1
    expect SubscriptionLostError:
      discard subscription.receive(0)
    subscription.close()
    subscription.close()
    let other = inbox.registerSubscription(%2, proc(id: JsonNode) = inc count)
    inbox.disconnect("specific failure")
    inbox.disconnect()
    try:
      discard other.receive(0)
      check false
    except SubscriptionLostError as error:
      check error.msg == "specific failure"
    other.close()

  test "HTTP metadata safely mirrors names and parameters":
    let client = newMcpClient("tests", "1", modernProtocol = true)
    let req = client.createRequest("tools/list", %*{"_meta": {"custom": "retained"}})
    check req.params["_meta"]["custom"].getStr() == "retained"
    let schema = %*{"type": "object", "properties": {
      "location": {"type": "string", "x-mcp-header": "Location"}}}
    let headers = parameterHeaders(schema, %*{"location": " café\n"})
    check headers.len == 1
    check decodeHeaderValue(headers[0][1]) == " café\n"
    check decodeHeaderValue(encodeHeaderValue("=?base64?literal?=")) == "=?base64?literal?="
    expect ValueError:
      discard parameterHeaders(%*{"oneOf": [{"properties": {
        "hidden": {"type": "string", "x-mcp-header": "Hidden"}}}]}, nil)

  test "short replay windows do not erase another client's history":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol(experimentalEvents = true)
    server.registerEvent(EventDefinition(name: "namespace:event", inputSchema: %*{}, payloadSchema: %*{}))
    let start = server.handleRequest(modernRequest(%1, "events/poll", %*{"name": "namespace:event"})).response.result["cursor"]
    server.emitEvent(EventOccurrence(name: "namespace:event", data: %*{"value": 1}))
    sleep(10)
    let recent = server.handleRequest(modernRequest(%2, "events/poll", %*{"name": "namespace:event", "cursor": start, "maxAgeMs": 1})).response.result
    check recent["truncated"].getBool()
    check recent["events"].len == 0
    let history = server.handleRequest(modernRequest(%3, "events/poll", %*{"name": "namespace:event", "cursor": start})).response.result
    check history["events"].len == 1

  test "malformed JSON returns a parse error":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol()
    check server.handleRequest("{").error.error.code == -32700

  test "non-advancing check batches fail rather than looping":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol(experimentalEvents = true)
    server.registerEvent(EventDefinition(name: "invalid", inputSchema: %*{}, payloadSchema: %*{}),
      check = proc(context: RequestContext, request: EventPollRequest): EventBatch =
        EventBatch(cursor: request.cursor, hasMore: true))
    check server.handleRequest(modernRequest(%1, "events/poll", %*{"name": "invalid"})).error.error.code == -32603

  test "HTTP discovery does not advertise push notifications":
    let server = newMcpServer("test", "1")
    server.enableModernProtocol(experimentalEvents = true)
    let discovery = server.handleRequest(modernRequest(%1, "server/discover"), RequestContext(transport: HttpTransport)).response.result
    check not discovery["capabilities"]["tools"]["listChanged"].getBool()
    check not discovery["capabilities"]["resources"]["subscribe"].getBool()
    check discovery["capabilities"]["events"]["listChanged"] == %false
