## MCPort ⚙️

![glowing blue computers](static/crystal_computer.png "Why doesn't your computer have a giant blue crystal?")

Nim library for building Model Context Protocol (MCP) servers and clients. Supports STDIO and HTTP transports.
[Model Context Protocol](https://modelcontextprotocol.io/docs/getting-started/intro).

- Warning: this is a work in progress!
- the MCP client code has not been extensively tested.
- the MCP server currently logs everything out to console, including any sensitive data in requests, so be careful.
- http server does not use tls, you should wrap this with a reverse proxy for security (eg: nginx + certbot).

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
