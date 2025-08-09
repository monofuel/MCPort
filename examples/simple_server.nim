## Example usage of MCPort library
## This shows how to create MCP servers with custom tools

import
  std/[json, os],
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
