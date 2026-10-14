import
  std/json,
  mcport

const Url = "ws://127.0.0.1:8097/mcp/ws"

proc main() =
  let client = newWebSocketMcpClient("push-example", "1", Url)
  client.connectAndInitialize()
  defer: client.close()
  let subscription = client.subscribeEvents(EventPollRequest(name: "message"))
  defer: subscription.close()
  while true:
    let update = subscription.receive()
    if update.kind == SubscriptionClosed:
      break
    if update.kind == SubscriptionMessage:
      echo update.message

when isMainModule:
  main()
