import
  std/[deques, json, locks, monotimes, options, os, tables, times],
  ./[mcp_core, mcp_extensions]

export mcp_extensions

type
  SubscriptionLostError* = object of CatchableError
  SubscriptionReadKind* = enum
    SubscriptionMessage, SubscriptionTimeout, SubscriptionClosed
  SubscriptionRead* = object
    kind*: SubscriptionReadKind
    message*: JsonNode
  ClientInbox* = ref object
    gate: Lock
    responses: Table[string, string]
    subscriptions: Table[string, Subscription]
    failure: string
    disconnected: bool
    queueCapacity: int
    notifications: Deque[string]
  Subscription* = ref object
    id*: JsonNode
    acknowledgedText: string
    inbox: ClientInbox
    queue: Deque[string]
    finished: bool
    failure: string
    cancelSent: bool
    cancel: proc(id: JsonNode) {.gcsafe.}

const
  DefaultSubscriptionQueueCapacity* = 256
  ReceiveSleepMs = 5
  DefaultRequestTimeoutMs* = 60_000

proc newClientInbox*(queueCapacity = DefaultSubscriptionQueueCapacity): ClientInbox =
  if queueCapacity <= 0:
    raise newException(ValueError, "Subscription queue capacity must be positive")
  result = ClientInbox(queueCapacity: queueCapacity)
  initLock(result.gate)

proc disconnect*(inbox: ClientInbox, failure = "Connection closed") =
  withLock inbox.gate:
    if inbox.disconnected:
      return
    inbox.disconnected = true
    inbox.failure = failure

proc registerSubscription*(inbox: ClientInbox, id: JsonNode,
    cancel: proc(id: JsonNode) {.gcsafe.}): Subscription =
  result = Subscription(id: id, inbox: inbox, cancel: cancel)
  withLock inbox.gate:
    if inbox.disconnected:
      raise newException(SubscriptionLostError, inbox.failure)
    if $id in inbox.subscriptions:
      raise newException(ValueError, "Duplicate subscription ID")
    inbox.subscriptions[$id] = result

proc route*(inbox: ClientInbox, message: JsonNode): bool =
  if message{"jsonrpc"}.getStr() != "2.0":
    raise newException(IOError, "Invalid JSON-RPC message")
  withLock inbox.gate:
    if message.hasKey("id"):
      if message["id"].kind notin {JInt, JString} or message.hasKey("result") == message.hasKey("error"):
        raise newException(IOError, "Invalid JSON-RPC response")
      let key = $message["id"]
      if key in inbox.subscriptions:
        let subscription {.cursor.} = inbox.subscriptions[key]
        subscription.finished = true
        if message.hasKey("error"):
          subscription.failure = message{"error", "message"}.getStr()
      else:
        if inbox.responses.len >= inbox.queueCapacity:
          raise newException(IOError, "Unconsumed response queue exceeded capacity")
        inbox.responses[key] = $message
      return true
    let id = if message{"method"}.getStr() == "notifications/cancelled":
        message{"params", "requestId"}
      else: message{"params", "_meta", SubscriptionIdKey}
    if id == nil or $id notin inbox.subscriptions:
      return false
    let
      subscription {.cursor.} = inbox.subscriptions[$id]
      methodName = message{"method"}.getStr()
    if methodName == "notifications/cancelled":
      subscription.finished = true
      return true
    if methodName in ["notifications/subscriptions/acknowledged", "notifications/events/active"] and subscription.acknowledgedText.len == 0:
      subscription.acknowledgedText = $message
    if subscription.finished:
      return true
    if subscription.queue.len >= inbox.queueCapacity:
      subscription.failure = "Subscription queue capacity exceeded"
      subscription.finished = true
      subscription.cancelSent = true
      subscription.cancel(subscription.id)
      return true
    subscription.queue.addLast($message)
    if methodName == "notifications/events/terminated":
      subscription.finished = true
    return true

proc receive*(subscription: Subscription, timeoutMs = -1): SubscriptionRead =
  let deadline = getMonoTime() + initDuration(milliseconds = max(0, timeoutMs))
  while true:
    withLock subscription.inbox.gate:
      if subscription.failure.len > 0:
        raise newException(SubscriptionLostError, subscription.failure)
      if subscription.queue.len > 0:
        return SubscriptionRead(kind: SubscriptionMessage, message: parseJson(subscription.queue.popFirst()))
      if subscription.finished:
        return SubscriptionRead(kind: SubscriptionClosed)
      if subscription.inbox.disconnected:
        raise newException(SubscriptionLostError, subscription.inbox.failure)
    if timeoutMs >= 0 and getMonoTime() >= deadline:
      return SubscriptionRead(kind: SubscriptionTimeout)
    sleep(ReceiveSleepMs)

proc waitAcknowledged*(subscription: Subscription, timeoutMs = DefaultRequestTimeoutMs) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    withLock subscription.inbox.gate:
      if subscription.acknowledgedText.len > 0:
        return
      if subscription.finished:
        raise newException(SubscriptionLostError, "Subscription closed before acknowledgment")
      if subscription.failure.len > 0:
        raise newException(SubscriptionLostError, subscription.failure)
      if subscription.inbox.disconnected:
        raise newException(SubscriptionLostError, subscription.inbox.failure)
    if getMonoTime() >= deadline:
      raise newException(IOError, "Subscription acknowledgment timed out")
    sleep(ReceiveSleepMs)

proc close*(subscription: Subscription) =
  var cancel = false
  withLock subscription.inbox.gate:
    cancel = $subscription.id in subscription.inbox.subscriptions and not subscription.inbox.disconnected and not subscription.cancelSent
    subscription.cancelSent = true
    subscription.finished = true
    subscription.inbox.subscriptions.del($subscription.id)
  if cancel:
    subscription.cancel(subscription.id)

proc waitResponse*(inbox: ClientInbox, id: JsonNode, timeoutMs = DefaultRequestTimeoutMs): JsonNode =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    withLock inbox.gate:
      if $id in inbox.responses:
        result = parseJson(inbox.responses[$id])
        inbox.responses.del($id)
        return
      if inbox.disconnected:
        raise newException(SubscriptionLostError, inbox.failure)
    if getMonoTime() >= deadline:
      raise newException(IOError, "MCP request timed out")
    sleep(ReceiveSleepMs)

proc listEvents*[T](client: T, cursor = ""): JsonNode =
  mixin request
  client.request("events/list", if cursor.len > 0: %*{"cursor": cursor} else: %*{})

proc pollEvents*[T](client: T, poll: EventPollRequest): EventBatch =
  mixin request
  let params = %*{"name": poll.name, "arguments": (if poll.arguments == nil: %*{} else: poll.arguments)}
  params["cursor"] = if poll.cursor.isSome: %poll.cursor.get else: newJNull()
  if poll.maxAgeMs > 0:
    params["maxAgeMs"] = %poll.maxAgeMs
  if poll.maxEvents > 0:
    params["maxEvents"] = %poll.maxEvents
  parseEventBatch(client.request("events/poll", params))

proc listenNotifications*[T](client: T, filter: SubscriptionFilter): Subscription =
  mixin openSubscription
  client.openSubscription("subscriptions/listen", %*{"notifications": filter})

proc subscribeEvents*[T](client: T, poll: EventPollRequest): Subscription =
  mixin openSubscription
  let params = %*{"name": poll.name, "arguments": (if poll.arguments == nil: %*{} else: poll.arguments)}
  params["cursor"] = if poll.cursor.isSome: %poll.cursor.get else: newJNull()
  if poll.maxAgeMs > 0:
    params["maxAgeMs"] = %poll.maxAgeMs
  client.openSubscription("events/stream", params)

proc acknowledged*(subscription: Subscription): JsonNode =
  withLock subscription.inbox.gate:
    if subscription.acknowledgedText.len > 0:
      result = parseJson(subscription.acknowledgedText)

proc bufferNotification*(inbox: ClientInbox, message: JsonNode) =
  withLock inbox.gate:
    if inbox.notifications.len >= inbox.queueCapacity:
      raise newException(IOError, "Unconsumed notification queue exceeded capacity")
    inbox.notifications.addLast($message)

proc dispatchNotifications*(inbox: ClientInbox, callback: Option[NotificationCallback]) =
  var notifications: seq[string]
  withLock inbox.gate:
    while inbox.notifications.len > 0:
      notifications.add(inbox.notifications.popFirst())
  if callback.isSome:
    for message in notifications:
      callback.get()(parseJson(message))

proc closeInbox*(inbox: ClientInbox) =
  withLock inbox.gate:
    inbox.subscriptions.clear()
    inbox.responses.clear()
    inbox.notifications.clear()
