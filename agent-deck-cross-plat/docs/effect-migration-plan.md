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

### Slice 6 — Persistence service

- `persistence.ts` behind a service interface; on-disk format unchanged.
- Optional follow-up (not this slice): SQLite via `@effect/sql-sqlite` per t3code —
  revisit when checkpointing (Slice 16) needs transactional turn snapshots.

- Exit gate for each Phase-2 slice: full suite + `test:pi` + streaming test.

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

## Phase 5 — Change review core

### Slice 9 — Diff engine (server)

- Donor: `apps/server/src/{vcs,sourceControl,review}/` shapes; extend our `git.ts`
  (worktree logic already exists) toward per-turn changed-file tracking and diff
  computation. Receipts for "diff finalized" per our existing receipts pattern.

### Slice 10 — Diff panel + changed-files tree (web)

- Donor: `DiffPanel.tsx`, `DiffPanelShell.tsx`, `DiffWorkerPoolProvider.tsx`,
  `chat/ChangedFilesTree.tsx`, `chat/DiffStatLabel.tsx`.
- Diff rendering in web workers; changed-files tree in the session view wired to the
  Slice 9 stream.

### Slice 11 — Open-in editor (VS Code / JetBrains / etc.)

- Donor: `apps/server/src/process/externalLauncher.ts`, `chat/OpenInPicker.tsx`,
  `JetBrainsIcons.tsx`.
- Open file/line from diff panel, changed-files tree, and transcript file references.
- Small slice; lands right after Slice 10 so diffs get "open in editor" immediately.

### Slice 12 — Review comments → composer

- Donor: `apps/server/src/review/`, `chat/ComposerPendingReviewComments.tsx`.
- Comment on a diff hunk; comments accumulate as pending composer context and are sent
  as a structured follow-up turn to pi.
- Depends on Slices 9–10.

## Phase 6 — Files & navigation

### Slice 13 — File tree + file preview

- Donor: `components/files/` (FilePreviewPanel), workspace file endpoints.
- Project file navigation panel + read-only preview (syntax highlight, images), gated
  to project root/worktree paths.

### Slice 14 — Command palette + keybindings

- Donor: `CommandPalette*.tsx`, `apps/server/src/keybindings.ts`,
  `KeybindingsUpdateToast.*`.
- Palette over sessions/projects/actions; user-editable keybindings persisted
  server-side; toast on binding conflicts after updates.
- Mostly client-side; server surface is the keybindings store.

## Phase 7 — Preview browser

### Slice 15 — Embedded preview surface + port discovery

- Donor: `apps/server/src/preview/`, `apps/web/src/components/preview/`
  (addBrowserSurface, openDiscoveredPort, previewActionBus),
  `ProjectScriptsControl.tsx` + `apps/server/src/{environment,project}/` script running.
- Run project dev scripts from the UI (processRunner), detect listening ports, open the
  dev server in an embedded preview panel; terminal links open in preview.
- Depends on terminal (Slice 8) for the script-output surface.

### Slice 16 — Preview automation → composer context

- Donor: `preview/PreviewAutomationHosts.tsx`, `previewAutomation*`,
  `chat/ComposerPreviewAnnotationCards.tsx`, `ComposerPendingElementContexts.tsx`.
- Point at an element / annotate a screenshot in the preview; annotation becomes a
  structured composer context card sent to pi with the next turn.
- This is a flagship "slick" feature — schedule demo time; it sells the migration.

## Phase 8 — Session UX parity

### Slice 17 — Composer upgrades

- Donor: `chat/Composer*` family — pending-approval panel + actions, pending-user-input
  panel (maps onto our existing `ui_response` pass-through), context window meter,
  file tag chips, terminal context chips, expanded image previews,
  `apps/server/src/attachmentStore.ts` for attachments.
- Split into 2–3 landings if reviews get large; each chip/panel is independent.

### Slice 18 — Checkpoints & rollback

- Donor: `apps/server/src/checkpointing/`, plus `readThread`/`rollbackThread` semantics
  from their adapter contract mapped onto pi session files + git worktree state.
- Per-turn checkpoint capture; roll a session back to a prior turn (transcript + files).
- **Largest feature slice.** Depends on diff engine (Slice 9) and likely triggers the
  SQLite persistence follow-up from Slice 6. Needs a careful pi-side design: pi owns
  the session file; we own worktree state. Design doc before code.

## Phase 9 — Agent Deck differentiators on the new substrate

Existing functionality survives the migration; these slices _deepen_ it using the new
machinery — this is where "their chrome, our core" pays off.

### Slice 19 — Skills/agents/prompts management re-skin

- Re-home the Skills screens (import, sync, conflict sheets), AgentEditor, scope chips
  onto the new design language (palette entries, command surfaces, file-preview reuse).
  No behavior change — presentation + wiring only.

### Slice 20 — Sessions ⇄ worktree ⇄ diff integration

- Wire our existing worktree isolation + Merge action into the diff panel and branch
  toolbar patterns (donor: `BranchToolbar*`, `GitActionsControl*`) so worktree sessions
  get first-class review-then-merge flow.

## Phase 10 — Remote & multi-device

### Slice 21 — Remote access, simple story first

- Option (a), default: bind configurably + auth token + docs for `tailscale serve` /
  LAN access. Zero donor code; hardening only (auth on WS + REST, CORS).
- Option (b), only if (a) proves insufficient: port their `relay/` + `packages/ssh` /
  `packages/tailscale` stack. **Project-sized — treat as its own plan.**
- Mobile app: explicitly out of scope for this plan; revisit after Phase 10.

## Phase 11 — Desktop & distribution polish

### Slice 22 — Desktop polish

- Auto-update (electron-updater per their desktop app), native notifications on
  turn-complete / approval-needed, dock/taskbar badges.
- Donor: `apps/desktop/` patterns; independent of all feature slices.

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
