import
  std/[base64, json, sets, strutils]

const
  HeaderPrefix = "=?base64?"
  HeaderSuffix = "?="
  MaxSafeInteger = 9_007_199_254_740_991'i64
  HeaderTokenChars = {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}

proc encodeHeaderValue*(value: string): string =
  var encoded = value != value.strip() or (value.startsWith(HeaderPrefix) and value.endsWith(HeaderSuffix))
  for ch in value:
    if ch notin {'\t', ' '..'~'}:
      encoded = true
  if encoded: HeaderPrefix & encode(value) & HeaderSuffix else: value

proc decodeHeaderValue*(value: string): string =
  if value.startsWith(HeaderPrefix) and value.endsWith(HeaderSuffix):
    decode(value[HeaderPrefix.len ..< value.len - HeaderSuffix.len])
  else:
    value

proc requestName*(message: JsonNode): string =
  case message{"method"}.getStr()
  of "tools/call", "prompts/get": message{"params", "name"}.getStr()
  of "resources/read": message{"params", "uri"}.getStr()
  else: ""

proc parameterHeaders*(schema, arguments: JsonNode): seq[(string, string)] =
  var
    names = initHashSet[string]()
    headers: seq[(string, string)]
  proc visit(node, value: JsonNode, reachable: bool) =
    if node == nil:
      return
    if node.kind == JObject:
      if node.hasKey("x-mcp-header"):
        let
          name = node["x-mcp-header"].getStr()
          kind = node{"type"}.getStr()
        if not reachable or name.len == 0 or name.toLowerAscii() in names or kind notin ["string", "integer", "boolean"]:
          raise newException(ValueError, "Invalid x-mcp-header annotation")
        for ch in name:
          if ch notin HeaderTokenChars:
            raise newException(ValueError, "Invalid x-mcp-header name")
        names.incl(name.toLowerAscii())
        if value != nil:
          let valid = (kind == "string" and value.kind == JString) or
            (kind == "integer" and value.kind == JInt and value.getBiggestInt() in -MaxSafeInteger..MaxSafeInteger) or
            (kind == "boolean" and value.kind == JBool)
          if not valid:
            raise newException(ValueError, "Invalid HTTP parameter value")
          let text = if value.kind == JString: value.getStr() else: $value
          headers.add(("Mcp-Param-" & name, encodeHeaderValue(text)))
      for key, child in node:
        if key == "properties" and child.kind == JObject:
          for property, definition in child:
            visit(definition, value{property}, reachable)
        elif key != "x-mcp-header":
          visit(child, nil, false)
    elif node.kind == JArray:
      for child in node:
        visit(child, nil, false)
  visit(schema, arguments, true)
  result = headers
