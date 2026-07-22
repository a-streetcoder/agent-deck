# Effect Migration & t3code Feature-Port Plan

Goal: rebuild the server/client substrate on Effect following t3code's architecture
(github.com/pingdotgg/t3code, MIT — reference clone, do not track upstream), so their
feature code (terminal, diffs, preview browser, file nav, command palette, remote, …)
can be ported as donor pairs — while pi stays the only engine and `packages/domain`
stays pure.

Ground rules (unchanged from README non-negotiables):

1. The streaming CI test (≥2 distinct `text_delta`s before finalize) stays green after
   **every** slice.
2. Every slice ends verified against a real `pi` binary (`pnpm test:pi`) before the next
   slice starts.
3. Each slice is independently landable: the app runs, e2e passes, and the slice's seam
   is the only boundary that moved.
4. **Visual gate** (added 2026-07-20): `e2e/tests/visual.spec.ts` holds masked screenshot
   baselines (app shell, skills screen, transcript exchange) that run as part of the
   Playwright suite. Behavior specs can't see style breakage; these can. Regenerate
   intentionally via `pnpm --filter @agent-deck/e2e test:visual:update` and review the
   diff. Baselines are per-platform (auto-suffixed); a platform without baselines skips.
   This gate is MANDATORY at the Slice 7 transport cutover and for every web-facing
   feature slice.

`packages/domain` is **not** rewritten to Effect. It is pure TS (reducer, ingestion,
schemas) and gets wrapped, not ported.

Existing Agent Deck features (skills import/sync/conflicts, agents, scopes, prompts,
loops, memory tools, MCP tools, worktrees, release action, onboarding, provider login)
**carry through the migration unchanged** — Phases 0–3 preserve behavior. Only new
features get slices.

---

## Phase 0 — Contracts seam (no behavior change)

### Slice 1 — `packages/contracts` with Effect Schema

- Add Effect toolchain deps (workspace root + new package only).
- Create `packages/contracts`: port `packages/domain/src/protocol.ts` (ClientMessage,
  ServerMessage, SessionMeta, ProjectMeta, DiscoveredProject) to Effect Schema.
- Wire format is **identical** — this slice moves the source of truth, not the bytes.
- Golden-fixture test: a corpus of recorded wire messages (valid + invalid) must
  accept/reject identically under the old zod schemas and the new Effect schemas.
- `domain/protocol.ts` becomes a re-export shim; server/web imports migrate to
  `@agent-deck/contracts`.
- Exit gate: typecheck, fixture parity test, streaming test, `test:pi`.
- **Status: LANDED (2026-07-19).** effect 3.22.0, 48-fixture parity corpus + type-level
  assignability tests. The domain re-export shim was deferred (readonly-vs-mutable
  friction at apps/server callsites + a domain⇄contracts cycle) — the parity test is
  the enforced seam; fold the import migration into Slice 7. Known nuance: Effect
  Record accepts exotic objects (Date/Map) that zod rejects — equivalent over
  JSON-derived input only, which is what the WS boundary feeds it.

## Phase 1 — Monolith decomposition (plain TS, pre-Effect)

### Slice 2 — Split `apps/server/src/server.ts` (3,896 lines)

- Extract along the _future service boundaries_ (this mapping is the whole point):
  - `routes/sessions.ts`, `routes/projects.ts`, `routes/resources.ts`,
    `routes/settings.ts`, `routes/git.ts` (REST)
  - `wsHandler.ts` (socket accept, subscribe/replay, message dispatch)
  - anything left in `server.ts` is bootstrap only.
- Pure mechanical refactor: no signature or behavior changes, e2e untouched.
- Exit gate: full suite + `test:pi` + desktop e2e.
- **Status: LANDED (2026-07-19).** server.ts 3,896 → 597 lines; 9 route modules +
  wsHandler.ts + bridgeTools.ts. Review minors all resolved same day: dead
  `gitCloneShallow` removed; composition pieces (ServerContext, envDefaults,
  asThinkingLevel, NamedAgentLaunch) moved from routes/shared.ts to src/context.ts;
  repo-record root resolution deduped (rootsForRepoRecord); shared
  createSessionWorktree helper in git.ts used by loops + sessions.

## Phase 2 — Effect inside the shell (service by service)

Order matters: leaf services first, coordinator last. Fastify stays as the HTTP shell
throughout this phase — handlers call into a `ManagedRuntime`; dropping Fastify for
`@effect/platform` HttpServer is an optional post-migration slice, not a dependency.

### Slice 3 — Runtime bootstrap + PushBus service

- `ManagedRuntime` created in `index.ts`/`mainModule.ts`; Layers composed in one place
  (t3code's `serverLayers` pattern).
- Port `SessionPushBus` to an Effect service (Ref + PubSub, same ring/replay semantics).
  Keep a thin class adapter so existing callsites don't churn in this slice.
- Port its unit tests; add a replay-equivalence test against the old implementation.
- **Status: LANDED (2026-07-20).** `src/runtime.ts` ManagedRuntime/serverLayers seam
  (created per server, disposed in close); `services/pushBus.ts` with DELIBERATELY
  synchronous single-op dispatch (atomicity note in module doc — PubSub rejected to
  preserve legacy ordering); legacy class kept as runSync adapter + as the equivalence
  oracle (`pushBusLegacy.ts`, dies with Slice 7); 26 tests incl. a seeded randomized
  legacy-vs-Effect equivalence suite plus pinned throw/mid-dispatch-mutation semantics.
  Review minors resolved same day: FiberFailure unwrap in the adapter (error identity
  preserved), latched+rejection-safe CLI shutdown, template caveats documented
  (subscribeScoped/Option surfaces for Slice 5/7 consumers). Known transitional debt:
  the ManagedRuntime is production-dead until Slice 5 makes SessionManager a real
  consumer (documented in runtime.ts).

### Slice 4 — PiHost as a scoped service

- Wrap `packages/pi-host` subprocess lifecycle in `Effect.acquireRelease` + `Scope`
  (spawn/kill), RPC correlation via `Deferred`, JSONL stdout as `Stream`.
- pi-host's public API stays stable; `packages/pi-host` internals stay portable (it is
  also used by tests). The Effect wrapper lives server-side first.
- This is the slice where Effect has to prove itself against the process-lifecycle
  edge cases (abort, exit mid-turn, resume). Budget review time accordingly.
- **Status: LANDED (2026-07-20).** `services/piHost.ts`: scoped spawn (acquireRelease,
  tree-kill on release), Deferred RPC correlation (exit fails pending), JSONL Stream
  terminated by exit; joined into serverLayers. packages/pi-host hardened: stdin EPIPE
  swallow, cross-platform process-tree kill, drain-gated exit (buffered stdout flushes
  before ProcessExit), stop() bounded by a 10s last-resort deadline so a wedged child
  can't hang shutdown. 13 fake-subprocess unit tests + a real-pi service test (spawn →
  streamed turn → clean close, orphan check via kill(pid,0)). The three items deferred
  to Slice 5 scope all LANDED 2026-07-20 (pre-Slice-5 hardening):
  (1) events queue single-consumer contract ENFORCED — `events` is one-shot
  (second run fails typed `PiEventsAlreadyConsumed`) and scope-tied: consumer
  detach shuts the queue down, later lines are dropped (counted in the
  `droppedEvents` diagnostic) instead of accumulating unboundedly; no re-attach
  by design (RPC correlation + awaitExit survive detach).
  (2) JSONL line-classification deduped into `packages/pi-host/src/rpcProtocol.ts`
  (classifyPiLine, req-N id source, shared timeout constants), consumed by both
  PiSession and the Effect service; existing tests on both sides untouched.
  (3) kill-escalation coverage: SIGTERM-ignoring fixture → SIGKILL-after-grace
  (POSIX-only, skipIf win32) and a SIGTERM-ignoring grandchild reaped by the
  tree kill on scope close (runs on BOTH platforms — Windows exercises the
  taskkill /T path).

### Slice 5 — SessionManager service

- `SessionManager.ts` (1,086 lines) becomes an Effect service consuming Slice 3+4
  services. Supervisor + receipts fold in here (they are small and coupled to it).
- Domain ingestion (`domain/ingest.ts`) is called as a pure function — unchanged.
- **Status: LANDED (2026-07-20).** `services/sessionManager.ts`
  (`SessionManagerService`, template anatomy) is the coordinator, joined into
  `serverLayers` via `Layer.provideMerge` over PiHostLive + SessionPushBusesLive.
  Each session owns a `Scope.CloseableScope`: pi comes from PiHost, the bus from
  SessionPushBuses, and session close == scope close == pi tree-kill. The
  per-session ingestion fiber is the long-lived single consumer of PiHost's
  scope-tied `events` stream; a single synchronous `emit` (transcript reduce +
  `bus.append`) keeps stdout order (leans on the S3 sync-dispatch guarantee), and
  synthetic domain events (subagent cards, plan, supervisor cards) stamp through
  the SAME `emit`. Resume needs no seed gate — `getMessages()` (RPC-correlated)
  seeds first, then ingestion forks and drains the buffered live events strictly
  after. Title/subagent/one-shot-helper launches spawn their own pi through the
  same PiHost service under short-lived `Effect.scoped` blocks, retiring the last
  `new PiSession()` / `new SessionPushBus()` production paths. `SessionManager.ts`
  is now a synchronous class facade (adapter, like pushBus.ts) over the service —
  external API unchanged for routes/wsHandler/bridgeTools (Effect-native at S7);
  it resolves everything through the server's ManagedRuntime, which now carries
  production traffic (runtime.ts doc updated). supervisor.ts + receipts.ts kept as
  their own modules — they are coupled to the ROUTES (bridge.ts) and the receipts
  bus, not the manager internals, so the service _consumes_ ReceiptBus and the
  observable receipt timing (first_delta / assistant_final / idle / session_created
  / title) is byte-identical. Exit handling is idempotent and driven by the
  ProcessExit stream item, with a post-scope-close `ensureExitHandled` guard in
  `stop()` so endedAt/session_meta fire before session_removed (legacy ordering).
  Full gate green: typecheck, lint, format:check, `pnpm test`, and `pnpm test:pi`
  (pi-host 5, apps/server 54 real-pi, e2e 118 incl. abort/resume/exit-mid-turn).
  Review: 5 blocker/major findings fixed in-workflow; the 3 deferred minors
  resolved on landing — (a) title/session-file daemons already fork via
  `forkIn(sessionScope)` (not `forkDaemon`), so `stopAll()` on close interrupts
  them and no helper pi orphans; (b) the resume/fork plan-vs-buffered-events
  ordering flagged as a behavior change is inert — plans mutate ONLY via the
  set/update_session_plan BRIDGE tools, never pi stdout, so no buffered pi event
  can race the restore (documented at both call sites); (c) runtime.ts doc
  corrected — session Scopes are detached roots reclaimed by `stopAll()` before
  `dispose()`, not by `dispose()` itself (matters for S6 copying the pattern).

### Slice 6 — Persistence service

- `persistence.ts` behind a service interface; on-disk format unchanged.
- Optional follow-up (not this slice): SQLite via `@effect/sql-sqlite` per t3code —
  revisit when checkpointing (Slice 16) needs transactional turn snapshots.
- **Status: LANDED (2026-07-20).** `services/persistence.ts` (Persistence service:
  JsonArrayStore + SettingsStore handles) joined into serverLayers; on-disk JSON format
  byte-identical (atomic tmp+rename, defaults, back-compat coercion, defaultDataDir all
  preserved) — proven by a round-trip fixture test against real on-disk files. Class
  facade (persistence.ts) is a thin adapter using `runSyncUnwrapped` so fs errors keep
  their raw identity + `err.code` (parity test). Review minors: error-identity finding
  fixed (runSyncUnwrapped); the E=never-on-fallible-I/O finding is documented as a
  deliberate caveat and DEFERRED to Slice 7 (below) — the tagged `PersistenceWriteError`
  is designed with its first Effect-native consumer, not speculatively.

- Exit gate for each Phase-2 slice: full suite + `test:pi` + streaming test.

**PHASE 2 COMPLETE (2026-07-20):** the entire server substrate runs on Effect
(runtime + push bus + pi-host + session manager + persistence), all behind synchronous
class facades so routes/wsHandler/bridgeTools are unchanged until Slice 7.

## Phase 3 — Transport swap (the one breaking seam)

### Slice 7 — Effect RPC over WebSocket, side by side, then cutover

- New endpoint speaking Effect RPC (contracts from Slice 1) mounted **alongside** the
  legacy `ws` envelope. Both serve simultaneously.
- New `packages/client-runtime`: transport state machine, reconnect/backoff, typed push
  decode at the boundary (t3code's WsTransport pattern).
- Web app switches behind a flag; e2e runs against both; delete the legacy path only
  after reconnect/replay parity tests (subscribe with `lastSeq`, ring-evicted fallback
  to snapshot) pass on the new transport.
- This is the only slice where client and server move together. Everything before it is
  server-internal; everything after it builds on it.
- **Also fold in here** (deferred from earlier slices, now that routes go Effect-native):
  - Slice 1's `domain/protocol.ts` re-export shim → migrate server/web imports to
    `@agent-deck/contracts`, and add the Effect Record plain-object refinement (reject
    Date/Map that zod rejected) now that the Effect schema becomes the runtime validator.
  - Slice 6's persistence error channel: move `flush`/`mkdir` to `Effect.try` with a
    `PersistenceWriteError` tagged error, mapped by the new Effect-native routes to HTTP
    5xx (the E=never write paths documented as a caveat in services/persistence.ts).
  - pushBus's `subscribeScoped` + `replayFrom` Option surfaces for the now-Effect-native
    wsHandler consumer (documented in services/pushBus.ts Template caveats).
- **Status: LANDED (2026-07-20). PHASE 3 COMPLETE.** Built in three staged parts, all
  green: S7a — Effect-RPC endpoint on `/rpc` (packages/contracts/src/rpc.ts framing)
  mounted alongside the legacy envelope; contracts became the runtime validator
  (+ Record plain-object refinement); domain→contracts shim migration done; new
  `packages/client-runtime` (transport state machine, reconnect/backoff, typed push
  decode, 9 unit tests). S7b — web cut over behind a flag; reconnect/replay/eviction
  parity proven (e2e transport-parity.spec.ts: replay tail, evicted-lastSeq snapshot
  fallback, reconnect-mid-turn no gap-or-dup); streaming non-negotiable green on the
  new transport; visual baselines UNCHANGED. S7c — legacy `/ws` envelope deleted,
  `/rpc` sole path, contracts Effect Schema sole socket validator; pushBusLegacy.ts +
  equivalence oracle retired as planned. Review: zero blocker/major. Deferred minors
  → follow-up commit (client-runtime reconnect-timer clear) and 7-polish backlog
  (rpcHandler push backpressure cap; persistence PersistenceWriteError; pushBus
  subscribeScoped/Option surfaces — still open by scope discipline).

---

# Feature roadmap (Phases 4–11)

Each feature slice is a contracts + server-service + web-component triple ported from
the t3code reference clone. Server halves are near-lifts once the substrate matches;
web halves are **pattern-ports** (their component as visual/behavioral spec, rewritten
against our client-runtime and styling) unless we later adopt their atom stack.

Donor paths below are relative to the t3code clone.

## Phase 4 — Tracer bullet

### Slice 8 — Terminal

- Donor: `packages/contracts/src/terminal.ts`, `apps/server/src/terminal/`
  (NodePtyAdapter), `apps/web/.../ThreadTerminalDrawer.tsx` (xterm).
- Per-session terminal drawer running in the session cwd (worktree-aware).
- Success here validates the whole substrate bet; friction here is cheap early signal.
- Exit gate: e2e opening a terminal in a real session worktree.
- **Status: LANDED (2026-07-20).** Server half (8a): `contracts/src/terminal.ts`
  wire schema (terminal ops ride `RpcClientFrame`; pushes get their own
  `terminal_push`/`terminal_open_ok` frame kinds), `services/terminal.ts`
  TerminalHost (scoped PTY on the piHost template: acquireRelease kill
  escalation, donor PtyAdapter seam, lazy node-pty, capped scrollback with
  atomic attach), `terminalGateway.ts` facade + rpcHandler ops — server-allocated
  ids, scrollback replay on reattach, teardown funneled into one scope close
  (terminal_close / connection drop / session exit). Web half (8b):
  `components/TerminalDrawer.tsx` (xterm + FitAddon, resizable bottom drawer on
  the chat surface, ported from ThreadTerminalDrawer minus splits/tabs),
  header toggle + Ctrl/⌘+` shortcut with the donor's terminalFocus guard,
transport terminal ops in client-runtime (`openTerminal`/`terminalRequest`/
`onTerminalPush`) and a per-session terminal-id registry in wsBridge (closing
the drawer keeps the PTY; reopening reattaches and replays scrollback; ids
die with the connection). Gate: `e2e/tests/terminal.spec.ts`against the real
stack (echo round-trip via a shell variable, session-cwd match, scrollback
replay on reopen, shortcut toggle) + a 4th visual baseline (drawer open,
deterministic prompt via the`AGENT_DECK_TERMINAL_SHELL`+`PROMPT`seam).
Review: 4 blocker/major findings fixed in-workflow; minors resolved on
landing — orphan-observability log when kill escalation is exhausted,
surrogate-safe chunk/scrollback cuts,`connectionClosed` guard on the awaited
  terminal_open spawn, client-side in-flight open dedup (pendingOpens join).
  Deferred (latent until a light theme exists): donor's dual ANSI palette +
  live retheming — pick up with the theming slice (S19).

## Phase 5 — Change review core

### Slice 9 — Diff engine (server)

- Donor: `apps/server/src/{vcs,sourceControl,review}/` shapes; extend our `git.ts`
  (worktree logic already exists) toward per-turn changed-file tracking and diff
  computation. Receipts for "diff finalized" per our existing receipts pattern.
- **Status: LANDED (2026-07-20).** Server half only (web panel is Slice 10).
  Contracts (`contracts/src/diff.ts`): `diff_files` / `diff_file` requests ride
  `RpcClientFrame` (terminal-op pattern); replies get their own frame kinds
  (`diff_files_ok` — status letter/rename oldPath/insertions/deletions/binary
  per entry, capped at `DIFF_MAX_FILES` with a truncated flag; `diff_file_ok` —
  unified patch capped at `DIFF_MAX_PATCH_CHARS` + truncated/binary flags) and
  an unsolicited `diff_push` (`diff_changed` carries the full new set).
  Diff-base semantics follow the donor's review preview: working tree vs HEAD
  for the SESSION's checkout (worktree-aware `meta.cwd`), staged+unstaged,
  `-M` rename detection, untracked included (status `?`) with `/dev/null`
  no-index synthesis (verified on Windows git), empty-tree base in a
  no-commit repo. `services/diff.ts` (`SessionDiff`, template anatomy) caches
  per session with a fingerprint compare (VcsStatusBroadcaster pattern —
  missing cache compares as an empty set, so a clean first refresh is quiet);
  git plumbing added to git.ts as pure exec helpers (name-status/numstat `-z`
  parsers, bounded-capture runner that returns partial output + truncated on
  maxBuffer overflow). Turn-boundary hook: `SpawnSessionParams.onIdle` forked
  into the session Scope at agent-idle exactly like captureSessionFile /
  generateTitle (receipt timing untouched — pinned by test); server.ts wires
  refresh → on change: `diff_push` broadcast + `diff_refreshed` receipt (new
  ReceiptName). rpcHandler ops validate session ownership like terminal ops;
  cwd never rides the wire. Non-git sessions answer `repo:false` + empty set,
  never an error; the only repo probe is one rev-parse per turn-boundary/on-
  demand refresh (nothing per keystroke), and fileDiff only accepts paths git
  itself listed (doubles as the traversal guard). Tests: 10 service tests on
  real scratch repos (modify/staged-add/delete/pure-rename/binary/untracked/
  fresh-repo, patch + set truncation, fingerprint change detection, cache/
  drop), 4 rpcHandler op tests (fake gateway), an idle-fork sessionManager
  test, and `diff-refresh.pi.test.ts` — real pi + real repo: turn boundary
  after a working-tree write → receipt + push + both ops over `/rpc`. Client
  transport ignores the new frame kinds until Slice 10 (decode-safe, no web
  code this slice; visual baselines untouched).
  Review majors fixed on landing: `--literal-pathspecs` on gitDiffFilePatch
  (glob names like `app/[id]/page.tsx` were expanding to sibling files'
  diffs — reproduced) and the turn-boundary spawn storm replaced by a cheap
  scan (3 git spawns + fs.stat untracked identity) gating the per-file
  numstat pass, with a 2s racily-clean guard on the fs.stat fingerprint.
  Also: darwin CI skip for the real node-pty smoke test (spawn-helper exec
  permission on mac runners; linux+windows ship targets green through e2e).

### Slice 10 — Diff panel + changed-files tree (web)

- Donor: `DiffPanel.tsx`, `DiffPanelShell.tsx`, `DiffWorkerPoolProvider.tsx`,
  `chat/ChangedFilesTree.tsx`, `chat/DiffStatLabel.tsx`.
- Diff rendering in web workers; changed-files tree in the session view wired to the
  Slice 9 stream.
- **Status: LANDED (2026-07-21, ae8a39c).** Transport diff ops + onDiffPush in
  client-runtime (Slice-8 pattern); tree/panel/stat-label pattern-ported (no worker
  pool — documented rationale: no shiki highlighting, 200k-char server cap,
  react-virtuoso rows); session-scoped stale-while-revalidate on file diffs (review
  fix); AGENT_DECK_DEFAULT_CWD e2e seam; diff.spec.ts real-pi e2e + 5th visual
  baseline stable. Deferred minors: session-switch toggle blink (aggressive reset —
  revisit at S19 polish), client-side tests for error/binary/truncated panel states.

### Slice 11 — Open-in editor (VS Code / JetBrains / etc.)

- Donor: `apps/server/src/process/externalLauncher.ts`, `chat/OpenInPicker.tsx`,
  `JetBrainsIcons.tsx`.
- Open file/line from diff panel, changed-files tree, and transcript file references.
- Small slice; lands right after Slice 10 so diffs get "open in editor" immediately.
- DEFERRED from this slice: transcript file references. The transcript renderer has
  no file-reference detection/linkification yet, so there is no anchor to hang the
  open action on; landing the diff-panel + changed-files-tree surfaces now and
  revisiting transcript references once the transcript gains file-reference
  rendering (natural home: Slice 13 file navigation, or S19 polish).
- **Status: LANDED (2026-07-21, fc63e3f).** Donor 20-editor table, PATH×PATHEXT
  detection re-probed per list (donor parity), .cmd shell-hop escaping, containment
  (relative-only, segment-aware "..", symlink realpath compare, canonical-path
  launch), server-detected ids only, AGENT_DECK_OPEN_BIN argv seam; OpenInPicker
  split control on diff header + tree rows; preferredEditor in AppSettings. Review:
  3 confirmed fixed in-workflow, 4 minors fixed on landing. Deferred: picker ARIA
  menu keyboard pattern → S19. Post-landing: mac CI fix — launcher tests now expect
  CANONICAL paths (mac tmpdir is a /var→/private/var symlink; the TOCTOU fix
  returns realpath). ae3a0e5's windows-e2e desktop-electron CI failure confirmed a
  runner flake (green again on fc63e3f).

### Slice 12 — Review comments → composer

- Donor: `apps/server/src/review/`, `chat/ComposerPendingReviewComments.tsx`.
- Comment on a diff hunk; comments accumulate as pending composer context and are sent
  as a structured follow-up turn to pi.
- Depends on Slices 9–10.
- **Status: LANDED (2026-07-21, dfc6a0b).** Client-side only (no server review/ state
  needed — the donor serializes into the prompt client-side): hover-revealed inline
  comment editor on diff rows, per-session pending cards above the composer
  (ComposerPendingReviewComments), donor-faithful `<review_comment>` serialization
  appended to the next prompt + cleared on send. Review fixes: sectionId → donor's
  literal `"unstaged"`, same-frame double-submit guard. Deferred: stale-card
  re-anchor (cosmetic; outgoing excerpt frozen/correct) → S19. e2e + 6th visual
  baseline. **PHASE 5 COMPLETE** — diff engine → panel → open-in-editor → review
  comments all landed.

## Phase 6 — Files & navigation

### Slice 13 — File tree + file preview

- Donor: `components/files/` (FilePreviewPanel), workspace file endpoints.
- Project file navigation panel + read-only preview (syntax highlight, images), gated
  to project root/worktree paths.
- **Status: LANDED (2026-07-21, 2cbafb8).** Server file list/read (services/files.ts)
  gated by a SHARED `pathContainment.ts` (extracted from editorLauncher — one hardened
  containment gate, reused not re-copied); bounded read, binary/image handling. Web
  Files panel: session-header toggle → lazy directory tree (changed-files-tree pattern)
  - read-only preview with syntax highlight/image/binary states, S11 OpenInPicker wired
    into the preview header. Review minors fixed: file_list decode maxItems cap (DiffPush
    parity), StrictMode-safe lazy-load. New files-panel visual baseline + 4 legit header
    baseline updates (Files toggle). Deferred: readdir-before-cap, NUL-only binary
    heuristic (donor-faithful).

### Slice 14 — Command palette + keybindings

- Donor: `CommandPalette*.tsx`, `apps/server/src/keybindings.ts`,
  `KeybindingsUpdateToast.*`.
- Palette over sessions/projects/actions; user-editable keybindings persisted
  server-side; toast on binding conflicts after updates.
- Mostly client-side; server surface is the keybindings store.
- **Status: LANDED (2026-07-22, 2ece926).** Ctrl/Cmd+K palette (grouped, fuzzy,
  keyboard-nav; pure logic in CommandPalette.logic.ts + tests) over nav/session/panel/
  action commands. Keybindings map with donor defaults persisted in AppSettings
  (chord-validated PATCH); live editor with conflict detection; ALL prior hardcoded
  shortcuts unified through the map (rebindable, no parallel path). Review: blocker
  fixed in-workflow — native-menu recovery (File→Edit Keybindings…) so a lost
  palette open-chord can't lock the editor away; minor fixed — Escape-closes the
  editor. Deferred: empty-string-unbind not persisted (dead via UI), focus-trap +
  navigator.platform → S19 a11y pass. 2 new visual baselines. **PHASE 6 COMPLETE**
  (file tree + preview, command palette + keybindings).

## Phase 7 — Preview browser

### Slice 15 — Embedded preview surface + port discovery

- Donor: `apps/server/src/preview/`, `apps/web/src/components/preview/`
  (addBrowserSurface, openDiscoveredPort, previewActionBus),
  `ProjectScriptsControl.tsx` + `apps/server/src/{environment,project}/` script running.
- Run project dev scripts from the UI (processRunner), detect listening ports, open the
  dev server in an embedded preview panel; terminal links open in preview.
- Depends on terminal (Slice 8) for the script-output surface.
- **Status: LANDED (2026-07-22, e5c4bc6).** services/scriptRunner.ts (terminal.ts
  template — Scope-owned managed child, tree-kill, 0 orphans; shares
  TERMINAL_ENV_BLOCKLIST) runs DECLARED scripts only, streams output, detects the
  loopback port (stdout match + TCP confirm-probe). Web PreviewPanel: scripts control
  - sandboxed iframe embed. Security: loopback-only embed ENFORCED at both the URL bar
    and the iframe-src boundary (shared isLoopbackHost guard) — not just advertised.
    Deferred (doc corrected, not overclaimed): port-probe can't prove the listener is
    this run's own PID — donor's socket→process-tree mapping is the hardening. New
    preview visual baseline; Toggle Preview palette command. Terminal-link-to-preview:
    not built (no anchor yet). NO annotation-to-composer (that is S16).

### Slice 16 — Preview automation → composer context

- Donor: `preview/PreviewAutomationHosts.tsx`, `previewAutomation*`,
  `chat/ComposerPreviewAnnotationCards.tsx`, `ComposerPendingElementContexts.tsx`.
- Point at an element / annotate a screenshot in the preview; annotation becomes a
  structured composer context card sent to pi with the next turn.
- This is a flagship "slick" feature — schedule demo time; it sells the migration.
- **Status: LANDED (2026-07-22, 66b8a12).** Manual-subset port (documented +
  justified): the donor's in-frame react-grab inspector needs an Electron webview
  preload + ipcRenderer, impossible against our sandboxed cross-origin iframe — so
  rather than a postMessage bridge (prompt-injection / pixel-leak surface), the user
  names the element (selector/note), the preview URL auto-attaches, → the donor's
  `<element_context>` card riding the next pi turn (S12 pattern). No page-derived DOM
  captured, so the injection surface doesn't exist. Security minor fixed: pageUrl (the
  one non-user-provenance field) sanitized through a shared lib/loopback.ts (extracted
  from PreviewPanel). New visual baseline. **PHASE 7 COMPLETE** — preview browser +
  element automation.
  - Follow-up: the FULL point-and-click inspector could return in the Electron shell
    (S22 desktop polish) via a webview preload, once the desktop bridge exposes one.

## Phase 8 — Session UX parity

### Slice 17 — Composer upgrades

- Donor: `chat/Composer*` family — pending-approval panel + actions, pending-user-input
  panel (maps onto our existing `ui_response` pass-through), context window meter,
  file tag chips, terminal context chips, expanded image previews,
  `apps/server/src/attachmentStore.ts` for attachments.
- Split into 2–3 landings if reviews get large; each chip/panel is independent.
- **Status: LANDED (2026-07-22, c826c88).** Coherent subset, EXTENDING existing
  surfaces (context meter, token footer, image attachments, @-file autocomplete all
  already existed — not rebuilt). Landed: composer-anchored pending user-input panel
  (on the existing `ui_response` pass-through, NO wire change; answer controls
  extracted to a shared `QuestionAnswerControls` used by transcript + composer, with a
  module-scoped single-answer guard); file tag chips (view over draft @-mention
  tokens); expanded image dialog. New composer-file-tag-chips visual baseline.
  DEFERRED to the Slice-23 parity audit (assess value there, not a dedicated S17b):
  ComposerPendingApprovalPanel + actions (CHECK first — pi tool-approval may already
  flow through `extension_ui_request`, i.e. covered by the user-input panel),
  TerminalContextInlineChip / pending-terminal-contexts, the donor attachmentStore
  (in-memory image flow has no gap it fixes). ExpandedImageDialog focus-trap → S19 a11y.

### Slice 18 — Checkpoints & rollback

- Donor: `apps/server/src/checkpointing/`, plus `readThread`/`rollbackThread` semantics
  from their adapter contract mapped onto pi session files + git worktree state.
- Per-turn checkpoint capture; roll a session back to a prior turn (transcript + files).
- **Largest feature slice.** Depends on diff engine (Slice 9) and likely triggers the
  SQLite persistence follow-up from Slice 6. Needs a careful pi-side design: pi owns
  the session file; we own worktree state. Design doc before code.
- Design: `docs/checkpoints-design.md`. Split into S18a (capture) + S18b (rollback + UI).
- **S18a LANDED (2026-07-22, 68a1d49).** Per-turn capture at the idle boundary
  (forked in session scope — idle receipt intact): conversation = wholesale copy of pi's
  session file (never parsed); workspace = hidden git ref via a throwaway GIT_INDEX_FILE
  tree-capture that provably does NOT disturb the user index/worktree (tested); non-git
  cwd → conversation-only; retention-capped; `checkpoints_list` op; metadata in
  persistence (NO SQLite — not needed at this scale, documented). Review minor fixed:
  crash-safe prune order (flush index before deleting files/refs). No web UI, no
  rollback — S18b.
- **S18b LANDED (2026-07-22, eae9278). PHASE 8 COMPLETE.** checkpoint_rollback restores
  both halves via the resume() path (git-restore the worktree from the target's hidden
  ref → copy the conversation snapshot back over pi's session file → relaunch), with the
  physical restore run INSIDE the same per-session serialize lock that guards capture (no
  forked idle capture can snapshot a half-restored worktree) and a FORCED safety
  checkpoint of the pre-rollback state first (so the rollback is itself undoable). Abort
  on git-failure: a target that HAS a ref but fails to restore relaunches from the
  ORIGINAL session file and rejects with a clear error rather than leaving a
  files-old/conversation-new half-state; a non-git target restores conversation only
  (`filesRestored:false` → distinct info toast). Web CheckpointsPanel = right-hand rewind
  timeline (newest first) + destructive confirm; idle-gated (Restore disabled while a
  turn runs; an in-flight turn closes an open confirm); rejected rollback → error toast.
  e2e (2 turns write files → roll back to turn 1 → turn-2 file gone AND conversation
  truncated) is the END-TO-END guard for the "pi flushed before snapshot" invariant.
  Review minors fixed inline: abort-on-git-failure (was swallowed as a benign
  conversation-only rollback), idle-gate, error toast on rejection.

## Phase 9 — Agent Deck differentiators on the new substrate

Existing functionality survives the migration; these slices _deepen_ it using the new
machinery — this is where "their chrome, our core" pays off.

### Slice 19 — Skills/agents/prompts management re-skin + a11y batch

- Re-home the Skills screens (import, sync, conflict sheets), AgentEditor, scope chips
  onto the new design language (palette entries, command surfaces, file-preview reuse).
  No behavior change — presentation + wiring only.
- **LANDED (2026-07-22, 86e115d).** Re-skin AUDITED (adversarial workflow) as ALREADY
  SATISFIED: the Skills/Agents/Prompts screens + AgentEditor + ScopeChip already speak
  the migration design language (same token vocabulary border/surface/text/selection-fill,
  the `text-[10px] font-semibold uppercase tracking-wider text-text-muted` group-label
  idiom byte-for-byte with CommandPalette, rounded-xl selection-fill/stroke row cards,
  `rounded-xl border-border-subtle bg-surface-elevated` detail cards, capsule chips,
  centered muted empty states). materialGap=false — a re-skin would be churn/risk against
  working tested code; the `design-system/components/App*` primitives are DEAD (0-1
  consumers) pre-migration scaffolding, NOT the design language. So the slice landed the
  deferred A11Y BATCH instead: (1) `lib/platform.ts` detectPlatform() centralizing the
  deprecated navigator.platform behind navigator.userAgentData.platform (3 call sites;
  empty-value coalesce so "" can't flip ⌘/Ctrl; unit-tested); (2) `lib/useFocusTrap.ts`
  reusable modal trap (initial focus + Tab wrap + restore-to-opener, optional
  initialFocusRef) adopted in ExpandedImageDialog (backdrop → tabIndex=-1, focus → visible
  close, killing a viewport-ring + Space/Enter insta-close footgun the reviewer caught);
  (3) CommandPalette Tab trapped on the input (arrow-key model — handler on the input;
  comment+e2e corrected). AgentEditSheet already had a complete trap — left unchanged.
  Review: 0 blocker/0 major; 4 minors/nits all fixed. Gates green (web unit/e2e/visual);
  test:pi orthogonal (web-only diff) — CI real-pi matrix is the authoritative check.
  NOTE: no jsdom test env → the useFocusTrap DOM behavior is covered by the palette
  Tab-trap e2e; a dedicated image-dialog focus e2e was deferred (image-seeding
  disproportionate for a minor).

### Slice 20 — Sessions ⇄ worktree ⇄ diff integration

- Wire our existing worktree isolation + Merge action into the diff panel and branch
  toolbar patterns (donor: `BranchToolbar*`, `GitActionsControl*`) so worktree sessions
  get first-class review-then-merge flow.
- **LANDED (2026-07-22, 2cbb495). PHASE 9 COMPLETE.** Scoped first (Explore agent): the
  SERVER merge flow was already COMPLETE + tested (POST /sessions/:id/merge auto-commits
  worktree work, checks commits-ahead, `git merge --no-ff` into the source branch, 400/409
  errors; session-worktree.pi.test.ts). And because worktree work stays UNCOMMITTED until
  merge (checkpoints use hidden refs, not branch commits), the existing Slice-9
  working-tree-vs-HEAD diff ALREADY shows the complete branch delta — it IS the review
  surface. So this was a ~70% WIRING slice: a branch toolbar in the DiffPanel for worktree
  sessions ("<branch> → <source>" + "Merge to <source>", testid diff-merge), gated on the
  gitAutomation setting + idle-gated (mid-turn merge would auto-commit a half-written tree).
  Shared `wsBridge.mergeWorktreeSession` used by BOTH the toolbar and GitScreen (unified
  toast); merge STAYS on the HTTP route (git-route-family consistency — NOT moved to RPC).
  Review: 0 blocker, 0 confirmed-major (the one major — post-merge SessionDiff cache
  staleness on resubscribe — was verified real but transient; FIXED properly: the merge
  route now drops the server diff cache via new `ctx.dropDiffCache`, so a resubscribe
  recomputes the empty set instead of replaying the stale one). Also fixed: GitScreen merge
  button idle-gated (was the lone ungated merge surface). DEFERRED (branch-vs-base gap, →
  S23): committed-in-worktree work (agent/terminal `git commit` inside the worktree) is
  merged but NOT shown in the working-tree diff — a true review needs a `sourceBranch...
worktreeBranch` diff base (new git primitive + diff-scope contract); also a shared live
  settings store so the gitAutomation gate tracks Preferences without reload (self-corrects
  on reload today). Tests: worktree-merge.spec.ts (full click→merge→verify incl. `git log
main` Merge commit) + diff-worktree-toolbar visual baseline (masked dynamic branch). All
  gates green (typecheck, lint, format, web unit, server unit 305, e2e, visual); CI real-pi
  matrix validates the unchanged merge route.

## Phase 10 — Remote & multi-device

### Slice 21 — Remote access, simple story first

- Option (a), default: bind configurably + auth token + docs for `tailscale serve` /
  LAN access. Zero donor code; hardening only (auth on WS + REST, CORS).
- Option (b), only if (a) proves insufficient: port their `relay/` + `packages/ssh` /
  `packages/tailscale` stack. **Project-sized — treat as its own plan.**
- Mobile app: explicitly out of scope for this plan; revisit after Phase 10.
- **PARKED (2026-07-22) pending a USER decision — the one security-sensitive slice.**
  The server currently binds loopback-only (server.ts:710 `host ?? "127.0.0.1"`) with NO
  general WS/REST auth or CORS (only the pi-bridge token exists). S21 opens a real remote
  attack surface, and the correct design depends on the user's deployment model, which only
  they can supply. Questions to resolve before building: (1) deployment model — tailscale
  serve (server stays loopback, tailscale terminates), a bound LAN address with a token, or
  both? (2) token delivery/storage — env var, generated-and-shown-once in settings, or a
  settings-file secret? (3) default posture — keep loopback-only default and make remote
  strictly opt-in (recommended)? (4) CORS — same-origin only, or an allowlist? Per the
  standing goal, S21 is parked and the loop CONTINUES with the independent S22 (desktop
  polish) first; S21 resumes once the user answers.

## Phase 11 — Desktop & distribution polish

### Slice 22 — Desktop polish

- Auto-update (electron-updater per their desktop app), native notifications on
  turn-complete / approval-needed, dock/taskbar badges.
- Donor: `apps/desktop/` patterns; independent of all feature slices.
- **Split after scoping (2026-07-22): S22a (buildable now) + S22b (parked).** The desktop
  shell today (apps/desktop/main.js) imports only `app, BrowserWindow, dialog, ipcMain,
Menu, shell` — no Notification/Tray/setBadgeCount, no focus tracking, and it spawns the
  server via `pnpm --filter … dev` (a dev-checkout shell, NOT a packaged bundle). There is
  no electron-builder/forge, no `.github` release automation, and no code-signing config.
- **S22a — notifications + badges: LANDED (2026-07-22, 041145c).** Native OS notifications
  on the active session's turn-complete (`agentStatus` running→idle) and approval-needed
  (`openQuestion`), plus a dock/taskbar badge via `app.setBadgeCount`. The web forwards
  semantic attention events over a new `signalAttention` preload bridge; MAIN owns the
  `!isFocused()` gate + badge counter (increment while unfocused, clear on focus) so it's
  testable via the `_electron` `app.evaluate` spy pattern. Scoped to the ACTIVE session
  (agentStatus is active-session-only); background-session notifications deferred. Review:
  0 blocker/major; fixes applied — edge-detection extracted to a PURE
  `attentionEventsFor(prev, next)` + 8 unit tests (closed the untested-hook gap);
  approval-needed now fires on any new distinct question id (not only null→non-null);
  documented the harmless focus-gated rollback edge. Gates green (web unit 54, desktop e2e
  6/6 incl. a Notification/setBadgeCount spy test asserting focus clears the badge).
- **S22b — auto-update + packaging/signing: PARKED (2026-07-22) pending USER/infra
  decisions.** electron-updater needs three things the repo has zero of, and they are not
  self-contained code tasks: (1) a packaging tool (electron-builder) AND a bundled-server
  packaging story (main.js currently spawns `pnpm dev` — no bundle exists); (2) an update
  feed (GitHub Releases vs S3 vs generic server); (3) Apple Developer ID + Windows
  code-signing certificates (procurement + secrets — a cost/credential decision only the
  user can make). Resume once the user decides the packaging/feed/signing story.

## Phase 12 — Final parity audit (goal completion gate)

### Slice 23 — Parity audit vs the macOS app and t3code

- Systematic audit, feature by feature, against two checklists:
  (a) the native macOS Agent Deck app (`../agent-deck` — README, docs, and the
  Swift sources are the spec): agents, skills (import/sync/conflicts), prompts,
  scopes/assignment, sessions/transcripts, worktrees + merge, loops, memory,
  MCP, issues, git actions incl. release, doctor, onboarding, provider login;
  (b) the t3code feature set adopted in Phases 4–11: terminal, diffs + review
  comments, open-in-editor, file nav, palette, preview browser + automation,
  composer upgrades, checkpoints, remote story, desktop polish.
- Every gap becomes a fix slice before the goal is considered DONE.
- Exit gate: full suite + `test:pi` + visual gate green, and both checklists
  fully ticked in a written audit report committed to docs/.
- **AUDIT COMPLETE (2026-07-22). Report: `docs/parity-audit.md`.** Ran as a 12-agent
  workflow (11 parallel per-area auditors vs the macOS Swift sources + the adopted t3code
  set, then a synthesis). **Verdict: has-blockers** — the load-bearing core of every area
  is ported + tested and the t3code-adopted set is the most complete, but the port is NOT
  yet at full parity: **1 BLOCKER** (Loops ships only the single-agent engine — the editor
  advertises Maker+Checker/Pipeline/Parallel/Triage/Human-Approval but every non-single
  structure silently runs single-agent; verified: `loopEngine.ts` is the native
  `launchSingleAgentLoop` minimal form only, the other 4 engines were never ported while
  the UI/route enum still offer them), plus a band of majors (agent avatars + per-project
  assignment matrix; skills import-preview sheet + folder scan + per-file conflict
  detection [data-loss]; session per-message fork/rerun; semantic-memory abstain gates +
  "Memory Recalled" card; MCP add-http/edit/OAuth-auto-capture/assignment; Issues
  reply/reopen/rich-context; provider API-key sign-in + session-independent model catalog;
  Doctor in-app pi install/update + Web Access card; desktop BACKGROUND-session
  notifications) and a long minor/cosmetic tail (mostly documented deliberate reductions).
  The report catalogs all 110 gaps + 11 recommended fix-slices (A–K, severity-ordered). All
  gaps + fix-slices AWAIT USER PRIORITIZATION — this is a Linux/Windows port, so which
  native-macOS features to build is the user's call (some may be undesired; avatar AI-gen +
  Apple Foundation Model are intentionally macOS-only). The Loops blocker specifically needs
  a user decision: IMPLEMENT the 4 missing engines, or restrict the UI/enum to singleAgent
  so the app stops advertising what it doesn't run.

---

## Standing goal (armed 2026-07-20)

Autonomous completion of ALL slices (S3–S23), one workflow per slice, in
dependency order: implement → adversarial review → fix → full gates
(typecheck, lint, unit, `test:pi`, visual) → **commit the validated slice** on
`agent-cross-plat` (commits only, never push) → update this doc's slice status →
launch the next slice. Visual baselines are extended as new UI lands (each
web-facing slice adds/updates its screens via `test:visual:update`, reviewed).
Stop conditions: all slices landed and the Slice 23 audit is clean, OR a
blocker only the user can resolve (which is reported and parked, continuing
with non-dependent slices where the graph allows).

---

## Dependency graph

```
S1 contracts ─┬─▶ S3 runtime+pushbus ─▶ S4 pi-host ─▶ S5 session-manager ─▶ S6 persistence
S2 split ─────┘                                                                │
                                        S7 transport swap ◀───────────────────┘
                                              │
        ┌─────────────┬───────────────┬───────┴───────┬──────────────┐
     S8 terminal   S9 diff engine   S13 file tree   S14 palette   S22 desktop
        │             │    │
        │      S10 diff panel ─▶ S11 open-in ─▶ S12 review comments
        │             │
     S15 preview ─▶ S16 preview automation        S17 composer (any time after S7)
                      │
               S18 checkpoints (after S9, S6-followup)
                      │
     S19 skills re-skin (after S14)      S20 worktree⇄diff (after S10)
     S21 remote (any time after S7)
```

## Rough effort (agent-assisted, one slice landed before the next starts)

| Phase                 | Slices  | Order of magnitude                           |
| --------------------- | ------- | -------------------------------------------- |
| 0–1 contracts + split | S1–S2   | ~1 week combined                             |
| 2 Effect services     | S3–S6   | ~2–3 weeks (S4/S5 dominate)                  |
| 3 transport           | S7      | ~1 week                                      |
| 4 terminal tracer     | S8      | ~3–5 days                                    |
| 5 change review       | S9–S12  | ~2–3 weeks                                   |
| 6 files & navigation  | S13–S14 | ~1 week                                      |
| 7 preview browser     | S15–S16 | ~1.5–2 weeks                                 |
| 8 session UX parity   | S17–S18 | ~2–3 weeks (S18 dominates; design doc first) |
| 9 differentiators     | S19–S20 | ~1 week                                      |
| 10 remote (option a)  | S21     | days                                         |
| 11 desktop polish     | S22     | ~3–5 days                                    |

Substrate + terminal: ~5–6 weeks. Full roadmap through Phase 11: roughly 3–4 months of
sequential slices — parallelizable after S7 where the graph allows (e.g. S13/S14/S22
alongside Phase 5).

Priority call if time pressure hits: Phases 5 and 7 are the visible "slickness" payoff
(diffs + preview browser); Phase 8's checkpoints is the deepest lift and can slip
without blocking anything except itself.

## Reference-clone hygiene

- Keep a pinned local clone of t3code for reading (currently at commit 53e3c98); never
  vendor its `.repos/` directory; never copy code without noting origin file in the
  commit message (MIT attribution: keep their license text alongside any near-literal
  lifts).
- Do not chase upstream. Re-sync the reference clone only when starting a new donor
  slice, and diff only the donor files.

---

## Post-audit user-requested features (L-series, 2026-07-22)

Beyond the S3–S23 migration plan, the user asked for an in-app BROWSER + a
click-to-select element inspector + a tabbed workspace (Chrome-style, replacing
the side-by-side tool panels). Decided (user): workspace-tools tabs (chat fixed
left; terminal stays the bottom drawer); browser as a DESKTOP (Electron webview)
feature — web build falls back to a placeholder; "deal with the web later."

- **Slice L1 — Tabbed workspace pane: LANDED (2026-07-22, 917be39).** Ported
  t3code RightPanelTabs/rightPanelStore. The four side-by-side tool asides
  (Diff/Files/Preview/Checkpoints) become tabs in one right pane with a
  Chrome-style tab strip + "+" menu + right-click context menu; per-session
  `workspaceTabs` store model; KEEP-ALIVE (inactive tab bodies hidden not
  unmounted, so the Preview's live dev-server iframe survives switches); header
  toggles → open/activate/close the tab; DeckPanel + terminal untouched. Review
  0 blocker/major; ARIA + diff-placeholder nits fixed. 4 visual baselines
  regenerated.
- **Slice L2 — Desktop general browser: LANDED (2026-07-22, 15d93ea).** A real
  Electron `<webview>` browser as a singleton "browser" workspace tab (Option B —
  additive; internal Chrome-style page-tabs inside the panel, capped at 8,
  keep-alive). Toolbar (back/forward/reload/stop, address bar, title), stock
  Chrome UA (Google-login workaround), `persist:agentdeck-browser` partition.
  Desktop-only (web build → placeholder; "+" gated on isElectron). Security pass
  (biggest threat-model change — arbitrary untrusted content in-app): fixed a
  BLOCKER (guest handed non-http(s) URLs to shell.openExternal → RCE) + a MAJOR
  (no nav clamp → file:// + unguarded agent-deck REST reachable) by dropping
  non-http(s) popups and a guest will-navigate blocking file: + the control-plane
  origin. FOLLOW-UP (recommended, server-side): mirror the WS local-origin guard
  onto the REST mutating routes (defense-in-depth vs guest CSRF). desktop e2e 8/8.
- **Slice L3 — Click-to-select element inspector: IN PROGRESS.** Inject a picker
  into the browser webview (via `webview.executeJavaScript` returning a
  click-resolved Promise — NO guest preload / NO contextIsolation weakening, so
  L2's hardening is preserved) so clicking an element captures its selector + the
  page URL into the EXISTING element-context path (buildPendingElementContext →
  addElementContext) that feeds the composer. Restores the point-and-click
  automation the sandboxed loopback iframe couldn't do (Slice 16's manual subset).
