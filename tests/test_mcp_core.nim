import
  std/[unittest, json, tables, strutils, options, sequtils],
  mcport/mcp_core,
  ./test_helpers

suite "MCP Core Tests":

  setup:
    let server = createAndInitializeTestServer()

  test "server creation":
    check server.serverInfo.name == "TestServer"
    check server.serverInfo.version == "1.0.0"
    check server.initialized

  test "tool registration":
    check server.tools.hasKey("secret_fetcher")
    check server.toolHandlers.hasKey("secret_fetcher")

  test "initialize request":
    let initRequest = makeInitRequest()
    let result = server.handleRequest(initRequest)

    check not result.isError
    check server.initialized
    check result.response.result["serverInfo"]["name"].getStr() == "TestServer"

  test "tools/list request":
    let listRequest = makeToolsListRequest()
    let result = server.handleRequest(listRequest)

    check not result.isError
    let tools = result.response.result["tools"]
    check tools.len == 1
    check tools[0]["name"].getStr() == "secret_fetcher"
    # nextCursor should be omitted when there's no pagination
    check not result.response.result.hasKey("nextCursor")

  test "tools/call with default recipient":
    let callRequest = makeToolCallRequest(3, "secret_fetcher")
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]["text"].getStr()
    check content == "Test tool processed: default"

  test "tools/call with custom recipient":
    let callRequest = makeToolCallRequest(4, "secret_fetcher", %*{"recipient": "Monofuel"})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]["text"].getStr()
    check content == "Hello, Monofuel!"

  test "error on unknown tool":
    let callRequest = makeToolCallRequest(6, "unknown_tool")
    let result = server.handleRequest(callRequest)

    check result.isError
    check result.error.error.code == -32602
    check result.error.error.message.contains("Unknown tool name")

  test "error on invalid JSON":
    let invalidRequest = """{"invalid":"json","missing":"required fields"}"""
    let result = server.handleRequest(invalidRequest)

    check result.isError
    check result.error.error.code == -32600

  test "prompt registration":
    check server.prompts.hasKey("code_review")
    check server.promptHandlers.hasKey("code_review")

  test "prompts/list request":
    let listRequest = makePromptsListRequest(7)
    let result = server.handleRequest(listRequest)

    check not result.isError
    let prompts = result.response.result["prompts"]
    check prompts.len == 1
    check prompts[0]["name"].getStr() == "code_review"
    check prompts[0]["arguments"].len == 1
    check prompts[0]["arguments"][0]["name"].getStr() == "topic"
    check prompts[0]["arguments"][0]["required"].getBool() == true
    # nextCursor should be omitted when there's no pagination
    check not result.response.result.hasKey("nextCursor")

  test "prompts/get request with arguments":
    let getRequest = makePromptsGetRequest(8, "code_review", %*{"topic": "test code"})
    let result = server.handleRequest(getRequest)

    check not result.isError
    let messages = result.response.result["messages"]
    check messages.len == 1
    check messages[0]["role"].getStr() == "user"
    check messages[0]["content"]["type"].getStr() == "text"
    check messages[0]["content"]["text"].getStr().contains("test code")

  test "prompts/get request without optional arguments":
    let getRequest = makePromptsGetRequest(9, "code_review")
    let result = server.handleRequest(getRequest)

    check result.isError
    check result.error.error.code == -32602
    check result.error.error.message.contains("Missing required argument")

  test "error on unknown prompt name":
    let getRequest = makePromptsGetRequest(11, "unknown_prompt")
    let result = server.handleRequest(getRequest)

    check result.isError
    check result.error.error.code == -32602
    check result.error.error.message.contains("Unknown prompt name")

  test "resource registration":
    check server.resources.hasKey("config://test-server")
    check server.resourceHandlers.hasKey("config://test-server")

  test "resources/list request":
    let listRequest = makeResourcesListRequest(12)
    let result = server.handleRequest(listRequest)

    check not result.isError
    let resources = result.response.result["resources"]
    check resources.len == 1
    check resources[0]["uri"].getStr() == "config://test-server"
    check resources[0]["name"].getStr() == "Test Server Config"
    check resources[0]["mimeType"].getStr() == "application/json"
    # nextCursor should be omitted when there's no pagination
    check not result.response.result.hasKey("nextCursor")

  test "resources/read request with text content":
    let readRequest = makeResourceReadRequest(13, "config://test-server")
    let result = server.handleRequest(readRequest)

    check not result.isError
    let contents = result.response.result["contents"]
    check contents.len == 1
    check contents[0].hasKey("text")
    let text = contents[0]["text"].getStr()
    check text.contains("\"content\":\"test data\"")
    check text.contains("\"uri\":\"config://test-server\"")

  test "error on unknown resource URI":
    let readRequest = makeResourceReadRequest(15, "config://unknown")
    let result = server.handleRequest(readRequest)

    check result.isError
    check result.error.error.code == -32002
    check result.error.error.message.contains("Resource not found")

  test "rich content tool - text content":
    registerRichContentTestTool(server)

    let callRequest = makeToolCallRequest(16, "rich_content_test", %*{"content_type": "text"})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]
    check content["type"].getStr() == "text"
    check content["text"].getStr() == "This is plain text content"

  test "rich content tool - image content":
    registerRichContentTestTool(server)

    let callRequest = makeToolCallRequest(17, "rich_content_test", %*{"content_type": "image"})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]
    check content["type"].getStr() == "image"
    check content["data"].getStr().startsWith("data:image/png;base64,")

  test "rich content tool - audio content":
    registerRichContentTestTool(server)

    let callRequest = makeToolCallRequest(18, "rich_content_test", %*{"content_type": "audio"})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]
    check content["type"].getStr() == "audio"
    check content["data"].getStr().startsWith("data:audio/wav;base64,")

  test "rich content tool - resource_link content":
    registerRichContentTestTool(server)

    let callRequest = makeToolCallRequest(19, "rich_content_test", %*{"content_type": "resource_link"})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]
    check content["type"].getStr() == "resource_link"
    check content["uri"].getStr() == "test://linked-resource"
    check content["name"].getStr() == "Linked Resource"

  test "rich content tool - embedded_resource content":
    registerRichContentTestTool(server)

    let callRequest = makeToolCallRequest(20, "rich_content_test", %*{"content_type": "embedded_resource"})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]
    check content["type"].getStr() == "resource"
    let resource = content["resource"]
    check resource["uri"].getStr() == "test://embedded"
    check resource["mimeType"].getStr() == "text/plain"
    check resource["text"].getStr() == "Embedded content"

  test "rich content prompt - image content":
    registerRichContentTestPrompt(server)

    let getRequest = makePromptsGetRequest(21, "rich_prompt_test", %*{"content_type": "image"})
    let result = server.handleRequest(getRequest)

    check not result.isError
    let messages = result.response.result["messages"]
    check messages.len == 1
    let content = messages[0]["content"]
    check content["type"].getStr() == "image"
    check content["data"].getStr().startsWith("data:image/png;base64,")
    check content.hasKey("annotations")

  test "rich content prompt - audio content":
    registerRichContentTestPrompt(server)

    let getRequest = makePromptsGetRequest(22, "rich_prompt_test", %*{"content_type": "audio"})
    let result = server.handleRequest(getRequest)

    check not result.isError
    let messages = result.response.result["messages"]
    check messages.len == 1
    let content = messages[0]["content"]
    check content["type"].getStr() == "audio"
    check content["data"].getStr().startsWith("data:audio/wav;base64,")

  test "rich content prompt - embedded resource content":
    registerRichContentTestPrompt(server)

    let getRequest = makePromptsGetRequest(23, "rich_prompt_test", %*{"content_type": "embedded_resource"})
    let result = server.handleRequest(getRequest)

    check not result.isError
    let messages = result.response.result["messages"]
    check messages.len == 1
    let content = messages[0]["content"]
    check content["type"].getStr() == "resource"
    let resource = content["resource"]
    check resource["uri"].getStr() == "test://example"
    check resource["mimeType"].getStr() == "text/plain"
    check resource["text"].getStr() == "Example content"

  test "progress tool basic functionality":
    # Set up progress reporter
    proc testProgressReporter(progressToken: ProgressToken, progress: Option[float], status: Option[string], total: Option[int], current: Option[int]) =
      # Just ignore progress for this test
      discard

    server.setProgressReporter(testProgressReporter)
    registerProgressTestTool(server)

    # Call the progress tool with 3 steps
    let callRequest = makeToolCallRequest(24, "progress_test", %*{"steps": 3})
    let result = server.handleRequest(callRequest)

    check not result.isError
    let content = result.response.result["content"][0]["text"].getStr()
    check content.contains("Progress test completed with 3 steps")

  test "resource templates list":
    registerTestResourceTemplate(server)

    let listRequest = makeResourceTemplatesListRequest(26)
    let result = server.handleRequest(listRequest)

    check not result.isError
    let templates = result.response.result["resourceTemplates"]
    check templates.len == 1
    let tmpl = templates[0]
    check tmpl["uriTemplate"].getStr() == "test://template/{category}/{id}"
    check tmpl["name"].getStr() == "Test Template"
    check tmpl["description"].getStr() == "A parameterized resource template"
    check tmpl["mimeType"].getStr() == "application/json"

  test "resource templates list with multiple templates":
    registerTestResourceTemplate(server)

    # Register another template
    let template2 = McpResourceTemplate(
      uriTemplate: "api://users/{userId}/posts/{postId}",
      name: some("User Posts Template"),
      description: some("Template for accessing user posts"),
      mimeType: some("application/json")
    )
    server.registerResourceTemplate(template2)

    let listRequest = makeResourceTemplatesListRequest(27)
    let result = server.handleRequest(listRequest)

    check not result.isError
    let templates = result.response.result["resourceTemplates"]
    check templates.len == 2

    # Check that both templates are present
    let templateNames = templates.mapIt(it["name"].getStr())
    check "Test Template" in templateNames
    check "User Posts Template" in templateNames

  test "resource subscription":
    # Subscribe to the test resource
    let subscribeRequest = makeResourceSubscribeRequest(28, "config://test-server")
    let result = server.handleRequest(subscribeRequest)
    check not result.isError

  test "resource subscription to non-existent resource":
    # Try to subscribe to a resource that doesn't exist
    let subscribeRequest = makeResourceSubscribeRequest(29, "config://non-existent")
    let result = server.handleRequest(subscribeRequest)

    check result.isError
    check result.error.error.code == -32002  # Resource not found
    check result.error.error.message.contains("Resource not found")

  test "multiple resource subscriptions":
    # Subscribe to the test resource
    let subscribeRequest1 = makeResourceSubscribeRequest(30, "config://test-server")
    let result1 = server.handleRequest(subscribeRequest1)
    check not result1.isError

    # Register another resource and subscribe to it
    registerTestResource(server, "config://test-server-2", "Second Test Resource")
    let subscribeRequest2 = makeResourceSubscribeRequest(31, "config://test-server-2")
    let result2 = server.handleRequest(subscribeRequest2)
    check not result2.isError 
