import { Layer, ManagedRuntime } from "effect";
import { PiHostLive, type PiHost } from "./services/piHost.ts";
import { SessionPushBusesLive, type SessionPushBuses } from "./services/pushBus.ts";

/**
 * The Effect composition seam (Slice 3, t3code's `serverLayers` pattern).
 *
 * Everything the Effect runtime provides is composed here, in ONE place:
 * each service module exports a `*Live` layer, and this file merges them into
 * `serverLayers`. Later slices join the merge — the intended end state:
 *
 *   Layer.mergeAll(
 *     SessionPushBusesLive,
 *     PiHostLive,          // Slice 4 — scoped subprocess lifecycle (landed)
 *     SessionManagerLive,  // Slice 5 — consumes push bus + pi-host
 *     PersistenceLive,     // Slice 6
 *   )
 *
 * Dependencies between services are wired with `Layer.provide` /
 * `Layer.provideMerge` at the composition site (see t3code's
 * apps/server/src/server.ts), never by services importing each other's Live
 * layers directly.
 *
 * Lifecycle: `startServer()` (server.ts) builds one ManagedRuntime per server
 * and disposes it in `close()`, so scoped services (Slice 4+) get their
 * finalizers run on shutdown. Until Slice 5 makes SessionManager a consumer,
 * live callsites still reach the push bus through the `SessionPushBus` class
 * adapter (pushBus.ts), which wraps the same handle implementation the layer
 * serves, and pi subprocesses through the legacy `PiSession` path — the Effect
 * services are exercised through the runtime by the unit tests plus, for
 * PiHost, a real-pi integration test (test/piHost.pi.test.ts).
 */
export const serverLayers = Layer.mergeAll(SessionPushBusesLive, PiHostLive);

/** Union of every service the runtime can provide (grows with the merge). */
export type ServerServices = SessionPushBuses | PiHost;

export type ServerRuntime = ManagedRuntime.ManagedRuntime<ServerServices, never>;

export const makeServerRuntime = (): ServerRuntime => ManagedRuntime.make(serverLayers);
