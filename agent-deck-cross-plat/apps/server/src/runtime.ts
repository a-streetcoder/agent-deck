import { Layer, ManagedRuntime } from "effect";
import { PersistenceLive, type Persistence } from "./services/persistence.ts";
import { PiHostLive, type PiHost } from "./services/piHost.ts";
import { SessionPushBusesLive, type SessionPushBuses } from "./services/pushBus.ts";
import {
  SessionManagerServiceLive,
  type SessionManagerService,
} from "./services/sessionManager.ts";
import { TerminalHostLive, type TerminalHost } from "./services/terminal.ts";

/**
 * The Effect composition seam (Slice 3, t3code's `serverLayers` pattern).
 *
 * Everything the Effect runtime provides is composed here, in ONE place:
 * each service module exports a `*Live` layer, and this file merges them into
 * `serverLayers`. The coordinator (`SessionManagerService`, Slice 5) depends on
 * the two leaf services, so it is wired with `Layer.provideMerge`:
 *
 *   SessionManagerServiceLive          // Slice 5 — consumes push bus + pi-host
 *     ├── SessionPushBusesLive         // Slice 3
 *     ├── PiHostLive                   // Slice 4 — scoped subprocess lifecycle
 *     └── PersistenceLive              // Slice 6 — JSON-file app-data stores
 *
 * `provideMerge` feeds the leaf layers INTO the coordinator AND re-exports them,
 * so PiHost / SessionPushBuses / Persistence stay directly resolvable through the
 * runtime (the one-shot helper launch resolves PiHost that way, and the
 * leaf-service unit + real-pi tests exercise them). Dependencies between services
 * are always wired at THIS composition site, never by services importing each
 * other's Live layers directly.
 *
 * `Persistence` is a Slice-6 leaf on the SAME footing the push bus held at Slice
 * 3: joined here so a future Effect-native consumer (Slice 7 routes) resolves it
 * through the runtime, while today the synchronous class facade in
 * persistence.ts still reads it via a total `Effect.runSync(make*)` — no runtime
 * needed, so production writes don't yet flow through this tag.
 *
 * Lifecycle: `startServer()` (server.ts) builds one ManagedRuntime per server
 * and disposes it in `close()`, so scoped services get their finalizers run on
 * shutdown.
 *
 * ## Production-carrying as of Slice 5
 *
 * This runtime is no longer transitional debt: `SessionManager`
 * (../SessionManager.ts) is now a synchronous facade over
 * `SessionManagerService`, so EVERY live chat session's pi subprocess and push
 * bus are resolved through this runtime and owned by a per-session Scope. The
 * legacy `new SessionPushBus()` / direct `new PiSession()` production paths are
 * retired — the pi-host class survives only for its own package tests.
 *
 * Session-scope ownership (precise — Slice 6 copies this): each session's Scope
 * is a DETACHED root (`runtime.runSync(Scope.make())` in the facade), NOT a
 * child of the runtime's own scope. So `dispose()` does not itself close session
 * scopes; the pi-killing finalizer runs when the session's `stop()` closes that
 * scope, and `close()` calls `sessions.stopAll()` (fault-tolerant) BEFORE
 * `dispose()` for exactly that reason. `dispose()` then interrupts the
 * `runFork`'d fibers the runtime owns and runs the leaf-service layer
 * finalizers. A session whose `stop()` throws could leak its scope — a known,
 * narrow gap; a future slice may re-root session scopes under a runtime-held
 * parent so `dispose()` reclaims leaks.
 */
const leafLayers = Layer.mergeAll(
  SessionPushBusesLive,
  PiHostLive,
  PersistenceLive,
  // Slice 8a — terminal PTY factory, a PiHost sibling (scoped process handles).
  TerminalHostLive,
);

export const serverLayers = SessionManagerServiceLive.pipe(Layer.provideMerge(leafLayers));

/** Union of every service the runtime can provide (grows with the merge). */
export type ServerServices =
  | SessionPushBuses
  | PiHost
  | SessionManagerService
  | Persistence
  | TerminalHost;

export type ServerRuntime = ManagedRuntime.ManagedRuntime<ServerServices, never>;

export const makeServerRuntime = (): ServerRuntime => ManagedRuntime.make(serverLayers);
