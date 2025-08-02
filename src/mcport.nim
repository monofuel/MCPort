## MCPort - Nim library for Model Context Protocol (MCP) servers and clients
## 
## This library provides both STDIO and HTTP transport implementations for MCP servers.
## You can easily create MCP servers that work with Claude Desktop and other MCP clients.

import
  mcport/[mcp_core, mcp_server_stdio, mcp_server_http]

export
  mcp_core,
  mcp_server_stdio,
  mcp_server_http

# Re-export commonly used types and functions for convenience
export
  McpServer, McpTool, ToolHandler, HttpMcpServer,
  newMcpServer, registerTool, runStdioServer, newHttpMcpServer
