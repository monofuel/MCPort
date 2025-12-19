## MCPort ⚙️

![glowing blue computers](static/crystal_computer.png "Why doesn't your computer have a giant blue crystal?")

Nim library for building [Model Context Protocol](https://modelcontextprotocol.io/docs/getting-started/intro) servers and clients.

## Building an MCP Server

### Basic Server

```nim
import mcport, std/[json, options]

# Create server
let server = newMcpServer("MyServer", "1.0.0")

# Register a tool
let tool = McpTool(
  name: "greet",
  description: "Greet someone",
  inputSchema: %*{
    "type": "object",
    "properties": {
      "name": {"type": "string", "description": "Name to greet"}
    },
    "required": ["name"]
  }
)

proc greetHandler(arguments: JsonNode): JsonNode =
  let name = arguments["name"].getStr()
  return %*("Hello, " & name & "!")

server.registerTool(tool, greetHandler)

# Run server (STDIO transport)
runStdioServer(server)
```

### Register a Prompt

```nim
let prompt = McpPrompt(
  name: "code_review",
  description: some("Review code quality"),
  arguments: @[
    PromptArgument(
      name: "code",
      description: some("Code to review"),
      required: true
    )
  ]
)

proc promptHandler(arguments: JsonNode): seq[PromptMessage] =
  let code = arguments["code"].getStr()
  return @[
    PromptMessage(
      role: "user",
      content: TextContent(`type`: "text", text: "Review this code:\n" & code)
    )
  ]

server.registerPrompt(prompt, promptHandler)
```

### Register a Resource

```nim
let resource = McpResource(
  uri: "config://server-info",
  name: some("Server Configuration"),
  description: some("Server configuration data"),
  mimeType: some("application/json")
)

proc resourceHandler(uri: string): ResourceContent =
  let config = %*{"status": "running", "version": "1.0.0"}
  return ResourceContent(isText: true, text: $config)

server.registerResource(resource, resourceHandler)
```

### HTTP Transport

```nim
let httpServer = newHttpMcpServer(server)
httpServer.serve(8080, "0.0.0.0")
```

## Building an MCP Client

```nim
import mcport, std/json

let client = newMcpClient("MyClient", "1.0.0")

# Create initialize request
let initReq = client.createInitializeRequest()
# Send via your transport and get response...

# List tools
let toolsReq = client.createToolsListRequest()
# Send and handle response...

# Call a tool
let callReq = client.createToolCallRequest("greet", %*{"name": "World"})
# Send and parse response...
```

## What's Implemented

**Server:**
- Tools: register, list (with pagination), call (JSON schema + handlers + rich content)
- Prompts: register, list (with pagination), get (text/image/audio/embedded resources + annotations)
- Resources: register, list (with pagination), read (text + blob content), templates, subscriptions, notifications
- Transports: STDIO, HTTP

**Client:**
- Tools: list, call
- Transports: STDIO, HTTP

**Not implemented:**
- Progress tracking

See [MCP specification](https://modelcontextprotocol.io/specification/2025-06-18/server/) for protocol details.

## Examples

```bash
nim c -r examples/simple_server.nim         # STDIO server
nim c -r examples/simple_server.nim http    # HTTP server on port 8080
```

## Testing

```bash
nimble test
```

## Warnings

- ⚠️ Client code not extensively tested
- ⚠️ Server logs everything to console including sensitive data
- ⚠️ HTTP has no TLS - use reverse proxy for production
