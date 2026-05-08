# Stitch prompt — Agent Deck concept screens

Use the design system from this design.md file. Design a polished native macOS app concept for **Agent Deck**, a calm mission-control surface and native GUI for the Pi terminal CLI, used for chatting with agents, doing agentic coding work, and supervising Pi AI agents.

The app should feel like **Mission Control for AI agents**: precise, observant, fast to scan, trustworthy under load, and deeply native to macOS. Do not make it look like a generic AI chat app or web SaaS dashboard.

## Product context

Agent Deck helps technical users run Pi from a native Mac interface instead of only the terminal. It supports:

- Chatting with agents in CLI-backed sessions
- Agentic coding work with prompts, command output, file changes, diffs, and approvals
- Agents, chains, skills, and prompt templates
- Builtin, global, library, and project-scoped resources
- Projects, worktrees, and GitHub issue workflows
- Native agent sessions, subagent runs, supervisor requests, and session relay coordination

The interface should answer these questions at a glance:

1. What resources exist?
2. Where are they active: builtin, global, library, or project?
3. What is currently running?
4. What files, commands, or diffs changed?
5. What needs attention or approval?
6. What action can the user safely take next?

## Global app shell

Use a native macOS split-view layout:

- Left sidebar, 240–260 pt wide, using macOS sidebar styling.
- Main content column for lists, dashboards, tables, selected-area content, and a focused agentic coding workspace.
- Right inspector/detail panel for metadata, configuration, paths, actions, transcripts, command output, file changes, diffs, approvals, and danger zones.
- Top toolbar with global search, refresh/sync, launch/new action, GitHub/account status, and session status.

Use light and dark mode thinking, but render the concept primarily in a refined dark mode unless multiple variants are easy.

Use semantic scope/status indicators:

- Builtin: gray, read-only/lock cue
- Global: blue
- Library: violet
- Project: cyan
- Running: teal
- Success: green
- Warning/needs attention: amber
- Danger/error/destructive: red

Every status or scope must include text and icon, not color alone.

## Navigation model

The sidebar should include these primary sections:

- Mission Control
- Resource Library
- Agents
- Chains
- Skills
- Prompt Templates
- Projects
- Sessions
- Coding Workspace
- Supervisor Requests
- GitHub
- Settings

Below the main navigation, show a “Pinned Projects” group with 2–4 example projects.

Use SF Symbol-style icons. Avoid robot faces, chat bubbles, mascots, neon cyberpunk, and playful AI imagery.

## Screens to design

Create a cohesive set of main screens. They should look like they belong to the same app and design system.

---

## 1. Mission Control dashboard

Design the default landing screen.

Purpose: Give the user a fast operational overview of Pi on this Mac.

Include:

- Page title: “Mission Control”
- A concise subtitle like “Agents, projects, and sessions across this Mac.”
- Compact summary tiles for:
  - Active sessions
  - Pending supervisor requests
  - Projects linked
  - Resources available
- A prominent “Launch agent” or “New coding session” primary action in the toolbar or header.
- A “Live sessions” section using session/run cards, including coding sessions.
- A “Needs attention” section for supervisor requests, auth issues, or failed runs.
- A “Recent activity” list with timestamps and short operational messages.
- A right inspector titled “Machine status” showing:
  - Pi version
  - Settings path
  - Global agent folder
  - GitHub account status
  - Last sync/scan time

Visual notes:

- This screen should be scan-friendly, not a marketing dashboard.
- Use cards only for live/recent sessions and important summaries.
- Keep text-heavy areas opaque, not glassy.

---

## 2. Resource Library

Design the screen for browsing agents, chains, skills, and prompts across scopes.

Purpose: Make scope and source obvious.

Include:

- Page title: “Resource Library”
- Segmented control or filter tabs: All, Agents, Chains, Skills, Prompts
- Search field: “Search resources”
- Filter chips for Builtin, Global, Library, Project
- Main list/table of resources with rows showing:
  - Icon
  - Name
  - Short description
  - Type
  - Scope chip
  - Source/path metadata in monospaced text
  - Last modified or active state
  - Overflow menu
- Selected row example: an agent named “macos-development” or “commit-and-push”
- Right inspector titled “Agent details” or “Resource details” showing:
  - Frontmatter summary
  - Description
  - Skills or linked files
  - Source path
  - Read-only or editable state
  - Actions: Enable globally, Assign to project, Copy to library
  - A separated danger zone only if relevant

Visual notes:

- Resource rows should be dense and native, not large SaaS cards.
- Scope chips are mandatory and must be visually distinct.
- Builtin resources should show a lock/read-only marker.

---

## 3. Agentic Coding Workspace

Design the most important screen: a native Mac GUI for a Pi terminal CLI coding session.

Purpose: Let the user chat with an agent and do agentic coding while keeping project context, commands, diffs, approvals, and outputs visible.

Include:

- Page title with active task, e.g. “Refactor Resource Library”
- Project/cwd path in monospaced metadata
- Session status chip: Running, Needs approval, Stopped, Completed, Failed
- Top toolbar actions: New session, Stop, Resume, Attach context, Open terminal
- Main conversation/transcript area showing:
  - User prompts
  - Agent responses
  - Tool/command events
  - Status updates
  - Compact timestamps
- Bottom prompt composer with:
  - Placeholder: “Ask the agent to inspect, edit, test, or explain…”
  - Send button
  - Attach file/context button
  - Request plan option
  - Approval-aware state when the agent is blocked
- A command/output stream panel using opaque monospaced styling.
- A changed files panel showing paths, status badges, and counts.
- A diff preview panel for selected file changes.
- An approvals/risk area showing pending filesystem or command approvals with plain-language consequences.
- Right inspector titled “Session context” showing:
  - Active agent
  - Model
  - Project path
  - Git branch
  - Linked GitHub issue
  - Skills in use
  - Latest supervisor request if any

Visual notes:

- This is allowed to include chat, but it must not look like a generic AI chatbot.
- It should feel like a native coding cockpit wrapped around the Pi terminal CLI.
- Keep files, diffs, commands, and project context as first-class surfaces.
- Long transcripts, logs, and diffs must be opaque and readable, not glassy.
- Risky operations must require clear approval states.

---

## 4. Agent Session Dashboard

Design the screen for live and recent agent runs.

Purpose: Let users supervise active work and quickly understand run state.

Include:

- Page title: “Sessions”
- Toolbar action: “Launch agent” or “New coding session”
- Filters: Running, Needs reply, Needs approval, Completed, Failed, All
- Main content with grouped session cards:
  - Running now
  - Waiting on supervisor
  - Needs approval
  - Completed today
- Each session card should show:
  - Session name
  - Agent name
  - Project/cwd
  - Model
  - Status chip
  - Elapsed time or last activity
  - Subagent count
  - Latest event
  - Changed files count if relevant
  - Primary next action: Inspect, Reply, Approve, Resume, Archive
- A selected session detail area showing:
  - Timeline of recent events
  - Transcript preview in a code-style opaque panel
  - Output artifacts or changed files
  - Supervisor requests if any

Visual notes:

- Running sessions can use a subtle teal indicator.
- Pending supervisor requests should be prominent but not alarming unless blocked.
- Completed sessions should be calmer and lower emphasis.

---

## 5. Project Detail

Design a project-focused screen.

Purpose: Show what Pi resources are active in a project and provide launch/GitHub/coding actions.

Include:

- Page title with project name, e.g. “agent-deck”
- Project path in monospaced metadata
- GitHub repo connection status
- Header actions:
  - New coding session
  - Launch agent
  - Assign resource
  - Open in Finder
  - Open in terminal
- Sections or tabs:
  - Overview
  - Resources
  - Sessions
  - GitHub
  - Worktrees
- Overview content showing:
  - Active project agents
  - Project skills
  - Recent coding sessions
  - Git status summary
  - Changed files summary
  - Open issues or assigned GitHub work
- Main resource list showing project-scoped and inherited global/library resources.
- Right inspector titled “Project configuration” showing:
  - Project `.pi` path
  - Enabled agents
  - Linked skills
  - Worktree status
  - GitHub repo and branch
  - Clear filesystem consequences for actions

Visual notes:

- Make project scope visually clear with cyan “Project” chips.
- Show inherited/global/library resources without implying they are copied locally.
- Avoid hiding paths when files are written, linked, or moved.

---

## 6. Agent Detail Inspector / Launch flow

Design the focused experience for inspecting an agent and launching it.

Purpose: Help users understand what an agent does before launching, chatting with it, or assigning it.

Include:

- Selected agent title, e.g. “commit-and-push”
- Scope chip and source path
- Description from frontmatter
- Capabilities/skills list
- Settings or constraints summary
- Compatible projects or recent projects
- Actions:
  - New coding session
  - Launch agent
  - Enable globally
  - Assign to project
  - Edit source
- A launch configuration panel or sheet with:
  - Project/cwd picker
  - Model picker
  - Initial instruction field
  - Optional linked GitHub issue
  - Safety summary: what files/paths may be touched
  - Primary action: Launch
  - Secondary action: Cancel

Visual notes:

- The launch flow should feel deliberate and safe, not like a casual chat app.
- Use form controls and aligned labels.
- Use one primary command accent only.

---

## 7. Supervisor Requests / Session Relay

Design the coordination screen for blocked subagents or cross-session messages.

Purpose: Let the user see which sessions need input and reply safely.

Include:

- Page title: “Supervisor Requests”
- Summary count of pending requests
- Filter tabs: Pending, Answered, Archived
- Main list of requests showing:
  - Request title/question
  - Requesting session
  - Agent/subagent name
  - Project
  - Age/last activity
  - Status chip: Needs reply, Answered, Blocked
- Selected request detail showing:
  - Full question
  - Context excerpt
  - Related files or command output
  - Suggested response area
  - Reply box
  - Actions: Send reply, Open session, Defer
- A small “Session Relay” area for cross-session notes/questions.

Visual notes:

- Use relay violet only for coordination and relay concepts.
- Needs-reply states can use amber with text and icon.
- Do not make this look like a casual chat interface; it is an operational request queue.

## Visual style requirements

Follow these design constraints carefully:

- Native macOS first: sidebar, toolbar, split view, inspector, native controls.
- Calm, operational, exact tone.
- High information density where appropriate, but readable.
- Opaque panels for long text, code, transcripts, tables, and diffs.
- Subtle borders over heavy shadows.
- Chat is an important feature, but it must be framed as a native agentic coding workspace, not a generic AI chat UI.
- No robot mascots, chat bubbles, playful assistant avatars, or decorative gradients.
- No web-dashboard card stacks for every row.
- No hidden scope: every resource must make scope visible.
- Destructive actions must be separated and clearly labeled.

## Suggested sample data

Use realistic sample names:

Agents:

- commit-and-push
- unpushed-review
- macos-development
- github-cli-issues
- pi-create-agent

Skills:

- apple-documentation
- hig-components-layout
- ask-user
- librarian

Projects:

- agent-deck
- agent-deck-prototype
- macos-playground

Sessions:

- “Review unpushed changes” — Running
- “Create GitHub issue workflow” — Needs reply
- “Refactor resource library view” — Completed
- “Inspect macOS HIG layout” — Failed
- “Implement resource scope chips” — Needs approval

## Output expectation

Produce a cohesive native macOS product concept with the above screens, especially the agentic coding workspace. Prioritize layout, hierarchy, states, and interaction clarity over illustration. The final result should look like a production-quality app direction that an engineer could implement in SwiftUI using the design system from `design.md`.
