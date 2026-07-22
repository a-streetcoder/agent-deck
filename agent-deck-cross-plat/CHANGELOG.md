# Changelog

History of `agent-deck-cross-platform` — the cross-platform (Linux/Windows) port
of the native macOS Agent Deck, rebuilt on an **Effect** substrate with
**t3code**-inspired features, all on the **pi** engine.

Detailed per-slice records: [`docs/effect-migration-plan.md`](./docs/effect-migration-plan.md).
Remaining backlog + cuts: [`docs/roadmap.md`](./docs/roadmap.md).
Parity gaps vs the macOS app: [`docs/parity-audit.md`](./docs/parity-audit.md).

---

## Attribution & inspiration

This project stands on three sources — recording them so the lineage is never lost:

- **[t3code](https://github.com/pingdotgg/t3code) (MIT)** — the primary
  **inspiration** for the cross-platform UI + developer-tool features. We did
  **not** fork it, run their server, or adopt their engine: we rebuilt our own
  server/client on **Effect** _following their architecture_, and ported their
  features as **donor pairs** — reading a t3code component and re-expressing it on
  our substrate + pi, adapting freely rather than lifting verbatim. A pinned
  reference clone (commit `53e3c98`) was kept for reading only. Per MIT, keep
  t3code's license text alongside any near-literal port.
- **Native macOS Agent Deck** (`../agent-deck`, our own prior app) — the
  **feature spec** for everything that is _ours_: skills (import/sync/conflicts),
  agents, scopes, prompts, loops, memory, MCP, issues, git actions incl. the
  release action, doctor, onboarding, provider login, worktree isolation + merge.
- **pi** — the coding-agent engine (JSONL RPC over stdio). The only engine; never
  replaced, and its session-file format is treated as an opaque blob we copy but
  never parse.

### What we took from t3code (donor → ours)

| Area                        | t3code donor                                          | Our adaptation                                                                                                                                                      |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Server layer composition    | `serverLayers`                                        | `apps/server/src/runtime.ts` (ManagedRuntime + Layers)                                                                                                              |
| Terminal state wiring       | terminal state hooks                                  | `wsBridge` terminal surface + `TerminalDrawer` (S8)                                                                                                                 |
| Diff / changed-file model   | diff plumbing                                         | `services/diff.ts` + `DiffPanel` (S9–S10)                                                                                                                           |
| Preview (loopback dev-srv)  | `openDiscoveredPort` / `usePreviewSession`            | `PreviewPanel` loopback embed (S15)                                                                                                                                 |
| Checkpoints (worktree half) | `checkpointing/CheckpointStore` (hidden git refs)     | `services/checkpoints.ts` + `CheckpointsPanel` (S18)                                                                                                                |
| Command palette / keybinds  | palette + keybinding model                            | `CommandPalette` + `keybindings` (S14)                                                                                                                              |
| Tabbed workspace            | `RightPanelTabs` + `rightPanelStore` (`byThreadKey`)  | `components/workspace/*` + `workspaceTabs` store (L1)                                                                                                               |
| Desktop browser             | `HostedBrowserWebview` + `preview/WebviewPreferences` | `components/browser/BrowserPanel` + `main.js` guest hardening (L2) — WebContentsView compositing, Effect Manager, and react-grab picker deliberately **not** ported |
| Markdown preview toggle     | `filePreviewMode.ts`                                  | `components/files/filePreviewMode.ts` (L4a)                                                                                                                         |
| Atomic file write           | atomic temp-write + rename                            | `services/files.ts` `writeFile` (L4b)                                                                                                                               |
| Debounced autosave          | `fileSaveCoordinator`                                 | `lib/fileSaveCoordinator.ts` (L4b)                                                                                                                                  |

### Notable divergences (where we did NOT follow t3code)

- **`packages/domain` stays plain TS**, wrapped not ported to Effect.
- **Fastify kept** as the HTTP shell (handlers call into a ManagedRuntime) instead
  of `@effect/platform` HttpServer.
- **Preview element automation** is a documented manual-selector subset (our
  loopback preview is a sandboxed cross-origin iframe that can't be injected);
  the real point-and-click inspector only became possible on the L2 `<webview>`.
- **Browser guest** uses `contextIsolation: true` (t3code uses `false` for their
  picker preload) — security preserved.

### Key libraries

CodeMirror 6 + `@codemirror/language-data` (editor/highlighting), shiki + marked +
DOMPurify (markdown), node-pty (terminal), Electron (desktop shell), Effect
(server substrate). Their licenses ship with the dependency tree.

---

## Unreleased — post-audit feature work (L-series), 2026-07-22

New workspace features requested after the parity audit.

### Added

- **Tabbed workspace pane (L1)** — the right-side tools (Diff / Files / Preview /
  Checkpoints) became Chrome-style **tabs** in one pane with a `+` / close /
  right-click menu, replacing the side-by-side stacking. Per-session tab state,
  keep-alive (a background tab's live view survives). Ported from t3code's
  RightPanelTabs.
- **In-app browser (L2)** — a real Electron `<webview>` general browser as a
  workspace tab: address bar, back/forward/reload/stop, multiple page-tabs,
  loads **any** site (not iframe-limited). Hardened guest (sandbox,
  contextIsolation, no inherited preload) + popup/navigation clamps.
- **Click-to-select element inspector (L3)** — pick an element in the browser →
  its selector/tag/text/URL become composer context. `executeJavaScript`
  injection (no guest preload); the returned data is sanitized against a
  prompt-injection break-out.
- **File viewer upgrade (L4a)** — side-by-side **tree \| content** with
  **multi-file tabs**, **resizable** panels (sidebar / workspace pane /
  tree–content, persisted widths), **CodeMirror** syntax highlighting (a lazy
  chunk), and a markdown **raw/preview** toggle.
- **File editing + autosave (L4b)** — editable files with debounced **autosave**
  (no save button) via a guarded `file_write` op (path-containment + atomic write
  that preserves file mode + an on-disk **conflict guard** so an agent edit
  underneath you isn't clobbered); **per-session persistence** of the browser
  page-tabs and open files (survive toggling the tool off/on). Editor now renders
  on the app's dark theme.
- Layout: content ordered **next to the chat** (chat → content → tree); the Files
  tab is **tree-only** until a file is opened.

---

## Migration — Effect substrate + t3code feature port (S1–S23), 2026-07-19 → 2026-07-22

Rebuilt the server/client on Effect (following t3code's architecture) and ported
t3code's UI/features onto the pi engine, preserving Agent Deck's own features.

### Phase 0–3 — Effect substrate (S1–S7)

- Effect-Schema **contracts** package (golden-fixture parity vs the old zod
  schemas); server **decomposition** (server.ts 3,896 → 597 lines, route modules);
  Effect **services** — PushBus, scoped **PiHost** (acquireRelease + tree-kill,
  Deferred RPC, JSONL stream), **SessionManager**, **Persistence**; the transport
  **cutover** to Effect-RPC-over-WebSocket (`/rpc`).

### Phase 4–7 — t3code feature ports (S8–S16)

- **Terminal** drawer (node-pty over the RPC transport); **diff** engine + panel
  (per-session changed-file tracking, unified view); **open-in-editor** (20-editor
  detection); **review comments**; **file navigation** tree; **command palette** +
  user **keybindings**; dev-server **preview browser** (loopback-only sandboxed
  embed) + a documented manual element-automation subset.

### Phase 8 — Session UX (S17–S18)

- **Composer** upgrades (composer-anchored pending-input panel, file-tag chips,
  expanded-image dialog); per-turn **checkpoints** + destructive **rollback**
  (two halves — pi's session file copied wholesale + a hidden git ref of the
  worktree; abort-on-git-failure keeps the halves consistent).

### Phase 9 — Differentiators (S19–S20)

- **Accessibility** batch (command-palette + dialog focus traps, deprecated
  `navigator.platform` centralized); worktree **review-then-merge** flow wired
  into the diff panel (idle-gated; server-side diff-cache invalidation on merge).

### Phase 11 — Desktop (S22a)

- Native OS **notifications** on turn-complete / approval-needed + dock/taskbar
  **badges**, focus-gated (main-process owned, so testable).

### Phase 12 — Parity audit (S23)

- Feature-by-feature audit vs the macOS app + the adopted t3code set →
  [`docs/parity-audit.md`](./docs/parity-audit.md). Verdict: **has-blockers**
  (Loops advertises 6 run structures but only single-agent runs); 110 gaps
  cataloged into 11 fix-slices.

### Parked (pending user decisions)

- **S21** remote access (deployment/auth model); **S22b** desktop auto-update
  (packaging + update feed + code-signing).
