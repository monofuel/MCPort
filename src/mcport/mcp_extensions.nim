import
  std/[algorithm, deques, json, locks, options, os, strutils, sysrand, tables, times],
  jsony,
  ./mcp_core

type
  SubscriptionFilter* = object
    toolsListChanged*, promptsListChanged*, resourcesListChanged*: bool
    resourceSubscriptions*: seq[string]

  EventDefinition* = object
    name*, description*: string
    inputSchema*, payloadSchema*: JsonNode

  EventOccurrence* = object
    eventId*, name*, timestamp*: string
    data*: JsonNode
    cursor*: Option[string]

  EventPollRequest* = object
    name*: string
    arguments*: JsonNode
    cursor*: Option[string]
    maxAgeMs*, maxEvents*: int

  EventBatch* = object
    events*: seq[EventOccurrence]
    cursor*: Option[string]
    truncated*, hasMore*: bool
    nextPollMs*: int

  EventCheckHandler* = proc(context: RequestContext, request: EventPollRequest): EventBatch {.gcsafe.}
  EventMatchHandler* = proc(context: RequestContext, event: EventOccurrence, arguments: JsonNode): bool {.gcsafe.}
  EventTransformHandler* = proc(context: RequestContext, event: EventOccurrence, arguments: JsonNode): EventOccurrence {.gcsafe.}
  EventAuthorizeHandler* = proc(context: RequestContext, arguments: JsonNode) {.gcsafe.}

  EventProtocolError* = object of CatchableError
    code*: int

  EventSource = ref object
    definition: EventDefinition
    check: EventCheckHandler
    matches: EventMatchHandler
    transform: EventTransformHandler
    authorize: EventAuthorizeHandler
    history: Deque[tuple[position: int, created: float, event: EventOccurrence]]
    position: int

  ServerSubscription {.acyclic.} = ref object
    id: JsonNode
    context: RequestContext
    filter: SubscriptionFilter
    request: EventPollRequest
    eventSource {.cursor.}: EventSource
    active: bool
    gate: Lock
    worker: Thread[pointer]
    workerStarted: bool
    owner {.cursor.}: ExtensionState

  ExtensionState = ref object of RootObj
    server {.cursor.}: McpServer
    gate: Lock
    dispatchGate: Lock
    heartbeatWorker: Thread[pointer]
    heartbeatStarted, heartbeatStopped: bool
    events: Table[string, EventSource]
    subscriptions: Table[string, ServerSubscription]
    epoch: string
    started, experimentalEvents, stopping: bool
    historyMaxAgeMs, historyMaxEvents, heartbeatMs: int

const
  ModernProtocolVersion* = "2026-07-28"
  ProtocolVersionKey* = "io.modelcontextprotocol/protocolVersion"
  ClientInfoKey* = "io.modelcontextprotocol/clientInfo"
  ClientCapabilitiesKey* = "io.modelcontextprotocol/clientCapabilities"
  SubscriptionIdKey* = "io.modelcontextprotocol/subscriptionId"
  DefaultHistoryMaxAgeMs* = 600_000
  DefaultHistoryMaxEvents* = 10_000
  DefaultHeartbeatMs* = 30_000
  DefaultPollMs* = 1_000
  DefaultMaxEvents* = 100
  WorkerSleepMs = 20
  EventPageSize = 100

proc eventError*(code: int, message: string): ref EventProtocolError =
  result = newException(EventProtocolError, message)
  result.code = code

proc newIdentifier(): string =
  for value in urandom(16):
    result.add(value.int.toHex(2))

proc state(server: McpServer): ExtensionState =
  if server.extensionState == nil:
    raise newException(ValueError, "Modern protocol is not enabled")
  ExtensionState(server.extensionState)

proc subscriptionKey(context: RequestContext, id: JsonNode): string =
  $(%*[context.connectionId, id])

proc hasKind(node: JsonNode, kind: JsonNodeKind): bool =
  node != nil and node.kind == kind

proc toJsonNode(filter: SubscriptionFilter): JsonNode =
  result = %*{}
  if filter.toolsListChanged:
    result["toolsListChanged"] = %true
  if filter.promptsListChanged:
    result["promptsListChanged"] = %true
  if filter.resourcesListChanged:
    result["resourcesListChanged"] = %true
  if filter.resourceSubscriptions.len > 0:
    result["resourceSubscriptions"] = %filter.resourceSubscriptions

proc toJsonNode*(event: EventOccurrence): JsonNode =
  result = %*{"eventId": event.eventId, "name": event.name,
    "timestamp": event.timestamp, "data": event.data.copy()}
  result["cursor"] = if event.cursor.isSome: %event.cursor.get else: newJNull()

proc toJsonNode*(batch: EventBatch): JsonNode =
  result = %*{"events": [], "truncated": batch.truncated,
    "hasMore": batch.hasMore, "nextPollMs": batch.nextPollMs}
  result["cursor"] = if batch.cursor.isSome: %batch.cursor.get else: newJNull()
  for event in batch.events:
    result["events"].add(event.toJsonNode())

proc parseEventBatch*(node: JsonNode): EventBatch =
  result = ($node).fromJson(EventBatch)

proc sendNotificationUnlocked(subscription: ServerSubscription, methodName: string, params: JsonNode) =
  if not subscription.active:
    return
  let payload = params.copy()
  if not payload.hasKey("_meta"):
    payload["_meta"] = %*{}
  payload["_meta"][SubscriptionIdKey] = subscription.id.copy()
  subscription.context.sendContextMessage(%*{"jsonrpc": "2.0", "method": methodName, "params": payload})

proc sendNotification(subscription: ServerSubscription, methodName: string, params: JsonNode) =
  withLock subscription.gate:
    subscription.sendNotificationUnlocked(methodName, params)

proc isActive(subscription: ServerSubscription): bool =
  withLock subscription.gate:
    result = subscription.active

proc terminate(subscription: ServerSubscription, code: int, message: string) =
  subscription.sendNotification("notifications/events/terminated",
    %*{"error": {"code": code, "message": message}})
  withLock subscription.gate:
    subscription.active = false

proc sourceFor(runtime: ExtensionState, name: string): lent EventSource =
  withLock runtime.gate:
    if name notin runtime.events:
      raise eventError(-32023, "Unknown event: " & name)
    result = runtime.events[name]

proc validateOccurrence(event: EventOccurrence, name: string) =
  if event.name != name or event.eventId.len == 0 or event.timestamp.len == 0 or
      event.data == nil or event.data.kind != JObject:
    raise eventError(-32603, "Event handler returned an invalid occurrence")

proc poll(runtime: ExtensionState, context: RequestContext, request: EventPollRequest): EventBatch =
  let source {.cursor.} = runtime.sourceFor(request.name)
  if source.authorize != nil:
    source.authorize(context, request.arguments)
  if source.check != nil:
    result = source.check(context, request)
    result.nextPollMs = max(DefaultPollMs, result.nextPollMs)
    if result.events.len > request.maxEvents:
      raise eventError(-32603, "Event handler exceeded maxEvents")
    if result.hasMore and result.cursor == request.cursor:
      raise eventError(-32603, "Event handler did not advance its cursor")
    for event in result.events:
      event.validateOccurrence(request.name)
    return
  var
    pending: seq[tuple[position: int, event: EventOccurrence]]
    position: int
    currentPosition: int
  withLock runtime.gate:
    currentPosition = source.position
    let floor = epochTime() - runtime.historyMaxAgeMs.float / 1000
    while source.history.len > 0 and source.history.peekFirst.created < floor:
      discard source.history.popFirst()
    if request.cursor.isNone:
      position = source.position
    else:
      let prefix = runtime.epoch & ":" & request.name & ":"
      if not request.cursor.get.startsWith(prefix):
        result.truncated = true
        position = if source.history.len > 0: source.history.peekFirst.position - 1 else: source.position
      else:
        try:
          position = parseInt(request.cursor.get[prefix.len .. ^1])
        except ValueError:
          raise eventError(-32602, "Invalid event cursor")
        if position < 0 or position > source.position:
          raise eventError(-32602, "Invalid event cursor position")
        if source.history.len > 0 and position < source.history.peekFirst.position - 1:
          result.truncated = true
          position = source.history.peekFirst.position - 1
        elif source.history.len == 0 and position < source.position:
          result.truncated = true
          position = source.position
    for entry in source.history.items:
      if entry.position > position:
        if entry.created < epochTime() - request.maxAgeMs.float / 1000:
          result.truncated = true
          position = entry.position
        else:
          var occurrence = entry.event
          occurrence.data = entry.event.data.copy()
          pending.add((entry.position, move(occurrence)))
  for entry in pending:
    position = entry.position
    if source.matches == nil or source.matches(context, entry.event, request.arguments):
      let event = if source.transform != nil: source.transform(context, entry.event, request.arguments) else: entry.event
      event.validateOccurrence(request.name)
      result.events.add(event)
      if result.events.len == request.maxEvents:
        break
  result.hasMore = position < currentPosition
  result.cursor = some(runtime.epoch & ":" & request.name & ":" & $position)
  result.nextPollMs = DefaultPollMs

proc pumpEvents(subscription: ServerSubscription): int =
  withLock subscription.gate:
    while subscription.active:
      let batch = subscription.owner.poll(subscription.context, subscription.request)
      if batch.truncated:
        subscription.sendNotificationUnlocked("notifications/events/active",
          %*{"cursor": batch.toJsonNode()["cursor"], "truncated": true})
      for event in batch.events:
        subscription.sendNotificationUnlocked("notifications/events/event", event.toJsonNode())
      subscription.request.cursor = batch.cursor
      result = if batch.hasMore: 0 else: batch.nextPollMs
      if subscription.eventSource.check != nil or not batch.hasMore:
        break

proc eventWorker(data: pointer) {.thread.} =
  {.cast(gcsafe).}:
    let
      subscription {.cursor.} = cast[ServerSubscription](data)
      runtime {.cursor.} = subscription.owner
    var
      nextCheck = epochTime()
      nextHeartbeat = epochTime() + runtime.heartbeatMs.float / 1000
    while subscription.isActive:
      let now = epochTime()
      try:
        if now >= nextCheck:
          nextCheck = now + subscription.pumpEvents().float / 1000
        if subscription.eventSource.check != nil and now >= nextHeartbeat:
          withLock subscription.gate:
            let cursor = if subscription.request.cursor.isSome: %subscription.request.cursor.get else: newJNull()
            subscription.sendNotificationUnlocked("notifications/events/heartbeat", %*{"cursor": cursor})
          nextHeartbeat = now + runtime.heartbeatMs.float / 1000
      except EventProtocolError as error:
        subscription.terminate(error.code, error.msg)
      except CatchableError as error:
        subscription.sendNotification("notifications/events/error",
          %*{"error": {"code": -32603, "message": error.msg}})
        nextCheck = now + DefaultPollMs.float / 1000
      sleep(WorkerSleepMs)

proc heartbeatWorker(data: pointer) {.thread.} =
  {.cast(gcsafe).}:
    let runtime {.cursor.} = cast[ExtensionState](data)
    var nextHeartbeat = epochTime() + runtime.heartbeatMs.float / 1000
    while true:
      withLock runtime.dispatchGate:
        var subscriptions: seq[pointer]
        withLock runtime.gate:
          if runtime.heartbeatStopped:
            break
          if epochTime() >= nextHeartbeat:
            for subscription in runtime.subscriptions.values:
              if subscription.eventSource != nil and subscription.eventSource.check == nil:
                subscriptions.add(cast[pointer](subscription))
        for data in subscriptions:
          let subscription {.cursor.} = cast[ServerSubscription](data)
          withLock subscription.gate:
            let cursor = if subscription.request.cursor.isSome: %subscription.request.cursor.get else: newJNull()
            subscription.sendNotificationUnlocked("notifications/events/heartbeat", %*{"cursor": cursor})
        if subscriptions.len > 0:
          nextHeartbeat = epochTime() + runtime.heartbeatMs.float / 1000
      sleep(WorkerSleepMs)

proc stopSubscription(runtime: ExtensionState, key: string, graceful = false) =
  var subscription: ServerSubscription
  withLock runtime.dispatchGate:
    withLock runtime.gate:
      if key notin runtime.subscriptions:
        return
      subscription = runtime.subscriptions[key]
      runtime.subscriptions.del(key)
    withLock subscription.gate:
      if graceful and subscription.active:
        let meta = %*{}
        if subscription.eventSource == nil:
          meta[SubscriptionIdKey] = subscription.id.copy()
        subscription.context.sendContextMessage(%*{"jsonrpc": "2.0", "id": subscription.id.copy(),
          "result": {"_meta": meta}})
      subscription.active = false
  if subscription.workerStarted:
    joinThread(subscription.worker)

proc closeSubscriptions*(server: McpServer, connectionId = "", graceful = false) =
  if server.extensionState == nil:
    return
  let runtime {.cursor.} = server.state
  var keys: seq[string]
  withLock runtime.gate:
    if connectionId.len == 0:
      runtime.stopping = true
      runtime.heartbeatStopped = true
    for key, subscription in runtime.subscriptions:
      if connectionId.len == 0 or subscription.context.connectionId == connectionId:
        keys.add(key)
  for key in keys:
    runtime.stopSubscription(key, graceful)
  if connectionId.len == 0 and runtime.heartbeatStarted:
    joinThread(runtime.heartbeatWorker)
    runtime.heartbeatStarted = false

proc dispatchNotification(runtime: ExtensionState, notification: JsonNode) =
  acquire(runtime.dispatchGate)
  defer: release(runtime.dispatchGate)
  let methodName = notification{"method"}.getStr()
  var subscribers: seq[pointer]
  withLock runtime.gate:
    for subscription in runtime.subscriptions.values:
      if subscription.eventSource != nil:
        continue
      let filter = subscription.filter
      if (methodName == "notifications/tools/list_changed" and filter.toolsListChanged) or
          (methodName == "notifications/prompts/list_changed" and filter.promptsListChanged) or
          (methodName == "notifications/resources/list_changed" and filter.resourcesListChanged) or
          (methodName == "notifications/resources/updated" and notification{"params", "uri"}.getStr() in filter.resourceSubscriptions):
        subscribers.add(cast[pointer](subscription))
  for data in subscribers:
    let subscription {.cursor.} = cast[ServerSubscription](data)
    subscription.sendNotification(methodName,
      if notification.hasKey("params"): notification["params"] else: %*{})

proc capabilities(runtime: ExtensionState, transport: McpTransport): JsonNode =
  let server {.cursor.} = runtime.server
  let push = transport != HttpTransport
  result = %*{"tools": {"listChanged": push and server.capabilities.tools.listChanged and not server.toolsOnly}}
  if not server.toolsOnly:
    result["prompts"] = %*{"listChanged": push and server.capabilities.prompts.listChanged}
    result["resources"] = %*{"listChanged": push and server.capabilities.resources.listChanged,
      "subscribe": push and server.capabilities.resources.subscribe}
  if runtime.experimentalEvents:
    result["events"] = %*{"listChanged": false}

proc parsePollRequest(params: JsonNode): EventPollRequest =
  if not params.hasKind(JObject) or not params{"name"}.hasKind(JString):
    raise eventError(-32602, "Event name is required")
  result = EventPollRequest(name: params["name"].getStr(), arguments: %*{},
    maxAgeMs: DefaultHistoryMaxAgeMs, maxEvents: DefaultMaxEvents)
  if params.hasKey("arguments"):
    if params["arguments"].kind != JObject:
      raise eventError(-32602, "Event arguments must be an object")
    result.arguments = params["arguments"].copy()
  if params.hasKey("cursor") and params["cursor"].kind != JNull:
    if params["cursor"].kind != JString:
      raise eventError(-32602, "Event cursor must be a string or null")
    result.cursor = some(params["cursor"].getStr())
  for key in ["maxAgeMs", "maxEvents"]:
    if params.hasKey(key) and (params[key].kind != JInt or params[key].getInt() <= 0):
      raise eventError(-32602, key & " must be a positive integer")
  if params.hasKey("maxAgeMs"):
    result.maxAgeMs = params["maxAgeMs"].getInt()
  if params.hasKey("maxEvents"):
    result.maxEvents = params["maxEvents"].getInt()

proc intercept(runtime: ExtensionState, message: JsonNode, context: RequestContext): Option[McpResult] =
  let
    id = message{"id"}
    methodName = message{"method"}.getStr()
    params = if message.hasKey("params"): message["params"] else: %*{}
    meta = params{"_meta"}
    version = meta{ProtocolVersionKey}.getStr()
  if methodName == "notifications/cancelled":
    if message{"jsonrpc"}.getStr() != "2.0" or message.hasKey("id"):
      return some(McpResult(isError: true, error: createError(id, -32600, "Invalid cancellation notification")))
    if params{"requestId"} != nil:
      runtime.stopSubscription(subscriptionKey(context, params["requestId"]))
    return some(McpResult(deferred: true))
  if methodName != "server/discover" and version.len == 0:
    if methodName.startsWith("events/") or methodName == "subscriptions/listen":
      return some(McpResult(isError: true, error: createError(id, -32600, "Modern request metadata is required")))
    return none(McpResult)
  if message{"jsonrpc"}.getStr() != "2.0" or id == nil or id.kind notin {JInt, JString}:
    return some(McpResult(isError: true, error: createError(newJNull(), -32600, "Invalid JSON-RPC request")))
  try:
    if methodName != "server/discover":
      if version != ModernProtocolVersion:
        return some(McpResult(isError: true, error: createError(id, -32022, "Unsupported protocol version",
          some(%*{"supported": [MCP_VERSION, ModernProtocolVersion], "requested": version}))))
      if not meta{ClientInfoKey}.hasKind(JObject) or not meta{ClientInfoKey, "name"}.hasKind(JString) or
          not meta{ClientInfoKey, "version"}.hasKind(JString) or not meta{ClientCapabilitiesKey}.hasKind(JObject):
        raise eventError(-32600, "Client information and capabilities are required")
    var requestContext = context
    requestContext.metadata = meta
    case methodName
    of "server/discover":
      return some(McpResult(isError: false, response: createResponse(id, %*{
        "supportedVersions": [MCP_VERSION, ModernProtocolVersion],
        "capabilities": runtime.capabilities(context.transport), "serverInfo": runtime.server.serverInfo})))
    of "initialize", "resources/subscribe", "resources/unsubscribe", "ping", "logging/setLevel":
      raise eventError(-32601, "Method not found")
    of "events/list":
      if not runtime.experimentalEvents:
        raise eventError(-32601, "Method not found")
      var
        names: seq[string]
        start = 0
      withLock runtime.gate:
        runtime.started = true
        for name in runtime.events.keys:
          names.add(name)
      names.sort()
      if params.hasKey("cursor"):
        if params["cursor"].kind != JString:
          raise eventError(-32602, "Invalid list cursor")
        try:
          start = params["cursor"].getStr().parseInt()
        except ValueError:
          raise eventError(-32602, "Invalid list cursor")
      if start < 0 or start > names.len:
        raise eventError(-32602, "Invalid list cursor")
      let body = %*{"events": []}
      for i in start ..< min(names.len, start + EventPageSize):
        let definition {.cursor.} = runtime.sourceFor(names[i]).definition
        var descriptor = parseJson(definition.toJson())
        descriptor["delivery"] = if context.transport == HttpTransport: %*["poll"] else: %*["poll", "push"]
        body["events"].add(descriptor)
      if start + EventPageSize < names.len:
        body["nextCursor"] = % $(start + EventPageSize)
      return some(McpResult(isError: false, response: createResponse(id, body)))
    of "events/poll":
      if not runtime.experimentalEvents:
        raise eventError(-32601, "Method not found")
      let batch = runtime.poll(requestContext, parsePollRequest(params))
      return some(McpResult(isError: false, response: createResponse(id, batch.toJsonNode())))
    of "subscriptions/listen", "events/stream":
      acquire(runtime.dispatchGate)
      defer: release(runtime.dispatchGate)
      if runtime.stopping:
        raise eventError(-32603, "Server is shutting down")
      if context.transport notin {StdioTransport, WebSocketTransport, LocalTransport} or context.send == nil and context.sender == nil or context.connectionId.len == 0:
        raise eventError(-32601, "Push requires WebSocket or stdio")
      let subscription = ServerSubscription(id: id.copy(), context: RequestContext(
        transport: requestContext.transport, connectionId: requestContext.connectionId,
        auth: (if requestContext.auth == nil: nil else: requestContext.auth.copy()),
        metadata: (if requestContext.metadata == nil: nil else: requestContext.metadata.copy()),
        send: requestContext.send, sender: requestContext.sender, sendTarget: requestContext.sendTarget), active: true, owner: runtime)
      initLock(subscription.gate)
      let key = subscriptionKey(context, id)
      withLock runtime.gate:
        if key in runtime.subscriptions:
          raise eventError(-32600, "Duplicate subscription request ID")
      if methodName == "subscriptions/listen":
        let filter = params{"notifications"}
        if filter == nil or filter.kind != JObject:
          raise eventError(-32602, "Notification filter is required")
        for key in ["toolsListChanged", "promptsListChanged", "resourcesListChanged"]:
          if filter.hasKey(key) and filter[key].kind != JBool:
            raise eventError(-32602, "Notification filters must be boolean")
        if filter.hasKey("resourceSubscriptions"):
          if filter["resourceSubscriptions"].kind != JArray:
            raise eventError(-32602, "Resource subscriptions must be an array")
          for uri in filter["resourceSubscriptions"]:
            if uri.kind != JString:
              raise eventError(-32602, "Resource URIs must be strings")
        subscription.filter = ($filter).fromJson(SubscriptionFilter)
        subscription.filter.toolsListChanged = subscription.filter.toolsListChanged and runtime.server.capabilities.tools.listChanged
        subscription.filter.promptsListChanged = subscription.filter.promptsListChanged and runtime.server.capabilities.prompts.listChanged
        subscription.filter.resourcesListChanged = subscription.filter.resourcesListChanged and runtime.server.capabilities.resources.listChanged
        if not runtime.server.capabilities.resources.subscribe:
          subscription.filter.resourceSubscriptions = @[]
        if runtime.server.toolsOnly:
          subscription.filter = SubscriptionFilter()
      else:
        if not runtime.experimentalEvents:
          raise eventError(-32601, "Method not found")
        subscription.request = parsePollRequest(params)
        subscription.eventSource = runtime.sourceFor(subscription.request.name)
        let initial = runtime.poll(requestContext, subscription.request)
        subscription.request.cursor = initial.cursor
        subscription.sendNotification("notifications/events/active",
          %*{"cursor": initial.toJsonNode()["cursor"], "truncated": initial.truncated})
        for event in initial.events:
          subscription.sendNotification("notifications/events/event", event.toJsonNode())
      withLock runtime.gate:
        if key in runtime.subscriptions:
          raise eventError(-32600, "Duplicate subscription request ID")
        if subscription.eventSource == nil:
          subscription.sendNotification("notifications/subscriptions/acknowledged",
            %*{"notifications": subscription.filter.toJsonNode()})
        runtime.subscriptions[key] = subscription
        runtime.started = true
        if subscription.eventSource != nil:
          if subscription.eventSource.check != nil:
            createThread(subscription.worker, eventWorker, cast[pointer](subscription))
            subscription.workerStarted = true
          elif not runtime.heartbeatStarted:
            createThread(runtime.heartbeatWorker, heartbeatWorker, cast[pointer](runtime))
            runtime.heartbeatStarted = true
      if subscription.eventSource != nil and subscription.eventSource.check == nil:
        discard subscription.pumpEvents()
      return some(McpResult(deferred: true))
    else:
      return none(McpResult)
  except EventProtocolError as error:
    return some(McpResult(isError: true, error: createError(id, error.code, error.msg)))
  except CatchableError:
    return some(McpResult(isError: true, error: createError(id, -32603, "Internal error")))

proc enableModernProtocol*(server: McpServer, experimentalEvents = false,
    historyMaxAgeMs = DefaultHistoryMaxAgeMs, historyMaxEvents = DefaultHistoryMaxEvents,
    heartbeatMs = DefaultHeartbeatMs) =
  if server.extensionState != nil:
    raise newException(ValueError, "Modern protocol is already enabled")
  if min(historyMaxAgeMs, historyMaxEvents) <= 0 or heartbeatMs <= 0:
    raise newException(ValueError, "Event limits must be positive")
  let runtime = ExtensionState(server: server, epoch: newIdentifier(),
    experimentalEvents: experimentalEvents, historyMaxAgeMs: historyMaxAgeMs,
    historyMaxEvents: historyMaxEvents, heartbeatMs: heartbeatMs)
  initLock(runtime.gate)
  initLock(runtime.dispatchGate)
  server.extensionState = runtime
  if experimentalEvents:
    server.capabilities.events = some(EventCaps(listChanged: false))
  server.requestInterceptor = proc(message: JsonNode, context: RequestContext): Option[McpResult] =
    runtime.intercept(message, context)
  server.notificationSinks.add(proc(notification: JsonNode) = runtime.dispatchNotification(notification))

proc registerEvent*(server: McpServer, definition: EventDefinition,
    check: EventCheckHandler = nil, matches: EventMatchHandler = nil,
    transform: EventTransformHandler = nil, authorize: EventAuthorizeHandler = nil) =
  let runtime {.cursor.} = server.state
  if not runtime.experimentalEvents:
    raise newException(ValueError, "Experimental events are not enabled")
  if definition.name.len == 0 or
      definition.inputSchema == nil or definition.inputSchema.kind != JObject or
      definition.payloadSchema == nil or definition.payloadSchema.kind != JObject:
    raise newException(ValueError, "Event name and object schemas are required")
  withLock runtime.gate:
    if runtime.started or definition.name in runtime.events:
      raise newException(ValueError, "Event catalog is immutable after serving")
    var frozen = definition
    frozen.inputSchema = definition.inputSchema.copy()
    frozen.payloadSchema = definition.payloadSchema.copy()
    runtime.events[definition.name] = EventSource(definition: move(frozen), check: check,
      matches: matches, transform: transform, authorize: authorize)

proc freezeEvents*(server: McpServer) =
  if server.extensionState != nil:
    let runtime {.cursor.} = server.state
    withLock runtime.gate:
      runtime.started = true

proc emitEvent*(server: McpServer, event: EventOccurrence) =
  let
    runtime {.cursor.} = server.state
    source {.cursor.} = runtime.sourceFor(event.name)
  acquire(runtime.dispatchGate)
  defer: release(runtime.dispatchGate)
  if source.check != nil:
    raise newException(ValueError, "Direct emit requires an emit-only event source")
  if event.data == nil or event.data.kind != JObject:
    raise newException(ValueError, "Event data must be an object")
  var occurrence = event
  occurrence.data = event.data.copy()
  if occurrence.eventId.len == 0:
    occurrence.eventId = newIdentifier()
  if occurrence.timestamp.len == 0:
    occurrence.timestamp = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")
  var subscriptions: seq[pointer]
  withLock runtime.gate:
    inc source.position
    occurrence.cursor = some(runtime.epoch & ":" & event.name & ":" & $source.position)
    source.history.addLast((source.position, epochTime(), move(occurrence)))
    let floor = epochTime() - runtime.historyMaxAgeMs.float / 1000
    while source.history.len > runtime.historyMaxEvents or
        (source.history.len > 0 and source.history.peekFirst.created < floor):
      discard source.history.popFirst()
    for subscription in runtime.subscriptions.values:
      if subscription.eventSource == source:
        subscriptions.add(cast[pointer](subscription))
  for data in subscriptions:
    let subscription {.cursor.} = cast[ServerSubscription](data)
    try:
      discard subscription.pumpEvents()
    except EventProtocolError as error:
      subscription.terminate(error.code, error.msg)
