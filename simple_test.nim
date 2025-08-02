import std/unittest
import src/mcport/mcp_core

suite "Basic Test":
  test "server creation":
    let server = newMcpServer("Test", "1.0.0")
    check server.serverInfo.name == "Test" 
