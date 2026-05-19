# Agent guide

Agent Deck is a native macOS SwiftUI app that manages Pi coding-agent resources (agents, skills, prompts, settings) and runs Pi Agent sessions via Pi's JSONL RPC protocol.

**Stack:** Swift, SwiftUI, macOS 26 (Tahoe) + Liquid Glass, Xcode project with SPM (TourKit). No Package.swift at root — SPM is Xcode-integrated only.

**Build:**
```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

**Test:**
```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' test
```

## Critical constraints

- **Read-only builtins.** Never modify bundled resources; edits write override files.
- **Explicit write targets.** Never hide what the app writes. Report-only subagents produce artifacts, not project edits.
- **Explicit resource allowlists.** Agent Deck uses `--no-skills`, `--no-extensions`, `--no-prompt-templates`, `--no-themes` and selectively re-enables only assigned resources — never rely on Pi's ambient discovery.
- **Read source before editing.** Inspect actual files; don't trust stale plans. Cite source files or flag gaps; never invent behavior.
- **Scope visibility.** Every resource must display its scope (Builtin/Global/Library/Project) with color + icon + text, never color alone.
- **Secret safety.** `EnvPersistence` hides secrets by default. Never pass credentials as CLI args. Memory secret scanning blocks sensitive writes.

For detailed guidance, read the relevant guide before editing that area:

- **Product invariants & contributor rules:** `docs/agent-guidelines/INVARIANTS.md`
- **Architecture & data flow:** `docs/agent-guidelines/ARCHITECTURE.md`
- **SwiftUI & macOS UI conventions:** `docs/agent-guidelines/SWIFTUI.md`
- **Pi runtime integration (launch flags, skills, memory, models):** `docs/agent-guidelines/PI-RUNTIME.md`
- **Build, test & verification:** `docs/agent-guidelines/TESTING.md`

For canonical internal documentation, see `agent-deck-documentation/`. For official product documentation, see `pi-documentation/official-documentation/`.