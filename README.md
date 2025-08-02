# MCPort - Model Context Protocol for Nim

MCPort is a Nim library that makes it easy to create Model Context Protocol (MCP) servers and clients. MCP is Anthropic's protocol that allows AI assistants like Claude to securely connect to external tools and data sources.

## Features

- **Complete MCP Implementation**: Both servers and clients supported
- **Transport Agnostic**: Support for both STDIO and HTTP transports
- **Easy Tool Registration**: Simple API for adding custom tools (servers)
- **Simple Client API**: Easy connection to existing MCP servers (clients)
- **Type Safe**: Full Nim type safety for JSON-RPC messages
- **Modular Design**: Clean separation between protocol logic and transport
- **Production Ready**: Built on proven libraries (Mummy for HTTP)

## Quick Start

### MCP Server

#### Basic STDIO Server

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

#### HTTP Server

```nim
import mcport

let mcpServer = newMcpServer("MyHTTPServer", "1.0.0")
# ... register tools ...

let httpServer = newHttpMcpServer(mcpServer)
httpServer.serve(Port(8080), "0.0.0.0")
```

### MCP Client

#### STDIO Client

```nim
import mcport

# Create a client
let client = newStdioMcpClient("MyClient", "1.0.0")

# Connect to server process
if client.connectAndInitialize("path/to/server", @[]):
  # List available tools
  echo "Tools: ", client.getAvailableTools()
  
  # Call a tool
  let result = client.callTool("greet", %*{"name": "World"})
  if not result.isError:
    echo "Response: ", result.content[0].text
  
  # Cleanup
  client.close()
```

#### HTTP Client

```nim
import mcport

# Create a client
let client = newHttpMcpClient("MyClient", "1.0.0", "http://localhost:8080")

# Connect to server
if client.connectAndInitialize():
  # Call a tool
  let result = client.callTool("greet", %*{"name": "World"})
  if not result.isError:
    echo "Response: ", result.content[0].text
  
  # Cleanup
  client.close()
```

## Architecture

MCPort uses a modular architecture with clean separation of concerns:

```
mcport/
├── mcp_core.nim           # Core MCP protocol logic (transport-agnostic)
├── mcp_server_stdio.nim   # STDIO server transport implementation  
├── mcp_server_http.nim    # HTTP server transport implementation
├── mcp_client_core.nim    # Core client logic (transport-agnostic)
├── mcp_client_stdio.nim   # STDIO client transport implementation
├── mcp_client_http.nim    # HTTP client transport implementation
└── mcp_server.nim         # Backwards compatibility layer
```

### Core Components

**Server Components:**
- **`McpServer`**: Main server object that handles MCP protocol logic
- **`McpTool`**: Defines a tool with name, description, and JSON schema
- **`ToolHandler`**: Function that executes when a tool is called

**Client Components:**
- **`McpClient`**: Core client for managing server connections
- **`StdioMcpClient`**: STDIO transport client (launches server processes)
- **`HttpMcpClient`**: HTTP transport client (connects to HTTP servers)
- **`ToolCallResult`**: Results from tool execution

**Transport Layers:** STDIO and HTTP implementations for both servers and clients

## API Reference

### Server Types

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

### Client Types

```nim
type
  McpClient* = ref object        # Core client instance
  StdioMcpClient* = ref object   # STDIO transport client
  HttpMcpClient* = ref object    # HTTP transport client
  
  ToolCallResult* = object       # Tool execution result
    case isError*: bool
    of true: errorMessage*: string
    of false: content*: seq[ContentItem]
  
  ContentItem* = object          # Response content item
    type*: string
    text*: string
```

### Server Functions

```nim
proc newMcpServer*(name: string, version: string): McpServer
proc registerTool*(server: McpServer, tool: McpTool, handler: ToolHandler)
proc runStdioServer*(server: McpServer)
proc newHttpMcpServer*(mcpServer: McpServer, logEnabled: bool = true): HttpMcpServer
```

### Client Functions

```nim
proc newStdioMcpClient*(name: string, version: string, logEnabled: bool = true): StdioMcpClient
proc newHttpMcpClient*(name: string, version: string, baseUrl: string, logEnabled: bool = true): HttpMcpClient
proc connectAndInitialize*(client: StdioMcpClient, command: string, args: seq[string] = @[]): bool
proc connectAndInitialize*(client: HttpMcpClient): bool
proc callTool*(client: StdioMcpClient | HttpMcpClient, toolName: string, arguments: JsonNode = %*{}): ToolCallResult
```

## Examples

- **`examples/simple_server.nim`** - Complete server example with multiple tools
- **`examples/client_examples.nim`** - Client examples for both STDIO and HTTP

### Running Examples

```bash
# Server examples
nim c -r examples/simple_server.nim        # STDIO server (for Claude Desktop)
nim c -r examples/simple_server.nim http   # HTTP server

# Client examples (demonstrates client usage)
nim c -r examples/client_examples.nim
```

## Usage Patterns

### Server Integration with Claude Desktop

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

### Client-Server Communication

#### STDIO Pattern (Process-based)
```nim
# Client launches and communicates with server process
let client = newStdioMcpClient("MyClient", "1.0.0")
if client.connectAndInitialize("./my-server", @[]):
  let result = client.callTool("my_tool", %*{"param": "value"})
  client.close()
```

#### HTTP Pattern (Network-based)
```nim
# Client connects to running HTTP server
let client = newHttpMcpClient("MyClient", "1.0.0", "http://localhost:8080")
if client.connectAndInitialize():
  let result = client.callTool("my_tool", %*{"param": "value"})
  client.close()
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
