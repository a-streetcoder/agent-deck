# Agent Deck Cross-Platform — Final Parity Audit (Slice 23)

**Date:** 2026-07-22
**Scope:** Cross-plat port (`agent-deck-cross-plat`) audited against (a) the native macOS Agent Deck Swift app and (b) the adopted t3code feature set (Phases 4–11).

---

## Executive verdict

The cross-plat port is **substantially at parity on the load-bearing core of every area**, but it is **NOT fully at parity**, and it carries **one blocker**. Modulo the two parked slices (S21 remote, S22b auto-update), the honest status is:

- **One blocker:** the **Loops** feature ships only a single-agent run engine. The editor lets a user pick Maker+Checker, Agent Pipeline, Parallel Agents, Discovery/Triage, or Human Approval, but every non-single-agent structure **silently degrades to single-agent** at runtime (`apps/server/src/loopEngine.ts:137-203` has one code path; `apps/server/src/routes/loops.ts:158-162` always calls single-agent). A saved Maker+Checker loop runs with no checker. This is a functional feature the UI advertises but the engine does not deliver.
- **A band of major gaps** where whole native sub-surfaces are absent or half-built: agent **avatars** and the **per-project agent-assignment matrix**; the skills **import preview/selection sheet** and **folder-scan local import**; per-message **fork / rerun / fork-as-agent-chat** in sessions; the **semantic-memory abstain gates** and **"Memory Recalled" transcript card**; MCP **add-http / edit / OAuth auto-capture / per-project assignment** and Issues **reply / reopen / rich Open-in-Pi context**; provider **API-key sign-in** and the **session-independent model catalog**; Doctor **in-app pi install/update** and the **Web Access card**; preview **element inspector**; and desktop **background-session notifications + badge**.
- **A long tail of minor/cosmetic gaps** that are mostly documented, deliberate reductions.

The t3code-adopted set (terminal, diffs, review comments, open-in-editor, file nav, command palette, composer, checkpoints, preview, desktop notifications) is the **most complete and internally coherent** part of the port — fully wired end-to-end with dedicated e2e specs — and its remaining gaps are almost all documented deferrals rather than broken wiring.

**Bottom line:** the happy paths work end-to-end and are tested, but the port is not yet feature-complete against the native spec, and the Loops multi-structure engine must ship before "parity" can be claimed.

---

## Per-area summary

### macOS-parity areas

**Agents** — Core CRUD, builtin diff-override + reset, rename with default re-point, enable/disable, TOCTOU-safe writer, and the four-scope sectioned list are all present. Gaps: the entire **avatar system** is absent (only a scope-tinted paperplane glyph, `AgentAvatar.tsx:28-42`); the **per-project agent-assignment matrix** (built for skills/prompts, never applied to agents) and **per-project builtin disable** are missing; a swath of **subagent-config fields** (defaultExpectedOutcome, defaultProgress, interactive, output, defaultReads, maxSubagentDepth) can't be edited; editor UX uses free-text comma inputs vs native live pickers.

**Skills** — The git-repo pipeline (source parsing, persistent clone + provenance, ls-remote check, ff update, Keep-Mine/Take-Remote) genuinely works. Gaps: the native **import sheet with per-skill selection** is entirely absent (cross-plat force-imports every skill from one URL); **local import only accepts a single `.md`** (no folder scan, assets dropped); **conflict detection is SKILL.md-hash-only**, so edits to reference files are silently overwritten on update (a data-loss gap).

**Prompts + scopes/assignment** — Full CRUD, global-vs-project scoping with global-first resolution, per-project + All-Projects assignment, and slash-command insertion are ported and e2e-tested. Gaps are all in the richer native discovery model: no Library / Builtin(+disable) / Package / Settings sections, no search box, argument-hint frontmatter is preserve-only (uneditable), and no import-external-prompt path.

**Sessions / transcripts / fork / resume** — Lifecycle (create with worktree isolation, resume with history+plan restore, rename, delete-with-cleanup, merge, search, live state) is solid; the transcript reducer renders streaming/thinking/tool/subagent/supervisor faithfully. Biggest gap: **fork collapses to a whole-file "Duplicate" at HEAD** — no per-message fork via pi `/fork`, no **rerun (edit-and-resend)**, no **fork-as-agent-chat**, no provenance/recap card, no per-message copy/fork buttons.

**Worktrees + merge + Git incl. release** — Strong parity: worktree create, review-then-merge (idle-gated), status/commit/push, AI commit-message, and the generalized Release action (preflight → AI notes → atomic tag-and-push with rollback) all track the native services. Gaps are secondary: session-delete keeps the branch (native force-deletes), no keepWorktreeAfterMerge toggle, no explicit pre-merge parent-clean guard, merge conflict collapses to a generic 409, release preflight drops the remote-sync (ahead/behind) gate.

**Loops** — **BLOCKER area.** Loop Bank CRUD, `.loop.md` persistence, and the single-agent iterate-until-validation engine are at parity. Everything else is absent: the four other run engines, structure-specific config, launch context, per-iteration artifacts, worktree apply/discard, human-approval pause/resume, session/transcript integration (runs in a hidden throwaway session), project availability/assignment, and builtin loops.

**Memory** — Strong core: project-scoped store, all types/statuses with injection eligibility, secret scanning, launch + per-turn injection, the three bridge tools, and a lexical+fuzzy recall that correctly abstains. Gaps: the **semantic embedder path lacks native's abstain/qualification gates** (injects top-N for any query); there is **no "Memory Recalled" transcript card** and no click-through from memory cards; the data model drops useCount/lastUsedAt; UI drops tags editing, detail view, bulk stale cleanup, and the pause toggle.

**MCP + Issues** — Happy path covered (list servers with live status + tools, add stdio, refresh, remove, http OAuth; issues list with facets, detail, close). Gaps: MCP **add is stdio-only** (no http via UI, so OAuth is unreachable normally), **no edit**, **OAuth uses manual paste-the-code against a dead loopback port** (`mcpLoopback.ts` is unwired dead code), **no per-project assignment**. Issues: **no reply/comment posting, no reopen**, one-line Open-in-Pi vs native's rich `<github-issue-context>`, no relationships, thinner detail pane.

**Doctor + Onboarding + Provider login** — Doctor probe (exceeds native by adding node/bash preflights), phased onboarding, and the interactive OAuth relay are production-quality and tested. Gaps: providers are **OAuth-only — no API-key sign-in** and most providers (OpenAI/Google/OpenRouter/Groq/xAI/…) can't be added in-app; **no session-independent model catalog** (Models screen + onboarding picker empty until a session exists); Doctor lacks in-app **pi install/update + auto-update toggle** and the **Web Access (Exa/url-fetch) card**.

### t3code-adopted areas

**Set A (terminal, diffs+review-comments, open-in-editor, file nav, command palette)** — The most complete part of the port; all five fully wired with dedicated e2e specs and one unified command catalog. Remaining gaps are documented deferrals: no side-by-side split diff (stale docstring pointer), transcript file-reference open deferred and never picked up, no syntax highlighting (deliberate, no shiki/workers), single terminal per session, and a few parked a11y items.

**Set B (preview + automation, composer, checkpoints, desktop polish)** — Core flows present and tested (dev-script preview with loopback-only sandboxed embed, composer pending-input/review/element/file surfaces, per-turn checkpoints with idle-gated rollback, S22a native turn-complete notifications + badge). Real gaps: preview automation is a **manual CSS-selector subset** (no click-to-select inspector, no screenshot annotation) because the cross-origin iframe forbids in-frame injection; and desktop attention is **scoped to the active session only** — a background session finishing raises neither a notification nor a badge.

---

## Consolidated gap table (non-parked)

| Feature                                                                                             | Status    | Severity    | Area           |
| --------------------------------------------------------------------------------------------------- | --------- | ----------- | -------------- |
| Loop structure variants (Maker+Checker/Pipeline/Parallel/Triage/Human-Approval) run as single-agent | missing   | **blocker** | Loops          |
| Loop structure-specific config fields (checker/rubric/stages/branches/triage/checkpoint)            | missing   | major       | Loops          |
| Loop launch context + context scope                                                                 | missing   | major       | Loops          |
| Loop session + transcript integration (runs in hidden throwaway session)                            | divergent | major       | Loops          |
| Loop per-iteration markdown artifacts + artifact dir + reveal                                       | missing   | major       | Loops          |
| Loop worktree apply/discard                                                                         | partial   | major       | Loops          |
| Loop Human Approval pause/resume (Approve/Reject)                                                   | missing   | major       | Loops          |
| Loop project availability & assignment (Default/Project/Catalog/Builtin)                            | missing   | major       | Loops          |
| Loop run control bar (Retry/Save/Reveal/Apply/Discard/Approve/Reject)                               | partial   | major       | Loops          |
| Agent avatar generation / import-from-file / per-agent display                                      | divergent | major       | Agents         |
| Per-project agent-assignment matrix (custom agents)                                                 | missing   | major       | Agents         |
| Per-project builtin agent enable/disable                                                            | missing   | major       | Agents         |
| Editor coverage of subagent-behavior fields                                                         | missing   | major       | Agents         |
| Git import fetch-and-preview sheet with per-skill selection                                         | missing   | major       | Skills         |
| Local import: scan folder for multiple skill roots + assets                                         | partial   | major       | Skills         |
| Skill conflict detection granularity (per-file; ref-file edits lost)                                | divergent | major       | Skills         |
| Fork from a specific user message (pi /fork + composer seed + provenance)                           | divergent | major       | Sessions       |
| Rerun / edit-and-resend a user message in place                                                     | missing   | major       | Sessions       |
| Semantic (embedder) recall abstain/qualification gates                                              | divergent | major       | Memory         |
| "Memory Recalled" transcript card + click-through links                                             | missing   | major       | Memory         |
| MCP: add http/remote server via UI (OAuth unreachable without it)                                   | partial   | major       | MCP            |
| MCP: edit an existing server                                                                        | missing   | major       | MCP            |
| MCP: OAuth auto-capture (loopback is dead code; manual paste-code)                                  | divergent | major       | MCP            |
| MCP: per-project server assignment                                                                  | missing   | major       | MCP            |
| Issues: reply / post a comment                                                                      | missing   | major       | Issues         |
| Issues: reopen a closed issue                                                                       | missing   | major       | Issues         |
| Issues: Open-in-Pi prompt context richness (`<github-issue-context>`)                               | partial   | major       | Issues         |
| In-app Pi install/update + auto-update toggle                                                       | missing   | major       | Doctor         |
| Doctor Web Access card (Exa key + url-fetch deps)                                                   | missing   | major       | Doctor         |
| Provider catalog scope — API-key providers absent                                                   | partial   | major       | Providers      |
| API-key sign-in (write ApiKeyCredential to auth.json)                                               | missing   | major       | Providers      |
| Session-independent model catalog (Models + onboarding empty until session)                         | divergent | major       | Models         |
| Preview automation: point-and-click element inspector                                               | divergent | major       | Preview        |
| Desktop: background (non-active) session notifications + badge                                      | missing   | major       | Desktop        |
| Editing an agent's Extensions allowlist                                                             | partial   | minor       | Agents         |
| mcpDirectTools modeled separately                                                                   | partial   | minor       | Agents         |
| Model/thinking/tools/skills/MCP selection UX (free-text vs pickers)                                 | divergent | minor       | Agents         |
| Create/edit agent at library scope                                                                  | partial   | minor       | Agents         |
| Duplicate agent / Replace-builtin-as-custom drafts                                                  | missing   | minor       | Agents         |
| Agent warnings / skill-visibility diagnostics                                                       | missing   | minor       | Agents         |
| skills.sh reserved-owner list (missing trending/hot/official/new)                                   | divergent | minor       | Skills         |
| Blobless+sparse clone (copies-into-catalog vs in-place)                                             | divergent | minor       | Skills         |
| Re-import of already-synced repo (dup provenance record)                                            | missing   | minor       | Skills         |
| Keep-Mine/Take-Remote per-skill vs per-file modal                                                   | divergent | minor       | Skills         |
| Per-skill Synced-Repository detail card                                                             | missing   | minor       | Skills         |
| AI skill-description summary on import                                                              | missing   | minor       | Skills         |
| Compare duplicate skill copies (SkillCompareSheet)                                                  | missing   | minor       | Skills         |
| Argument-hint frontmatter editing                                                                   | partial   | minor       | Prompts        |
| Search/filter across prompt catalog                                                                 | missing   | minor       | Prompts        |
| Prompt Library section (~/.pi/agent/prompt-library)                                                 | missing   | minor       | Prompts        |
| Import external prompt file (externalReference)                                                     | missing   | minor       | Prompts        |
| Builtin prompts + enable/disable                                                                    | missing   | minor       | Prompts        |
| Fork conversation into a 1:1 agent chat                                                             | missing   | minor       | Sessions       |
| Per-message transcript actions (hover copy + fork gutter)                                           | missing   | minor       | Sessions       |
| Session title auto-update over the conversation                                                     | partial   | minor       | Sessions       |
| User-message image/paste attachment rendering in transcript                                         | partial   | minor       | Sessions       |
| Persisted session-status model (failed/needsAttention/lastError)                                    | partial   | minor       | Sessions       |
| New-chat spawns pi immediately vs lazy draft                                                        | divergent | minor       | Sessions       |
| Worktree branch-name uniqueness (silent fallback to unisolated)                                     | partial   | minor       | Worktrees      |
| Worktree teardown keeps session branch (native force-deletes)                                       | divergent | minor       | Worktrees      |
| keepWorktreeAfterMerge setting + auto-cleanup path                                                  | partial   | minor       | Worktrees      |
| Pre-merge safety guards (parent-clean, source-branch-exists)                                        | partial   | minor       | Worktrees      |
| Merge conflict handling (generic 409 vs distinct outcome)                                           | partial   | minor       | Worktrees      |
| Release preflight remote-sync (ahead/behind) gate                                                   | divergent | minor       | Worktrees      |
| Worktree removal unsafe-path guard                                                                  | missing   | minor       | Worktrees      |
| Loop retry failed iteration                                                                         | missing   | minor       | Loops          |
| Loop rich validation evidence (exit code/stdout/stderr/duration)                                    | partial   | minor       | Loops          |
| Loop builtin (bundled) templates                                                                    | missing   | minor       | Loops          |
| Loop stop-reason coverage (unsafeWriteTarget etc.)                                                  | partial   | minor       | Loops          |
| Loop agent selection (free-text vs picker + validation)                                             | divergent | minor       | Loops          |
| Memory usage tracking (useCount/lastUsedAt) + markUsed                                              | missing   | minor       | Memory         |
| Memory tags editing in UI                                                                           | missing   | minor       | Memory         |
| Memory read-only detail view (metadata + rendered body)                                             | partial   | minor       | Memory         |
| Bulk "delete all stale memories"                                                                    | missing   | minor       | Memory         |
| Memory info/stats popover + enable-pause toggle                                                     | missing   | minor       | Memory         |
| Near-duplicate write guard (lexical-only, no embedding)                                             | partial   | minor       | Memory         |
| sourceAgentName captured on agent writes                                                            | partial   | minor       | Memory         |
| MCP smart-paste config parser                                                                       | missing   | minor       | MCP            |
| MCP per-tool descriptions                                                                           | partial   | minor       | MCP            |
| MCP master enable toggle                                                                            | missing   | minor       | MCP            |
| MCP read-only vs app-owned + reveal-config                                                          | missing   | minor       | MCP            |
| MCP config source coverage (~/.config/mcp, project .mcp.json)                                       | partial   | minor       | MCP            |
| MCP SSE transport                                                                                   | missing   | minor       | MCP            |
| Issues relationships (parent/sub/blocked-by/blocking)                                               | missing   | minor       | Issues         |
| Issues detail pane depth (type/state-reason/timestamps/avatars/permalinks)                          | partial   | minor       | Issues         |
| Issues type filter + close-reason filter                                                            | missing   | minor       | Issues         |
| Issues result truncation / incomplete-results notice                                                | missing   | minor       | Issues         |
| Issues in-app GitHub connection/connect flow                                                        | divergent | minor       | Issues         |
| Issues backend gh CLI vs REST (root cause of missing features)                                      | divergent | minor       | Issues         |
| Provider picker search + Subscriptions/API-key grouping                                             | missing   | minor       | Providers      |
| Auto-open browser on auth_url / verification page                                                   | divergent | minor       | Providers      |
| Re-auth / switch account for connected provider                                                     | partial   | minor       | Providers      |
| Onboarding preferences (subagents toggle, title/commit model pickers, github gate)                  | partial   | minor       | Onboarding     |
| Doctor GitHub connect action (read-only)                                                            | partial   | minor       | Doctor         |
| Doctor Settings Files detailed viewer                                                               | partial   | minor       | Doctor         |
| Doctor Warnings section                                                                             | missing   | minor       | Doctor         |
| Terminal splits/tabs/groups                                                                         | divergent | minor       | Terminal       |
| Diff side-by-side (split) view                                                                      | divergent | minor       | Diffs          |
| Diff syntax highlighting                                                                            | divergent | minor       | Diffs          |
| Diff turn/branch scope pickers                                                                      | divergent | minor       | Diffs          |
| Open-in-editor from transcript file references                                                      | missing   | minor       | Open-in-editor |
| File preview syntax highlighting                                                                    | divergent | minor       | File nav       |
| File nav recursive finder / project search                                                          | divergent | minor       | File nav       |
| Preview screenshot annotation → composer card                                                       | missing   | minor       | Preview        |
| Preview back/forward history navigation                                                             | divergent | minor       | Preview        |
| Composer terminal-context inline chip                                                               | missing   | minor       | Composer       |
| Composer server-side attachment persistence                                                         | missing   | minor       | Composer       |
| Checkpoints rewind semantics (restore-only vs native rerun-from-here)                               | divergent | minor       | Checkpoints    |
| Desktop badge count semantics (unseen events vs sessions-awaiting)                                  | divergent | minor       | Desktop        |
| Desktop notification click → navigate to raising session                                            | partial   | minor       | Desktop        |

_(Cosmetic-severity items — e.g. prompt package/settings sections, session-strip reshuffle, compacting-input banner, notification debounce, terminal light palette, palette focus-trap — are omitted from this table; they are noted in the area results.)_

---

## Known parked (pending user decisions)

| Item                                       | Reason                                                                                                                                                                                                  |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **S21 — Remote access**                    | Deployment/auth model + CORS is a security-sensitive slice that needs a user call on how the server is exposed and authenticated.                                                                       |
| **S22b — Desktop auto-update / packaging** | electron-updater needs a packaging tool (electron-builder/forge) + bundled-server story + update feed + Apple/Windows code-signing certs — procurement/credential/infra choices only the user can make. |
| Doctor Apple Foundation Model section      | Intentional platform divergence, not a defect: Apple Foundation Model is macOS/Apple-Intelligence-only and cannot exist on Linux/Windows.                                                               |

_(S22a desktop notifications + badges IS landed and is audited above, not parked.)_

---

## Recommended fix-slices (non-parked, ordered by severity)

**Slice A — Loops multi-structure engine (unblock).** Implement the four missing run engines (Maker+Checker, Agent Pipeline, Parallel Agents, Discovery/Triage) and Human-Approval pause/resume, plus the structure-specific config model, launch context, per-iteration artifacts + artifact directory, worktree apply/discard, and session/transcript integration (Loop / Loop Recap / Round cards). Add the missing control-bar actions and project availability/assignment. This is the single blocker and the largest single body of work.

**Slice B — Provider + model reach.** Add API-key sign-in (write `ApiKeyCredential` to auth.json) and surface the full connectable provider catalog (Subscriptions + API-key groups). Introduce a session-independent model catalog endpoint so the Models screen and onboarding default-model picker work before a session exists.

**Slice C — MCP completeness.** Add http/remote server add + edit forms, wire the dead `McpLoopbackServer` so OAuth auto-captures the redirect (kill the paste-the-code UX), and add per-project MCP assignment. Fold in per-tool descriptions, master toggle, config-source coverage, and read-only/reveal.

**Slice D — Issues write-back + context.** Add comment posting and reopen routes/UI, and build the rich `<github-issue-context>` block for Open-in-Pi (body + comments + relationships). Consider moving from gh-CLI to REST to unlock relationships, issue type, state-reason, and permalinks.

**Slice E — Agents avatars + assignment matrix.** Ship the portable "Import from File" + stored-image display path (AgentImageStore/AgentImageLoader), the per-project agent-assignment matrix and per-project builtin disable (reuse the skills/prompts pattern already in the codebase), and add the missing subagent-config editor fields.

**Slice F — Sessions fork/rerun.** Implement per-message fork via pi `/fork` (cut point + composer seed + provenance/recap), in-place rerun (edit-and-resend), and the per-message hover copy/fork gutter buttons.

**Slice G — Memory recall fidelity.** Port native's semantic abstain/qualification gates (minTopSimilarity, keepScoreRatio, discriminative-term overlap) and add the "Memory Recalled" transcript card with click-through to the Memory screen.

**Slice H — Doctor actionability.** Add in-app pi install/update with progress + auto-update toggle, the Web Access card (Exa key + url-fetch deps), the GitHub connect button, and the Settings Files viewer.

**Slice I — Skills import UX + safety.** Build the fetch-and-preview import sheet with per-skill selection, folder-scan local import (with assets), and upgrade conflict detection to per-file fingerprinting so reference-file edits aren't silently overwritten (closes a real data-loss gap).

**Slice J — Desktop background attention.** Track all sessions (not just the active one) for turn-complete/approval, fix the badge to count distinct sessions-awaiting-review, and wire the `focus-session` IPC in the renderer so clicking a notification navigates to the raising session.

**Slice K — Minor/polish sweep.** Preview element inspector improvements (or accept the manual subset), diff split view + syntax highlighting, transcript file-reference open, worktree cleanup/guards, prompts library/search/builtin, and the remaining minor items batched by area.
