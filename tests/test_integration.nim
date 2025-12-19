import
  std/[unittest, json, strutils, options],
  mcport/mcp_core,
  ./test_helpers

suite "Integration Tests":

  test "full MCP workflow - tools":
    ## Test complete workflow: initialize → list tools → call tool → get result
    let server = createAndInitializeTestServer()

    # 1. Initialize (already done by createAndInitializeTestServer)

    # 2. List available tools
    let listRequest = makeToolsListRequest(1)
    let listResult = server.handleRequest(listRequest)
    check not listResult.isError
    let tools = listResult.response.result["tools"]
    check tools.len >= 1  # At least the secret_fetcher tool

    # 3. Call a tool
    let callRequest = makeToolCallRequest(2, "secret_fetcher", %*{"recipient": "IntegrationTest"})
    let callResult = server.handleRequest(callRequest)
    check not callResult.isError

    # 4. Verify the result
    let content = callResult.response.result["content"][0]["text"].getStr()
    check content == "Hello, IntegrationTest!"

  test "full MCP workflow - resources":
    ## Test complete resource workflow: list resources → read resource → verify content
    let server = createAndInitializeTestServer()

    # 1. List available resources
    let listRequest = makeResourcesListRequest(3)
    let listResult = server.handleRequest(listRequest)
    check not listResult.isError
    let resources = listResult.response.result["resources"]
    check resources.len >= 1

    # 2. Read a resource
    let readRequest = makeResourceReadRequest(4, "config://test-server")
    let readResult = server.handleRequest(readRequest)
    check not readResult.isError

    # 3. Verify the content
    let contents = readResult.response.result["contents"]
    check contents.len == 1
    check contents[0]["text"].getStr().contains("\"content\":\"test data\"")

  test "full MCP workflow - prompts":
    ## Test complete prompt workflow: list prompts → get prompt → verify content
    let server = createAndInitializeTestServer()

    # 1. List available prompts
    let listRequest = makePromptsListRequest(5)
    let listResult = server.handleRequest(listRequest)
    check not listResult.isError
    let prompts = listResult.response.result["prompts"]
    check prompts.len >= 1

    # 2. Get a prompt with arguments
    let getRequest = makePromptsGetRequest(6, "code_review", %*{"topic": "test code"})
    let getResult = server.handleRequest(getRequest)
    check not getResult.isError

    # 3. Verify the prompt content
    let messages = getResult.response.result["messages"]
    check messages.len >= 1
    check messages[0]["role"].getStr() == "user"
    check messages[0]["content"]["text"].getStr().contains("test code")

  test "progress tool workflow":
    ## Test progress tool functionality
    let server = createAndInitializeTestServer()

    # Set up progress reporter
    proc testProgressReporter(progressToken: ProgressToken, progress: Option[float], status: Option[string], total: Option[int], current: Option[int]) =
      # Just ignore progress for this test
      discard
    server.setProgressReporter(testProgressReporter)

    # Register and call progress tool
    registerProgressTestTool(server)
    let callRequest = makeToolCallRequest(7, "progress_test", %*{"steps": 2})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]["text"].getStr()
    check content.contains("Progress test completed with 2 steps")

  test "resource subscription workflow":
    ## Test subscription functionality
    let server = createAndInitializeTestServer()

    # Subscribe to a resource
    let subscribeRequest = makeResourceSubscribeRequest(8, "config://test-server")
    let subscribeResult = server.handleRequest(subscribeRequest)
    check not subscribeResult.isError

  test "rich content workflow":
    ## Test rich content workflow: call tool → receive rich content → verify structure
    let server = createAndInitializeTestServer()
    registerRichContentTestTool(server)

    # Call tool for image content
    let callRequest = makeToolCallRequest(9, "rich_content_test", %*{"content_type": "image"})
    let callResult = server.handleRequest(callRequest)

    check not callResult.isError
    let content = callResult.response.result["content"][0]
    check content["type"].getStr() == "image"
    check content["data"].getStr().startsWith("data:image/png;base64,")

  test "error handling workflow":
    ## Test error handling: invalid request → receive error response
    let server = createAndInitializeTestServer()

    # Try to call non-existent tool
    let callRequest = makeToolCallRequest(10, "non_existent_tool")
    let callResult = server.handleRequest(callRequest)

    check callResult.isError
    check callResult.error.error.code == -32602  # Method not found
    check callResult.error.error.message.contains("Unknown tool name")

  test "resource templates workflow":
    ## Test resource templates: register template → list templates → verify structure
    let server = createAndInitializeTestServer()
    registerTestResourceTemplate(server)

    # List templates
    let listRequest = makeResourceTemplatesListRequest(11)
    let listResult = server.handleRequest(listRequest)

    check not listResult.isError
    let templates = listResult.response.result["resourceTemplates"]
    check templates.len >= 1
    check templates[0]["uriTemplate"].getStr() == "test://template/{category}/{id}" 
