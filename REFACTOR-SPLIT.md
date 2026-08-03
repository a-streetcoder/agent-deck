# refactor/startup-hotspots-tests — split map

Local branch for modularizing God objects. **Not pushed by default.**

## Commits (newest first)

| Commit | Change |
|--------|--------|
| (HEAD) | `PiAgentTranscriptAppKitViews` → RenderCache / Models / QuestionRail / Host / View |
| 0ccd266 | `PiAgentRunnerService` → Launch / TranscriptIO / RPC / Streaming / ExtensionBridge / Parse |
| 1ea1d41 | `PiAgentScreen` transcript → items / native / chrome |
| ff703bb | `PiAgentScreen` → Sessions / Layout / Transcript / Composer |
| ccae826 | `PiAgentViews` → AppKit transcript / session panel / composer panel |
| a9e6c88…ffdd546 | `AppViewModel` domain extensions + repository* rename |
| earlier | Computer Use removal, composer queue policy, startup perf, tests |

## Target shapes

### AppViewModel
- Core: stored state + `init` / `shutdown` (~600–700 LOC)
- `AppViewModel+*.swift`: Projects, Terminal, Settings, Subagents, Session*, Memory, Refresh, Agents, Skills, Prompts, Loops, Slash, Models, AutoRefresh, Env, Warnings, Repository, …

### PiAgentScreen
- `PiAgentViews.swift`: state + `body`
- `PiAgentScreen+Sessions|Layout|Composer|Transcript*`

### PiAgentRunnerService
- Core: clients, stream buffers, public start/send/stop/controls
- `+Launch` — process start, watchdog, idle parking
- `+TranscriptIO` — session file / user payload / stderr
- `+RPC` — inbound event routing + response commands
- `+Streaming` — flush, tools, compaction, rehydrate
- `+ExtensionBridge` — extension UI + Deck bridges
- `+Parse` — extract text / termination / mark status


### PiAgentTranscript AppKit stack
- `PiAgentTranscriptRenderCache.swift` — cache + stack + picker stress
- `PiAgentTranscriptModels.swift` — timeline / cell kind / row item / rail policy
- `PiAgentTranscriptQuestionRail.swift` — table chrome, question rail, jump-to-latest
- `PiAgentTranscriptHost.swift` — SwiftUI host isolating cache observation
- `PiAgentTranscriptAppKitViews.swift` — `NSViewRepresentable` shell + Coordinator stored state + cell views
- `PiAgentAppKitTranscriptCoordinator+DataSource.swift` — data source / prewarm / question rail
- `PiAgentAppKitTranscriptCoordinator+Apply.swift` — apply snapshot / benches / scroll observation
- `PiAgentAppKitTranscriptCoordinator+Layout.swift` — width / height / anchors
- `PiAgentAppKitTranscriptCoordinator+Scroll.swift` — follow glide / pin / table delegate

## Merge guidance

1. Build: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug CODE_SIGNING_ALLOWED=NO build`
2. Prefer merge/rebase onto current `main` before PR (this branch may lag `main` UI fixes).
3. Do **not** force-push rewrite unless explicitly requested.
4. Default delivery stays local commits only.

## Out of scope on this branch

- Behavioral product features (except incidental renames like `repository*`)
- Sparkle / signing
- History squash of the 18+ refactor commits (optional later)
