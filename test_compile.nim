import src/mcport/mcp_client_core

echo "Testing compilation..."

let client = newMcpClient("Test", "1.0.0")
echo "Client created"

let request = client.createInitializeRequest()
echo "Request created"

echo "Compilation test complete" 
