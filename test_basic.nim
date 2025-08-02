import std/unittest
import src/mcport/mcp_core

echo "Testing basic compilation..."

suite "Basic":
  test "server creation works":
    let server = newMcpServer("Test", "1.0.0")
    check server.serverInfo.name == "Test"
    check server.serverInfo.version == "1.0.0"
    check not server.initialized

echo "Basic test completed" 
