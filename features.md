# Agent Deck — Features

---

## Sessions

**Session Lifecycle**
Create, configure, start, stop, resume, and delete Pi Agent coding sessions bound to a specific project. Each session is an isolated conversation with an AI coding agent.
*Solves: Managing multiple parallel or sequential AI coding sessions with distinct project contexts.*

**Session List & Search**
A searchable, filterable list of all sessions with status indicators, project, and agent assignment. Context-menu actions for resume, delete, and terminal handoff.
*Solves: Finding and managing sessions across multiple projects.*

**Auto-Titling**
Automatically generates and updates session titles using a helper LLM based on the first user message and subsequent plan changes.
*Solves: Sessions pile up with generic names; auto-titling keeps them identifiable.*

**Idle Session Parking**
Automatically parks sessions that have been idle beyond a configurable timeout to free system resources.
*Solves: Long-running idle sessions waste resources and RPC connections.*

**Resume in Terminal**
Hand off a session to Terminal or iTerm for raw CLI access, with a warning that terminal messages don't sync back.
*Solves: Power users occasionally need low-level CLI access for debugging.*

---

## Transcript & Chat

**Streaming Transcript**
Real-time rendering of Pi Agent events: steering messages, thinking blocks, assistant responses, tool calls, status updates, and errors.
*Solves: Users need live, structured visibility into what the AI agent is doing as it works.*

**Display Options**
Toggle visibility of thinking blocks, web activity, tool calls, errors, plans, and diffs via a popover.
*Solves: Transcript clutter makes it hard to focus; users control what detail they see.*

**Inline Diffs**
Shows compact file diffs inline in the transcript with color-coded change lines.
*Solves: Review code changes the agent made without leaving the transcript.*

**File Preview**
Previews file contents referenced in tool call results directly within the transcript.
*Solves: Inspect referenced files without switching to an external editor.*

**Plan Checklist**
Displays a live task checklist showing the agent's current plan with status indicators (todo/in_progress/done/blocked/skipped).
*Solves: Multi-step agent work needs visible progress tracking so users know where the agent is.*

**Message Composer with Attachments**
A rich composer supporting text, paste handling, and attachments (files, folders, images). Type `@` to get project file suggestions.
*Solves: Provide context alongside natural-language instructions without navigating the file system.*

---

## Agents

**Agent Library**
Browse, create, edit, duplicate, and delete agent configurations — name, description, system prompt overrides, tool restrictions, model overrides, and thinking level.
*Solves: Define and manage specialized AI agents with distinct behaviors and constraints.*

**Scope & Assignment**
Agents carry explicit scope (Builtin/Global/Library/Project) with color + icon + text indicators. Assign agents per-project or globally as defaults.
*Solves: Understand where an agent comes from and control which agents are available per project.*

**Avatar Generation**
Auto-generates avatar prompts using a helper LLM, with optional Image Playground integration for visual avatar creation.
*Solves: Agents need visual identification for a navigable, personal library.*

**Import & Export**
Import agent configurations from files and export agents to shareable JSON.
*Solves: Share agent definitions across machines or team members.*

**Builtin Override**
Override specific fields of bundled builtin agents without modifying the bundled resource.
*Solves: Customize built-in agents without forking or losing updates.*

---

## Skills

**Skill Catalog & Discovery**
Browse discovered skills from Pi's skill directories with scope indicators, descriptions, and tool lists.
*Solves: Visibility into what skills are available and where they come from.*

**Skill Assignment**
Assign skills at three levels: default (all sessions), per-project, or per-agent, with warnings for missing skills.
*Solves: Skills must be selectively enabled for the right sessions; blanket discovery leads to unexpected behavior.*

---

## Prompt Templates

**Prompt Template Library**
Browse, create, rename, and delete prompt templates that can be injected into sessions as pre-written starting prompts.
*Solves: Eliminate repetitive typing and ensure prompt consistency across sessions.*

---

## Subagents

**Native Subagent Bridge**
Parent Pi sessions delegate work to specialized child agents via managed_subagent and managed_parallel tools, with worktree isolation for write tasks.
*Solves: Complex coding tasks benefit from parallel specialist agents working independently.*

**Subagent Summary Cards**
Rich summary cards in the transcript showing subagent progress — completed/running/failed counts, per-agent status, tokens, and duration.
*Solves: Parallel subagent runs produce complex output that needs at-a-glance visibility.*

**Supervisor Request Cards**
When a child subagent needs a decision, it renders a native macOS decision card with options and freeform input.
*Solves: Subagents need human guidance; structured request cards make this seamless.*

**Worktree Isolation**
Creates isolated git worktrees for write-capable subagents so parallel writers don't conflict.
*Solves: Multiple agents editing the same files simultaneously would cause merge conflicts.*

**Ask User Tool**
A bundled extension that renders native macOS decision cards for structured user interaction during agent sessions.
*Solves: Agents need a way to ask structured questions beyond freeform chat.*

---

## Projects

**Project Discovery & Management**
Auto-discovers git repositories from a configurable root directory, with project lists and add/remove support.
*Solves: Users with many repositories need automatic discovery rather than manual registration.*

**Per-Project Toggles**
Toggle which agents, skills, and prompts are active for each project independently.
*Solves: Different projects need different resource configurations; per-project toggles avoid noise.*

**Instruction File Editing**
Edit project-scoped instruction files (AGENTS.md, CLAUDE.md) directly within the app.
*Solves: Project instructions need frequent updates; switching to an external editor interrupts workflow.*

---

## Git & Shipping

**AI-Powered Commit & Push**
Stage all changes, generate an AI commit message, commit, and optionally push — with optional confirmation dialogs.
*Solves: Writing good commit messages and remembering to push is tedious; AI automates the workflow.*

**Git Status Integration**
Monitors git status for the active project and enables/disables commit/push buttons accordingly.
*Solves: Know if there are changes to commit without leaving the app.*

**Repository Changes View**
Shows local git changes (modified/new/deleted files) and GitHub commit/push status.
*Solves: Review and ship code changes without switching tools.*

---

## GitHub

**GitHub Authentication**
Connects to GitHub via `gh` CLI or native OAuth, with connection status and avatar display.
*Solves: GitHub features require authentication; the app auto-detects existing CLI auth.*

**Issue Board**
Displays issues from project repositories in a columnar board (Open/Closed) with filtering, sub-issue progress, and dependency tracking.
*Solves: Triage and select GitHub issues without leaving the coding environment.*

**Issue-to-Session Launch**
Build a structured prompt from a GitHub issue (title, body, labels, comments) and launch a Pi Agent session pre-configured to work on it.
*Solves: Going from issue to coding session involves copy-paste and context loss; this automates it.*

**Cross-Repo Issue Search**
Aggregates issues across multiple repositories with rate-limit awareness.
*Solves: Users with many repos need cross-repo issue visibility.*

---

## Agent Memory

**Persistent Project Memory**
Agents write durable facts (architecture, decisions, runbooks, failures, preferences) to a project-scoped memory store via the `agent_deck_memory_write` tool.
*Solves: Agents lose context between sessions; memory provides continuity across runs.*

**Memory Management UI**
Browse, search, filter (active/stale, by kind), enable/disable individual memories, and configure injection character budget.
*Solves: Memory grows unbounded without curation; users need tools to manage what agents remember.*

**Automatic Injection**
Relevant active memories are injected into new sessions within a configurable character budget.
*Solves: Agents need past context but the context window is limited; selective injection balances recall and token cost.*

**Stale Marking**
Agents mark outdated memories as stale, removing them from automatic injection while preserving them for audit.
*Solves: Outdated memories mislead agents; stale marking is safer than deletion.*

---

## Models

**Model Discovery & Selection**
Auto-discovers available models from configured Pi providers, groups by provider, and lets users set default and per-agent model overrides.
*Solves: Users with multiple API providers need to see and choose which model each session uses.*

**Apple Foundation Model**
Uses Apple's on-device Foundation Model for automations (title generation, commit messages, avatar prompts) when available.
*Solves: Some automation tasks don't need cloud models; on-device inference is free and private.*

**OpenAI Fast Mode**
Configures eligible OpenAI models to use priority service tier via a bundled extension.
*Solves: Power users on OpenAI plans want faster inference for specific models.*

**Model Disable/Hide**
Disable specific model identifiers so they don't appear in pickers.
*Solves: Too many discovered models clutter the UI; hiding unused ones reduces noise.*

---

## Environment & Secrets

**Environment Key Management**
Browse, create, edit, and delete environment key-value pairs from `.env` files across scopes, with secret masking in the UI.
*Solves: Manage API keys and configuration without exposing secrets in the interface.*

**Safe Persistence**
Reads and writes `.env` files with explicit write-target validation — never modifies bundled resources.
*Solves: Env files are fragile; structured persistence avoids corruption.*

---

## Health & Setup

**Pi Runtime Doctor**
Runs health checks validating Pi CLI installation, version, path resolution, and environment key presence, with auto-fix suggestions.
*Solves: Diagnose and fix setup failures without digging through logs.*

**Version & Update Checking**
Checks the installed Pi version against the latest release and reports update availability.
*Solves: Know when to update the Pi runtime for bug fixes and new features.*

**Welcome Tour**
A 6-page onboarding slideshow introducing the app's key concepts on first launch.
*Solves: New users need a guided introduction to understand what the app does.*

**Setup Wizard**
A step-by-step checklist covering Pi path, GitHub auth, project folder, and system prompt customization.
*Solves: First-time setup has multiple dependencies; the wizard ensures nothing is missed.*

---

## Web Access

**Exa Web Search & Fetch**
Bundled extensions for `web_search`, `fetch_content`, and `get_search_content` using the Exa API, with domain filtering and recency filters.
*Solves: AI agents need web research capabilities for current documentation and API lookups.*

**Fallback Web Fetch**
A fallback `web_fetch` extension when Exa is not configured, using basic HTTP fetching.
*Solves: Not all users have Exa API keys; a fallback ensures basic web access works.*

---

## Commands

**Injected Slash Commands**
Bundled and user-imported TypeScript slash commands injected into Pi sessions as extensions.
*Solves: Reusable command workflows automate multi-step operations within agent sessions.*

**Command Library**
A local library directory for user-created TypeScript commands, manageable from Settings.
*Solves: Create, manage, and share custom commands without modifying the app.*

---

## Settings

**8 Settings Tabs**
General (appearance, project root), Agents (defaults), Automations (toggles and helper models), GitHub (cache and connection), Performance (parking, cache limits), Subagents (templates), Commands (enable/disable), and Shortcuts (full keyboard shortcut reference).
*Solves: Centralized configuration for every aspect of the app.*

---

## Notifications

**Session Event Notifications**
macOS notifications for session state changes (completed, errored, needs attention) with configurable delay.
*Solves: Users step away during long agent runs and need to know when to return.*

---

## Window & Navigation

**Multi-Window Support**
Open multiple windows with proper state restoration and notification routing.
*Solves: Power users work on multiple sessions or views simultaneously.*

**Keyboard Shortcuts**
14 shortcuts across Session, Agents, App, GitHub, and Projects & Resources categories.
*Solves: Navigate and control the app faster with the keyboard.*
