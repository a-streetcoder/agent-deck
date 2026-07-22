# Agent Deck Cross-Platform — Delivery Roadmap

Living plan for what ships next. Curated for a **Linux/Windows** port — some
native-macOS features are intentionally cut. The canonical gap catalog is
[`docs/parity-audit.md`](./parity-audit.md); this file sequences the work and
records the KEEP / TRIM / CUT / DEFER decisions.

Decisions here are proposals — veto or reorder any row.

---

## Now shipping

- **L4b — file editing + persist** _(in progress)_: files become editable with
  **debounced autosave** (no save button) through a guarded `file_write` op
  (path-containment + atomic write + on-disk conflict guard); plus **per-session
  persistence** of the browser page-tabs and open files so toggling a tool's
  workspace tab off/on restores them.

---

## Track 1 — Technical follow-ups (near-term, small)

Do these right after L4b lands. Small, mostly local, high polish/security value.

1. **CodeMirror dark theme** — the editor content ignores the app theme
   (CodeMirror's default light theme paints white). Set `theme="none"` so our
   dark surface/tokens show, restore the edit cursor, add a light-mode token
   palette, and a soft-wrap toggle. Languages are fine — 143 via
   `@codemirror/language-data` incl. TypeScript (`.ts`); the white theme just made
   code look broken. Verify `.ts` renders + highlights after the fix. _(quick)_
2. **Preview panel renders nothing for frame-blocking dev servers** — the preview
   uses a sandboxed `<iframe>`, so a dev server that sends `X-Frame-Options` /
   CSP `frame-ancestors` (Next.js, many others) refuses to be framed → white,
   even on loopback (`localhost:3000`). In the desktop build, switch the preview
   embed to a `<webview>` (like the L2 browser, which isn't iframe-limited) so
   localhost dev servers render; keep the iframe fallback for the web build.
   **Workaround today:** open `localhost:3000` in the **Browser** tab. _(small)_
3. **Server REST origin/CSRF guard** — the WS upgrade has a local-origin guard
   but the REST mutating routes don't; the in-app browser (L2) makes that
   reachable from arbitrary web content. Mirror the WS guard onto REST. _(small —
   do early; it's the one open security item)_
4. **S20 branch-vs-base diff** — the diff shows working-tree-vs-HEAD only, so a
   worktree's _committed_ changes (agent/terminal `git commit` inside the
   worktree) merge but aren't shown in review. Add a `sourceBranch...worktreeBranch`
   diff base. _(small–medium)_
5. **S19 image-dialog focus e2e** — the deferred a11y test for the expanded-image
   dialog. _(tiny)_
6. **Repo cleanup** — archive the now-superseded `docs/checkpoints-design.md`
   (S18 shipped) and verify the migration's transitional "legacy oracle"
   references are history-comments, not dead code. Keep git history; just tidy.
   _(tiny; run after L4b so it doesn't collide)_

---

## Track 2 — Parity (curated: KEEP / TRIM / CUT)

From the `docs/parity-audit.md` fix-slices A–K, filtered for a Linux/Windows port.

| Slice                            | Decision               | Priority          | Notes                                                                                                                                                                                                                                                          |
| -------------------------------- | ---------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A · Loops**                    | **SPLIT**              | P0 hon. / P3 eng. | _Now:_ restrict the structure picker to the single-agent engine that actually runs (stop advertising the 4 broken structures) — cheap, closes the "shipped-but-doesn't-run" defect. _Later (large):_ build the 4 missing engines + human-approval + artifacts. |
| **I · Skills per-file conflict** | **KEEP**               | P0                | **Data-loss**: a skill's reference-file edits are silently overwritten on sync (only SKILL.md is fingerprinted). Fix per-file fingerprinting. (The import-preview / folder-scan UX can trail as P2.)                                                           |
| **B · Providers**                | **KEEP**               | P1                | API-key sign-in (only OAuth today) + a session-independent model catalog (Models screen / onboarding picker are empty until a session exists).                                                                                                                 |
| **C · MCP**                      | **KEEP (trim)**        | P1                | Add http/remote server + edit + OAuth auto-capture (kill the paste-the-code UX — the loopback listener is dead code). Per-project MCP assignment can trail.                                                                                                    |
| **G · Memory**                   | **KEEP**               | P2                | Semantic abstain/qualification gates + a "Memory Recalled" transcript card with click-through.                                                                                                                                                                 |
| **J · Desktop bg notifications** | **KEEP**               | P2                | Completes S22a: notify/badge for **background** (non-active) sessions, and wire notification-click → navigate to the raising session.                                                                                                                          |
| **F · Sessions fork/rerun**      | **KEEP**               | P2                | Per-message fork via pi `/fork` + in-place rerun (edit-and-resend) + per-message hover actions.                                                                                                                                                                |
| **D · Issues**                   | **KEEP (optional)**    | P3                | Reply/comment, reopen, rich `<github-issue-context>` for Open-in-Pi. Only if in-app issues matter to you.                                                                                                                                                      |
| **H · Doctor**                   | **TRIM**               | P3                | Keep in-app pi install/update + the Web Access (Exa) card; the rest (GitHub connect, settings-files viewer) is nice-to-have.                                                                                                                                   |
| **E · Agents**                   | **TRIM → cut avatars** | P3                | KEEP the per-project assignment matrix + the missing subagent-config editor fields (portable, useful). **CUT** the avatar system — AI generation is Apple Image Playground (macOS-only); import-from-file is low value.                                        |
| **K · Minor/polish**             | **DEFER**              | —                 | Cherry-pick as needed; mostly cosmetic / deliberate reductions.                                                                                                                                                                                                |

---

## Track 3 — Deferred & logged (not scheduled)

Recorded so we don't lose them. Each needs a decision, or is large / low-value.

- **S21 — Remote access** — parked; needs your call on the deployment/auth model
  (tailscale vs LAN+token; token delivery; default posture; CORS).
- **S22b — Desktop auto-update** — parked; needs electron-builder packaging + a
  bundled-server story + an update feed + Apple/Windows code-signing certs.
- **Loops full multi-engine implementation** — P3; the largest single body of
  work, taken up after the Track-2 honesty fix.
- **Agent avatars (AI-gen)** — CUT (macOS-only Image Playground).
- **Parity minor/cosmetic tail** — deferred; see slice K + the audit's minor rows.

---

## Suggested order

1. **Ship L4b** (in progress).
2. **Track 1** in order (theme → REST guard → branch diff → a11y e2e) — quick, clears the security + polish debt.
3. **Track 2 P0**: Loops honesty fix + Skills per-file conflict (the two data-integrity items).
4. **Track 2 P1**: Providers, MCP.
5. **Track 2 P2**: Memory, desktop bg notifications, sessions fork/rerun.
6. **Track 2 P3 / Track 3**: as prioritized when we get there.
