# Agent Description Comparison: Before → After

## scout
### Before
> Fast codebase recon that returns compressed context for handoff

### After
> Fast codebase explorer. Use when you need to understand a codebase area you haven't seen yet, find relevant files for a task, or gather context before planning or implementing. Prefer scout over reading files one-by-one when the task involves unfamiliar code, multiple files, or a module you haven't touched in this session. Returns a structured context file that other agents can consume directly.

**Verdict**: Already worked. Minor polish only.

---

## reviewer
### Before
> Versatile review specialist for code diffs, plans, proposed solutions, codebase health, and PR/issue validation

### After
> Code review from a fresh, independent context. Use when you want a second opinion on a diff, a plan, or a proposed approach. Also use for general codebase health audits and PR/issue validation. Prefer reviewer over self-review whenever the change is non-trivial — it inspects from scratch without the biases of whatever wrote the code. Can also apply small fixes directly during review.

**Verdict**: Already worked. Minor polish only.

---

## planner ⚠️
### Before
> Creates implementation plans from context and requirements

### After
> Turns requirements and scout context into a concrete, file-level implementation plan. Use planner when a task is complex enough that jumping straight to coding risks missed steps or rework — specifically when the change touches 3+ files, has non-obvious dependencies, or the correct order of operations matters. Outputs a structured plan.md that worker can execute directly. Not needed for small, obvious changes.

**Why it wasn't picked**: The original description just said what it does generically. The LLM can "create plans" itself — there was no clear trigger for when delegating is better. The new description gives concrete heuristics: "3+ files", "non-obvious dependencies", "order of operations matters".

---

## worker ⚠️
### Before
> Implementation agent for normal tasks and approved oracle handoffs

### After
> Implementation agent that writes and edits code. Use worker when you want to delegate the actual file changes instead of making them yourself — this keeps you free to review, coordinate, or handle other tasks. Good for: executing an approved plan, applying a batch of edits across multiple files, or implementing a well-scoped feature where the requirements are already clear. Give it a concrete task with clear scope, not vague direction. Returns a summary of what it changed and what it validated.

**Why it wasn't picked**: Two problems. (1) "approved oracle handoffs" made it sound like a second step that only fires after oracle — creating a dependency chain that never starts. (2) The LLM can edit files directly, so the description never answered "why not just do it myself?" The new description explains when delegating implementation is actually better.

---

## oracle ⚠️
### Before
> High-context decision-consistency oracle that protects inherited state and prevents drift

### After
> Second opinion from an agent that can see the full conversation history. Use oracle before committing to a non-trivial direction — specifically when you are unsure about an architecture choice, want to catch blind spots in your current approach, or need someone to challenge your assumptions before you start implementing. Not needed for straightforward changes where the right approach is obvious. Best triggered by the thought: "I'm about to do something I might regret — let me get a sanity check first."

**Why it wasn't picked**: "Decision-consistency", "inherited state", "drift" are abstract meta-cognitive concepts. The LLM never thinks "am I experiencing drift right now?" The new description gives a concrete trigger: "I'm about to do something I might regret" — an internal feeling the LLM can actually recognize. It also makes clear when NOT to use it (straightforward changes).

---

## researcher
### Before
> Autonomous web researcher — searches, evaluates, and synthesizes a focused research brief

### After
> Web research agent. Use when you need current information that isn't in the codebase — API docs, library behavior, best practices, ecosystem changes, or anything that requires live web searches. Returns a structured research brief with sources. Not for codebase exploration (use scout) or plan review (use reviewer).

**Verdict**: Added negative constraints ("not for codebase exploration, not for plan review") to help the LLM disambiguate. Otherwise unchanged.

---

## context-builder
### Before
> Analyzes requirements and codebase, generates context and meta-prompt

### After
> Gathers codebase context AND requirements into a structured handoff package. Use when you have a user request but need someone to bridge the gap between "what the user asked" and "what the codebase needs" — producing both a context file and a meta-prompt that planner or worker can consume. More thorough than scout (which just maps code) but doesn't plan or implement.

**Verdict**: Clarified the difference from scout and gave a concrete trigger.

---

## delegate
### Before
> Lightweight subagent that inherits the parent model with no default reads

### After
> Generic lightweight subagent that inherits your model and tools. Use for one-off tasks you want to run in a separate context — quick lookups, small independent jobs, or anything that doesn't fit a specific agent role. Minimal overhead, no fixed output format.

**Verdict**: Clarified when to use it vs the specialist agents.

---

## Pattern used

Every description now follows the same structure:
1. **One-line summary** of what the agent does
2. **"Use when..."** — concrete trigger situations the LLM can match against
3. **"Prefer X over Y when..."** or **"Good for: ..."** — why it's better than the alternative
4. **"Not for..."** — negative constraints to prevent mis-selection (where relevant)
