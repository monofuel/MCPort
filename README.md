## MCPort ⚙️

Nim library for building Model Context Protocol (MCP) servers and clients. Supports STDIO and HTTP transports.
[Model Context Protocol](https://modelcontextprotocol.io/docs/getting-started/intro).

### Features
- **Servers and clients**: Build MCP clients and servers.
- **Transports**: STDIO and HTTP.
- **Simple tools**: Register tools with JSON schema inputs and text outputs.
- **Type-safe**: Strongly typed JSON-RPC messages with Nim.
- **Minimal deps**: uses `curly`, `jsony` and `mummy`.

### Examples

Example Build and run:
```bash
nim c -r examples/simple_server.nim         # STDIO server
nim c -r examples/simple_server.nim http    # HTTP server
```

### Testing
```bash
nimble test
```
