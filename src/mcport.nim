## MCPort - Nim library for Model Context Protocol (MCP) servers and clients
## 
## This library provides both STDIO and HTTP transport implementations for MCP servers and clients.
## You can easily create MCP servers that work with Claude Desktop and other MCP clients,
## or create MCP clients that connect to existing MCP servers.

import
  mcport/[mcp_core, mcp_server_stdio, mcp_server_http, mcp_client_core, mcp_client_stdio, mcp_client_http]

export
  mcp_core,
  mcp_server_stdio,
  mcp_server_http,
  mcp_client_core,
  mcp_client_stdio,
  mcp_client_http

# Re-export commonly used server types and functions
export
  McpServer, McpTool, ToolHandler, HttpMcpServer,
  newMcpServer, registerTool, runStdioServer, newHttpMcpServer

# Re-export commonly used client types and functions  
export
  McpClient, StdioMcpClient, HttpMcpClient, ClientInfo, ToolCallResult, ContentItem,
  newMcpClient, newStdioMcpClient, newHttpMcpClient, createExampleStdioClient, createExampleHttpClient
