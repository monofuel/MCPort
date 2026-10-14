# Notifications and experimental events

MCPort supports notification subscriptions and experimental application events
with blocking APIs. WebSocket and stdio provide push delivery. HTTP provides
JSON request/response and event polling. SSE is not supported, and HTTP clients
do not advertise acceptance of it.

## Protocol selection

Existing clients retain the `2025-06-18` initialization path. Enable modern
requests explicitly with `modernProtocol = true` on HTTP or stdio clients.
WebSocket clients use `2026-07-28`. Their `initialize()` operation discovers
capabilities through `server/discover`; subsequent requests carry independent
client information, capabilities, and protocol metadata.

Servers opt in with `server.enableModernProtocol()`. Add
`experimentalEvents = true` to expose the event methods. Register event
sources before serving; the event catalog remains static.

The HTTP implementation supports JSON operations from the modern protocol,
including discovery and event polling. It is a limited HTTP implementation,
not a complete Streamable HTTP implementation. `subscriptions/listen` and
`events/stream` are unavailable over HTTP. For remote push, use WebSockets;
for HTTP-only notification consumers, refetch lists or resources. The existing
`/notifications` endpoint remains a legacy, shared polling queue and is not
part of the modern subscription protocol.

## WebSocket binding

Enable `/mcp/ws` with `newHttpMcpServer(server, enableWebSocket = true)`.
This is a custom MCP transport, not SEP-1288. Clients must explicitly support
this binding; ordinary HTTP clients cannot connect to it automatically.

Each WebSocket text message carries one complete JSON-RPC object. Binary
messages are rejected. Protocol metadata lives in each request body. Multiple
requests and subscriptions share the socket, with integer or string request
IDs used for correlation. Subscription notifications carry the originating
request ID in `params._meta["io.modelcontextprotocol/subscriptionId"]`.
Cancellation uses `notifications/cancelled` with `params.requestId`. Closing
the connection removes every subscription belonging to it.

Existing HTTP authentication callbacks also protect WebSocket upgrades.
Supply client credentials through `requestHeaders`. Servers reject a present
Origin unless it is included in `allowedOrigins`; native clients may omit
Origin. The optional `authContext` callback supplies application context to
event authorization, checking, matching, and transformation hooks.

WebSocket clients accept `maxMessageBytes` to limit incoming messages, including
fragmented messages. Its default is `0` (unlimited). A message exceeding a
configured limit disconnects the client and reports the error.

## Client subscriptions

`listenNotifications(filter)` and `subscribeEvents(request)` return a
`Subscription` after its acknowledgment arrives. `receive(timeoutMs)` returns
`SubscriptionMessage`, `SubscriptionTimeout`, or `SubscriptionClosed`.
Unexpected loss and queue overflow raise `SubscriptionLostError`. The first
queued message is the acknowledgment. `acknowledged` also exposes it directly.
Call `close()` when finished; repeated closes are harmless.

A connection worker continuously reads and routes messages, so ordinary
requests can run while subscriptions remain open. Each Whisky socket has one
owner thread for both reads and writes. Legacy notification callbacks are
invoked on the request caller's thread after a response arrives.

Clients control reconnects, polling intervals, cursor persistence, and event
ID deduplication. No automatic reconnect, retry, or subscription restoration
occurs. Construct a new push client after connection loss. Notification streams
have no replay: resubscribe and refetch the affected lists/resources.

Client subscription queues default to 256 messages. Overflow cancels that
subscription and reports an error rather than dropping messages silently.

## Event sources

The experimental wire format follows the design sketch at revision
`d5316be214be2e76e51462069c1d67e00a5a7619`:
https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/d5316be214be2e76e51462069c1d67e00a5a7619/docs/design-sketch-proposal.md

`EventDefinition` declares a name, description, subscription argument schema,
and payload schema. `registerEvent` accepts either a cursor-based check handler
or an emit-only source. `emitEvent` publishes occurrences for emit-only sources;
it generates missing IDs and UTC timestamps. Optional authorization, matching,
and transformation hooks use the same semantics for polling and push.

Application handlers validate their domain arguments and payloads. MCPort
validates the protocol envelope. Raise `eventError(code, message)` for deliberate
protocol errors; authorization denial uses `-32024`.

Check handlers return `EventBatch`, including the upstream cursor, `hasMore`,
`truncated`, and `nextPollMs`. Keep each batch within the requested `maxEvents`,
provide occurrence cursors for replayable push events, and return promptly so
cancellation can join the worker. Returned poll intervals have a 1000 ms floor.

Event matching and transformation hooks must not call publishing or subscription
lifecycle APIs. Check handlers should query the upstream feed and return a batch;
keep server mutations outside those callbacks.

Emit-only sources retain at most 10 minutes or 10,000 occurrences, configurable
through `enableModernProtocol`. Their cursors are process-scoped and become
invalid after restart. Null initial cursors start from now; stale cursors report
truncation and resume from available history. `maxAgeMs` bounds replay without
removing history needed by other clients.

HTTP event descriptors advertise `poll`; WebSocket and stdio advertise `poll`
and `push`. Event streams send cursor-bearing heartbeats every 30 seconds.
Webhooks and dynamic event catalog notifications are not implemented.

See `examples/events_server.nim`, `examples/poll_events.nim`, and
`examples/websocket_events.nim` for a complete producer and consumers.

## Development

MCPort 1.2.0 uses [monofuel's Whisky fork](https://github.com/monofuel/whisky)
on `fix-receive-and-handshake-options`, pinned in `nimby.lock` to
`d0009565e4d8f7fd0aa33d023cc26f0b423e67aa`. The fixes are proposed upstream in
[draft PR #10](https://github.com/guzba/whisky/pull/10).

When regenerating the lock with nimby 0.2.3, retain Whisky's fork URL;
the lock generator currently emits its package-catalog URL instead.

Resolve dependencies with nimby in an explicit parent workspace:

```sh
cd ..
nimby create
cd MCPort
nimby sync nimby.lock
```

Run `make check` and `make test`. On Nix, use `nix develop --command make test`;
the development shell supplies curl and OpenSSL. Project compiler settings live
in `config.nims`, including SSL support for `wss://`.
