## Example usage of MCPort library
## This shows how to create MCP servers with custom tools

import
  std/[json, os, options],
  mcport

proc createCustomServer(): McpServer =
  ## Create a custom MCP server with multiple tools.
  let server = newMcpServer("ExampleMCPServer", "1.0.0")
  
  # Tool 1: Simple greeting
  let greetingTool = McpTool(
    name: "greet",
    description: "Greet someone with a custom message",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Name of the person to greet"
        },
        "language": {
          "type": "string",
          "description": "Language for greeting (en, es, fr)",
          "enum": ["en", "es", "fr"]
        }
      },
      "required": ["name"],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )
  
  proc greetingHandler(arguments: JsonNode): JsonNode =
    let name = arguments["name"].getStr()
    let language = arguments.getOrDefault("language").getStr("en")
    
    let greeting = case language:
      of "es": "¡Hola"
      of "fr": "Bonjour"
      else: "Hello"
    
    return %*(greeting & ", " & name & "!")
  
  server.registerTool(greetingTool, greetingHandler)
  
  # Tool 2: Math calculator
  let mathTool = McpTool(
    name: "calculate",
    description: "Perform basic math operations",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "operation": {
          "type": "string",
          "description": "Math operation to perform",
          "enum": ["add", "subtract", "multiply", "divide"]
        },
        "a": {
          "type": "number",
          "description": "First number"
        },
        "b": {
          "type": "number",
          "description": "Second number"
        }
      },
      "required": ["operation", "a", "b"],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )
  
  proc mathHandler(arguments: JsonNode): JsonNode =
    let operation = arguments["operation"].getStr()
    let a = arguments["a"].getFloat()
    let b = arguments["b"].getFloat()
    
    let calcResult = case operation:
      of "add": a + b
      of "subtract": a - b
      of "multiply": a * b
      of "divide": 
        if b == 0:
          raise newException(ValueError, "Division by zero")
        a / b
      else:
        raise newException(ValueError, "Unknown operation")
    
    return %*calcResult
  
  server.registerTool(mathTool, mathHandler)

  # Progress-enabled tool: Long running task
  let progressTool = McpTool(
    name: "long_task",
    description: "Simulates a long-running task with progress reporting",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "duration": {
          "type": "integer",
          "description": "Duration in seconds (1-10)",
          "minimum": 1,
          "maximum": 10,
          "default": 3
        }
      },
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
  )

  proc longTaskHandler(arguments: JsonNode, progressReporter: ProgressReporter): ToolResult =
    let duration = arguments.getOrDefault("duration").getInt(3)
    let steps = 10
    let progressToken = "long-task-demo"  # Demo progress token

    for i in 0..<steps:
      # Simulate work
      sleep(duration * 1000 div steps)

      # Report progress
      let progress = (i + 1).float / steps.float
      progressReporter(
        progressToken = progressToken,
        progress = some(progress),
        status = some("Step " & $(i+1) & " of " & $steps & " completed")
      )

    return ToolResult(
      content: @[textContent("Long task completed after " & $duration & " seconds!")],
      isError: false
    )

  # Enable progress capability and notifications
  server.enableProgressCapability()
  server.enableProgressNotifications()

  server.registerProgressTool(progressTool, longTaskHandler)

  # Prompt: Code review assistant
  let codeReviewPrompt = McpPrompt(
    name: "code_review",
    description: some("Asks the LLM to analyze code quality and suggest improvements"),
    arguments: @[
      PromptArgument(name: "code", description: some("The code to review"), required: true)
    ]
  )

  proc codeReviewHandler(arguments: JsonNode): seq[PromptMessage] =
    let code = arguments["code"].getStr()
    return @[
      PromptMessage(
        role: "user",
        content: textPromptContent("Please review this code and provide feedback on quality, potential improvements, and best practices:\n\n" & code)
      )
    ]

  server.registerPrompt(codeReviewPrompt, codeReviewHandler)

  # Resource: Server configuration
  let configResource = McpResource(
    uri: "config://server-info",
    name: some("Server Configuration"),
    description: some("Current server configuration and settings"),
    mimeType: some("application/json")
  )

  proc configHandler(uri: string): ResourceContent =
    let config = %*{
      "server_name": "ExampleMCPServer",
      "version": "1.0.0",
      "features": ["tools", "prompts", "resources"],
      "uptime": "simulated",
      "environment": "development"
    }
    return ResourceContent(isText: true, text: $config)

  server.registerResource(configResource, configHandler)

  return server

proc main() =
  ## Main function to run the appropriate server based on command line args.
  let args = commandLineParams()
  
  if args.len > 0 and args[0] == "http":
    # Run HTTP server
    let mcpServer = createCustomServer()
    let httpServer = newHttpMcpServer(mcpServer)
    echo "Starting HTTP MCP server on http://localhost:8080"
    echo "Send JSON-RPC requests to this endpoint with Content-Type: application/json"
    httpServer.serve(8080, "0.0.0.0")
  else:
    # Run STDIO server (default)
    echo "Starting STDIO MCP server..."
    echo "Use with Claude Desktop or other MCP clients"
    let server = createCustomServer()
    runStdioServer(server)

when isMainModule:
  main() 
