## Backwards compatibility layer for the original mcp_server.nim
## This file now uses the new modular structure.
## 
## For new code, prefer importing mcport and using the new API:
## ```nim
## import mcport
## let server = newMcpServer("MyServer", "1.0.0")
## # Register tools...
## runStdioServer(server)
## ```

import ./mcp_server_stdio

# Re-export for backwards compatibility
export mcp_server_stdio

when isMainModule:
  let server = createExampleServer()
  runStdioServer(server)
