import
  std/[unittest, json],
  mcport/mcp_core

suite "Basic Integration Tests":
  
  test "core types work":
    # Just test that basic types compile and work
    let server = newMcpServer("Test", "1.0.0")
    check server.serverInfo.name == "Test"

  test "json parsing works":
    # Test basic JSON functionality
    let testJson = """{"test": "value"}"""
    let parsed = parseJson(testJson)
    check parsed["test"].getStr() == "value" 
