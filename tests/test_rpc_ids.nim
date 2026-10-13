import
  std/[json],
  jsony,
  mcport/mcp_core

let server = newMcpServer("test", "1")
server.toolsOnly = true
for id in [%1, %"request-1"]:
  let reply = server.handleRequest($(%*{"jsonrpc":"2.0", "id":id, "method":"ping"}))
  doAssert not reply.isError
  doAssert parseJson(reply.response.toJson())["id"] == id
let reply = server.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}")
doAssert not reply.isError
doAssert reply.response.result["capabilities"].len == 1
doAssert server.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}").isError
