# Native subagent eval report — 2026-05-14

## What ran

Completed the requested 30 real Pi model/thinking combinations against Agent Deck-style native subagent tasks:

- `explorer`: codebase reconnaissance of Agent Deck native subagent model/thinking/RPC launch flow.
- `planner`: 1:1 AppKit chat performance rewrite plan, with Apple documentation skill path and native performance skill path supplied.
- `reviewer`: review of commit `6820ba5` for the built-in subagent rename.

Artifacts are in:

```text
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/
```

Important files:

```text
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/summary.md
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/summary.json
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/model-pricing.json
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/<agent>/<model>/<thinking>/<task>/output.md
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/<agent>/<model>/<thinking>/<task>/token-usage.json
```

## Note about execution method

The XCTest harness was updated during the session to support the requested matrix, token/cost recording, Apple documentation skill handoff, and isolated worktree execution. While you were actively running/switching app branches and profiling another Agent Deck instance, the macOS XCTest app host was repeatedly killed by the system/test runner before completion.

To finish the evaluation without interfering with your active app work, I ran the same 30 agent/model/thinking tasks through an isolated standalone Pi CLI harness in a detached temporary worktree. This avoided branch-switch interference and preserved per-run outputs, sessions, tokens, and exact Pi-reported costs. The completed artifacts above are from that successful run.

## Results overview

All 30 runs completed.

| Agent | Runs | Avg score | Exact cost |
|---|---:|---:|---:|
| explorer | 11 | 4.18 / 5 | $5.808684 |
| planner | 8 | 4.38 / 5 | $5.668251 |
| reviewer | 11 | 4.27 / 5 | $5.479509 |
| **Total** | **30** | **4.27 / 5** | **$16.956444** |

Cost source: `session_usage` for all 30 runs, i.e. Pi session usage reported exact dollar cost directly. Pricing snapshot is also saved in `model-pricing.json`.

## Model comparison

| Model | Runs | Avg score | Total tokens | Exact cost |
|---|---:|---:|---:|---:|
| `gpt-5.4` | 12 | 4.33 | 7,550,545 | $4.884279 |
| `gpt-5.5` | 12 | 4.50 | 9,368,473 | $9.951276 |
| `gpt-5.4-mini` | 6 | 3.67 | 12,201,981 | $2.120889 |

Takeaways:

- `gpt-5.5` had the best average score but cost about 2x `gpt-5.4`.
- `gpt-5.4` was the best cost/quality balance in this run.
- `gpt-5.4-mini` was cheap per token, but high/xhigh thinking generated very large token counts and weaker reviewer scores, so it is not automatically cheaper for deep review tasks.

## Thinking-level comparison

| Model / thinking | Runs | Avg score | Total tokens | Exact cost |
|---|---:|---:|---:|---:|
| `gpt-5.4 off` | 3 | 4.67 | 617,022 | $0.611840 |
| `gpt-5.4 low` | 3 | 4.33 | 741,154 | $0.652814 |
| `gpt-5.4 medium` | 3 | 4.33 | 1,613,511 | $1.091502 |
| `gpt-5.4 high` | 3 | 4.00 | 4,578,858 | $2.528123 |
| `gpt-5.5 off` | 3 | 4.33 | 1,653,247 | $2.021993 |
| `gpt-5.5 low` | 3 | 4.67 | 903,227 | $1.382834 |
| `gpt-5.5 medium` | 3 | 4.67 | 1,769,218 | $2.056562 |
| `gpt-5.5 high` | 3 | 4.33 | 5,042,781 | $4.489887 |
| `gpt-5.4-mini medium` | 2 | 4.00 | 1,468,357 | $0.269700 |
| `gpt-5.4-mini high` | 2 | 3.50 | 2,883,777 | $0.632171 |
| `gpt-5.4-mini xhigh` | 2 | 3.50 | 7,849,847 | $1.219018 |

Takeaways:

- High/xhigh thinking often increased cost significantly without improving the automatic fact score.
- Best broad defaults from this eval:
  - `gpt-5.5 low` or `gpt-5.5 medium` when quality is more important.
  - `gpt-5.4 off` or `gpt-5.4 low` when cost/performance balance matters.
  - Avoid `gpt-5.4-mini high/xhigh` for reviewer-style tasks unless a manual review proves it adds value.

## Agent-specific observations

### Explorer

Best runs:

- `gpt-5.5 off`: score 5, $0.471429
- `gpt-5.5 high`: score 5, $1.307316

Most explorer runs found the relevant Agent Deck code paths. The automatic scorer often marked `launchCommand` as missing because several outputs described launch argument construction without literally using that string. Manual review of the `output.md` files is recommended before treating those as true misses.

Recommended default for explorer:

```text
gpt-5.4 low/off for cheap recon
gpt-5.5 off for stronger recon when cost is acceptable
```

### Planner

Best runs:

- `gpt-5.4 off`: score 5, $0.305197
- `gpt-5.5 low`: score 5, $0.376525
- `gpt-5.5 medium`: score 5, $0.619483

The strongest planner output is probably:

```text
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/planner/openai-codex_gpt-5.5/medium/planner-appkit-chat-performance-port/output.md
```

It gives a thorough 1:1 inventory of current chat capabilities and a concrete AppKit/AppKit-hybrid plan. It explicitly covers current SwiftUI transcript files, AppKit architecture, auto-scroll behavior, row/card parity, native subagent cards, accessibility, validation, and profiling/report structure.

Recommended default for planner:

```text
gpt-5.5 low or medium
```

### Reviewer

Best runs:

- `gpt-5.4 off`: score 5, $0.112274
- `gpt-5.4 low`: score 5, $0.211590
- `gpt-5.4 medium`: score 5, $0.322284
- `gpt-5.5 low`: score 5, $0.580432
- `gpt-5.5 medium`: score 5, $0.494131

Reviewer did not benefit from mini high/xhigh in this eval. The mini runs were cheaper than some full-model high runs but missed more expected evidence and used surprisingly many tokens at xhigh.

Recommended default for reviewer:

```text
gpt-5.4 low/medium for cost-effective reviews
gpt-5.5 medium for stronger reviews when cost is acceptable
```

## Cost hotspots

Most expensive individual runs:

| Agent | Model | Thinking | Score | Tokens | Cost |
|---|---|---:|---:|---:|---:|
| planner | gpt-5.5 | high | 4 | 2,095,666 | $1.849806 |
| reviewer | gpt-5.5 | high | 4 | 1,342,549 | $1.332765 |
| explorer | gpt-5.5 | high | 5 | 1,604,566 | $1.307316 |
| planner | gpt-5.4 | high | 4 | 1,954,722 | $1.077346 |
| explorer | gpt-5.5 | medium | 4 | 966,629 | $0.942948 |

High thinking is the obvious cost risk.

## Practical recommendations

1. Use `gpt-5.4 low` as the default cheap native subagent setting.
2. Use `gpt-5.5 low` or `gpt-5.5 medium` for planner tasks that need high-quality architecture decisions.
3. Do not default reviewer to mini high/xhigh; use `gpt-5.4 low/medium` or `gpt-5.5 medium` instead.
4. Keep exact cost recording from Pi session usage; it worked for every completed run.
5. For future XCTest-based evals, run from an isolated clone/worktree when the main app is not simultaneously being profiled or launched. The app-hosted XCTest process is not reliable while another Agent Deck instance is active.

## Manual review shortlist

Start with these outputs tomorrow:

```text
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/planner/openai-codex_gpt-5.5/medium/planner-appkit-chat-performance-port/output.md
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/planner/openai-codex_gpt-5.5/low/planner-appkit-chat-performance-port/output.md
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/explorer/openai-codex_gpt-5.5/off/explorer-native-subagent-model-flow/output.md
native-subagent-eval-artifacts-2026-05-14T00-34-06Z/reviewer/openai-codex_gpt-5.4/medium/reviewer-agent-rename-commit/output.md
```
