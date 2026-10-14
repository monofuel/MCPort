import
  std/[json, os],
  mcport

const Url = "http://127.0.0.1:8097/mcp"

proc main() =
  let client = newHttpMcpClient("poll-example", "1", Url, logEnabled = false, modernProtocol = true)
  client.connectAndInitialize()
  defer: client.close()
  var query = EventPollRequest(name: "message")
  while true:
    let batch = client.pollEvents(query)
    for event in batch.events:
      echo event.toJsonNode()
    query.cursor = batch.cursor
    if not batch.hasMore:
      sleep(batch.nextPollMs)

when isMainModule:
  main()
