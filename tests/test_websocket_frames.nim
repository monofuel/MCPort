import
  std/[base64, json, net, options, os, osproc, sha1, strutils, unittest],
  whisky

proc rawServer(port: int) =
  let listener = newSocket()
  listener.bindAddr(Port(port), "127.0.0.1")
  listener.listen()
  var socket: Socket
  listener.accept(socket)
  var key = ""
  while true:
    let line = socket.recvLine()
    if line.strip.len == 0:
      break
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      key = line.split(':', 1)[1].strip()
  let accept = encode(secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").Sha1Digest)
  socket.send("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " & accept & "\r\n\r\n")
  socket.send("\x01")
  sleep(80)
  socket.send("\x03abc\x89\x01p\x80\x03def\x81\x03g")
  sleep(80)
  socket.send("hi")
  sleep(80)
  socket.close()
  listener.close()

if paramCount() == 2 and paramStr(1) == "--fixture":
  rawServer(parseInt(paramStr(2)))
  quit(0)

suite "Blocking WebSocket frames":
  test "partial frames survive timeouts and interleaved controls":
    let reservation = newSocket()
    reservation.bindAddr(Port(0), "127.0.0.1")
    let port = reservation.getLocalAddr()[1].int
    reservation.close()
    let process = startProcess(getAppFilename(), args = @["--fixture", $port], options = {poParentStreams})
    defer:
      process.terminate()
      discard process.waitForExit()
      process.close()
    sleep(100)
    let socket = newWebSocket("ws://127.0.0.1:" & $port)
    defer: socket.close()
    var messages: seq[Message]
    for i in 0..<30:
      let message = socket.receiveMessage(20)
      if message.isSome:
        messages.add(message.get)
      if messages.len == 3:
        break
    check messages.len == 3
    check messages[0].kind == Ping
    check messages[1].data == "abcdef"
    check messages[2].data == "ghi"
