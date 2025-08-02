echo "Testing import..."

when isMainModule:
  import src/mcport
  echo "Import successful"
  
  let server = newMcpServer("Test", "1.0.0")
  echo "Server created: ", server.serverInfo.name 
