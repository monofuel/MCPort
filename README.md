# MCPort - Model Context Protocol for Nim

MCPort is a Nim library that makes it easy to create Model Context Protocol (MCP) servers. MCP is Anthropic's protocol that allows AI assistants like Claude to securely connect to external tools and data sources.

## Features

- **Transport Agnostic**: Support for both STDIO and HTTP transports
- **Easy Tool Registration**: Simple API for adding custom tools
- **Type Safe**: Full Nim type safety for JSON-RPC messages
- **Modular Design**: Clean separation between protocol logic and transport
- **Production Ready**: Built on proven libraries (Mummy for HTTP)

## Quick Start

### Basic STDIO Server

```nim
import mcport

# Create a server
let server = newMcpServer("MyServer", "1.0.0")

# Register a tool
let greetTool = McpTool(
  name: "greet",
  description: "Greet someone",
  inputSchema: %*{
    "type": "object",
    "properties": {
      "name": {"type": "string", "description": "Person to greet"}
    },
    "required": ["name"]
  }
)

proc greetHandler(arguments: JsonNode): JsonNode =
  let name = arguments["name"].getStr()
  return %*("Hello, " & name & "!")

server.registerTool(greetTool, greetHandler)

# Run the server
runStdioServer(server)
```

### HTTP Server

```nim
import mcport

let mcpServer = newMcpServer("MyHTTPServer", "1.0.0")
# ... register tools ...

let httpServer = newHttpMcpServer(mcpServer)
httpServer.serve(Port(8080), "0.0.0.0")
```

## Architecture

MCPort uses a modular architecture with clean separation of concerns:

```
mcport/
├── mcp_core.nim         # Core MCP protocol logic (transport-agnostic)
├── mcp_server_stdio.nim # STDIO transport implementation  
├── mcp_server_http.nim  # HTTP transport implementation
└── mcp_server.nim       # Backwards compatibility layer
```

### Core Components

- **`McpServer`**: Main server object that handles MCP protocol logic
- **`McpTool`**: Defines a tool with name, description, and JSON schema
- **`ToolHandler`**: Function that executes when a tool is called
- **Transport Layers**: STDIO and HTTP implementations

## API Reference

### Types

```nim
type
  McpServer* = ref object     # Main server instance
  McpTool* = object          # Tool definition
    name*: string
    description*: string
    inputSchema*: JsonNode
  
  ToolHandler* = proc(arguments: JsonNode): JsonNode {.gcsafe.}
  HttpMcpServer* = ref object # HTTP server wrapper
```

### Core Functions

```nim
proc newMcpServer*(name: string, version: string): McpServer
proc registerTool*(server: McpServer, tool: McpTool, handler: ToolHandler)
proc runStdioServer*(server: McpServer)
proc newHttpMcpServer*(mcpServer: McpServer, logEnabled: bool = true): HttpMcpServer
```

## Examples

See `examples/simple_server.nim` for a complete example with multiple tools.

### Running Examples

```bash
# STDIO server (for Claude Desktop)
nim c -r examples/simple_server.nim

# HTTP server
nim c -r examples/simple_server.nim http
```

## Integration with Claude Desktop

To use your MCP server with Claude Desktop, add it to your configuration:

```json
{
  "mcpServers": {
    "my-nim-server": {
      "command": "/path/to/your/server",
      "args": []
    }
  }
}
```

## HTTP Client Usage

For HTTP servers, send JSON-RPC requests to the server endpoint:

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

## Error Handling

MCPort follows Nim best practices for error handling:

- Protocol errors are returned as JSON-RPC error responses
- Tool execution errors are caught and returned as tool execution failures
- Transport errors bubble up naturally with full stack traces

## Backwards Compatibility

The original `mcp_server.nim` API is still supported but deprecated. New projects should use the modular API:

```nim
# Old way (still works)
import mcport/mcp_server

# New way (recommended)
import mcport
let server = newMcpServer("MyServer", "1.0.0")
```

## Dependencies

- `jsony` - JSON serialization
- `mummy` - HTTP server (for HTTP transport only)

## Testing

MCPort includes comprehensive unit tests using `std/unittest`:

```bash
nimble test  # Automatically runs all tests/test_*.nim files
```

The tests focus on the example `secret_fetcher` tool to verify protocol compliance and functionality. See `tests/README.md` for detailed information.

## Contributing

MCPort follows the Nim coding conventions outlined in `agents.md`. Key points:

- Use `##` for documentation comments
- Group imports by type (std, libraries, local)
- Prefer `const` over `let`, `let` over `var`
- Use complete sentences for comments
- Always run tests: `nimble test`

## License

[Your license here]
