// The client half of the Slice-7 Effect-RPC-over-WebSocket transport. The web
// app (Slice 7b) constructs an `RpcTransport` against the server's `/rpc` path,
// wires `onPush` into the domain reducer, and drives (re)subscription from
// `onConnected`. Runtime deps: effect + @agent-deck/contracts (the wire schema).
export * from "./transport.ts";
