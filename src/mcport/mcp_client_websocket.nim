import
  std/[algorithm, deques, httpcore, json, locks, options, os, sets, times],
  jsony, whisky,
  ./[mcp_core, mcp_client_core, mcp_client_runtime]

export mcp_client_runtime

type
  WebSocketMcpClient* = ref object
    client*: McpClient
    url*: string
    requestHeaders*: seq[(string, string)]
    maxMessageBytes: int
    inbox: ClientInbox
    gate: Lock
    outgoing: Deque[string]
    worker: Thread[pointer]
    running, connected, stopping: bool
    failure: string

const
  SocketReadTimeoutMs = 20
  ConnectTimeoutMs = 60_000

proc socketWorker(data: pointer) {.thread.} =
  {.cast(gcsafe).}:
    let client {.cursor.} = cast[WebSocketMcpClient](data)
    var socket: whisky.WebSocket
    try:
      let headers = newHttpHeaders()
      for (key, value) in client.requestHeaders:
        headers[key] = value
      socket = newWebSocket(client.url, headers = headers, timeout = ConnectTimeoutMs,
        maxMessageBytes = client.maxMessageBytes)
      withLock client.gate:
        client.connected = true
      while true:
        var messages: seq[string]
        withLock client.gate:
          if client.stopping:
            break
          while client.outgoing.len > 0:
            messages.add(client.outgoing.popFirst())
        for message in messages:
          socket.send(message)
        let incoming = socket.receiveMessage(SocketReadTimeoutMs)
        if incoming.isSome:
          case incoming.get.kind
          of whisky.Ping:
            socket.send(incoming.get.data, whisky.Pong)
          of whisky.Pong:
            discard
          of whisky.TextMessage:
            let message = parseJson(incoming.get.data)
            if not client.inbox.route(message):
              client.inbox.bufferNotification(message)
          of whisky.BinaryMessage:
            raise newException(IOError, "MCP requires WebSocket text messages")
    except CatchableError as error:
      client.inbox.disconnect(error.msg)
      withLock client.gate:
        client.failure = error.msg
    finally:
      if socket != nil:
        socket.close()
      withLock client.gate:
        client.connected = false
      client.inbox.disconnect()

proc newWebSocketMcpClient*(name, version, url: string,
    requestHeaders: seq[(string, string)] = @[],
    queueCapacity = DefaultSubscriptionQueueCapacity,
    maxMessageBytes = 0): WebSocketMcpClient =
  if maxMessageBytes < 0:
    raise newException(ValueError, "maxMessageBytes must be nonnegative")
  result = WebSocketMcpClient(client: newMcpClient(name, version, modernProtocol = true),
    url: url, requestHeaders: requestHeaders, maxMessageBytes: maxMessageBytes,
    inbox: newClientInbox(queueCapacity))
  initLock(result.gate)

proc isConnected*(client: WebSocketMcpClient): bool =
  withLock client.gate:
    result = client.connected

proc connect*(client: WebSocketMcpClient) =
  withLock client.gate:
    if client.running:
      raise newException(ValueError, "Client already started; construct a new client to reconnect")
    client.running = true
    createThread(client.worker, socketWorker, cast[pointer](client))
  let deadline = epochTime() + ConnectTimeoutMs.float / 1000
  while not client.isConnected:
    withLock client.gate:
      if client.failure.len > 0:
        raise newException(IOError, client.failure)
    if epochTime() > deadline:
      raise newException(IOError, "WebSocket connection timed out")
    sleep(SocketReadTimeoutMs)

proc sendMessage(client: WebSocketMcpClient, message: string) =
  withLock client.gate:
    if not client.connected or client.stopping:
      raise newException(IOError, "WebSocket is disconnected")
    client.outgoing.addLast(message)

proc request*(client: WebSocketMcpClient, methodName: string, params: JsonNode = %*{}): JsonNode =
  let req = client.client.createRequest(methodName, params)
  client.sendMessage(req.toJson())
  let response = client.inbox.waitResponse(%req.id)
  client.inbox.dispatchNotifications(client.client.notificationCallback)
  if response.hasKey("error"):
    raise newException(IOError, response{"error", "message"}.getStr())
  response["result"]

proc initialize*(client: WebSocketMcpClient) =
  let body = client.request("server/discover")
  client.client.handleDiscoveryResponse(ClientResult(isError: false,
    response: createResponse(0, body)))

proc openSubscription*(client: WebSocketMcpClient, methodName: string, params: JsonNode): Subscription =
  let req = client.client.createRequest(methodName, params)
  result = client.inbox.registerSubscription(%req.id, proc(id: JsonNode) =
    client.sendMessage($(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
      "params": {"requestId": id}})))
  client.sendMessage(req.toJson())
  try:
    result.waitAcknowledged()
  except CatchableError:
    result.close()
    raise

proc close*(client: WebSocketMcpClient) =
  var join = false
  withLock client.gate:
    if client.running:
      client.stopping = true
      join = true
      client.running = false
  if join:
    joinThread(client.worker)
  client.inbox.closeInbox()
  client.client.initialized = false

proc connectAndInitialize*(client: WebSocketMcpClient) =
  try:
    client.connect()
    client.initialize()
  except CatchableError:
    client.close()
    raise

proc callTool*(client: WebSocketMcpClient, name: string, arguments: JsonNode = %*{}): JsonNode =
  client.request("tools/call", %*{"name": name, "arguments": arguments})

proc listTools*(client: WebSocketMcpClient): JsonNode =
  client.request("tools/list")

proc listResources*(client: WebSocketMcpClient): JsonNode =
  client.request("resources/list")

proc readResource*(client: WebSocketMcpClient, uri: string): JsonNode =
  client.request("resources/read", %*{"uri": uri})

proc listPrompts*(client: WebSocketMcpClient): JsonNode =
  client.request("prompts/list")

proc getPrompt*(client: WebSocketMcpClient, name: string, arguments: JsonNode = %*{}): JsonNode =
  client.request("prompts/get", %*{"name": name, "arguments": arguments})

proc getAvailableTools*(client: WebSocketMcpClient): seq[string] =
  var
    cursor = ""
    cursors = initHashSet[string]()
  while true:
    let page = client.request("tools/list", if cursor.len > 0: %*{"cursor": cursor} else: %*{})
    for definition in page["tools"]:
      result.add(definition["name"].getStr())
    let nextCursor = page{"nextCursor"}.getStr()
    if nextCursor.len == 0:
      break
    if nextCursor in cursors:
      raise newException(IOError, "Repeated MCP tools/list cursor")
    cursors.incl(nextCursor)
    cursor = nextCursor
  result.sort()
