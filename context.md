---
head: d063bb4168f1329387cf76e40bc6b4a5bb44715f
dirty: false
generatedAt: 2026-05-04T22:15:05Z
taskScope: notification management/handling in pi-manager app
changeSummarySincePrevious: previous cache scope unrelated; refreshed from clean working tree
reusedCache: false
---

# Code Context

## Scope
Notifications/attention handling: local macOS user notifications, in-app badges, state/storage, scheduling/listening, and related control config copy.

## Files Retrieved
1. `pi-manager/AppViewModel.swift` (lines 1-82, 91-106, 1064-1123) - imports `UserNotifications`, owns notification task state, Pi Agent attention flow, permission request, local notification send.
2. `pi-manager/PiAgentRunnerService.swift` (lines 1-16, 367-391) - emits `onTurnFinished` from `agent_end`/`turn_end` events.
3. `pi-manager/PiAgentSessionModels.swift` (lines 93-127, 153-201, 245-249) - persisted `needsAttention` and `lastNotificationAt` fields.
4. `pi-manager/PiAgentSessionStore.swift` (lines 1-18, 48-76, 114-121) - session JSON store in Application Support and update/save path.
5. `pi-manager/ContentView.swift` (lines 72-75, 798-851, 355-363, 4495-4513, 6069-6073) - sidebar badge and unrelated internal `NotificationCenter` skill-import event.
6. `pi-manager/PiAgentViews.swift` (lines 262-266, 2679-2699) - filters attention sessions and session-row bell indicator.
7. `pi-manager/pi_managerApp.swift` (lines 8-24) - app delegate only activates window; no notification delegate/response handling.
8. `pi-manager/Models.swift` (lines 1-6, 45-48), `pi-manager/PiScanner.swift` (lines 715-719), `pi-manager/EnvPersistence.swift` (lines 18-22), `pi-manager/ContentView.swift` (lines 2062-2084, 5513-5549, 6214-6218) - subagent control config fields/copy mentioning notify channels, not wired to OS notifications.

## Key Code
- `AppViewModel` has `pendingPiAgentNotificationTasks: [UUID: Task<Void, Never>]` and `piAgentNotificationDelay = 60` at `AppViewModel.swift:81-82`.
- Runner callback is set in init: `piAgentRunner.onTurnFinished = { ... handlePiAgentTurnFinished(sessionID) }` (`AppViewModel.swift:100-102`).
- On turn finish, if session exists and is not actually visible, it sets `record.needsAttention = true` then schedules notification (`AppViewModel.swift:1075-1082`). Visibility requires app active, Pi Agent sidebar selected, selected session ID matching, and visible key/main window (`AppViewModel.swift:1085-1090`).
- Scheduler cancels/replaces existing task per session, sleeps 60s, then calls `sendPiAgentCompletionNotificationIfNeeded` on main actor (`AppViewModel.swift:1092-1102`).
- Before sending, it removes task, rechecks session exists, `needsAttention`, and not visible; then writes `lastNotificationAt = Date()` and sends (`AppViewModel.swift:1104-1111`).
- OS notification requests authorization every send with `[.alert, .badge]`, creates immediate `UNNotificationRequest` with title `Pi Agent needs review`, body `session.displayTitle`, and `userInfo["sessionID"]` (`AppViewModel.swift:1114-1123`). No badge number is set.
- Selecting/acknowledging a session cancels pending task and clears `needsAttention` (`AppViewModel.swift:1057-1072`).
- `PiAgentRunnerService.handle(rawLine:event:sessionID:)` calls `onTurnFinished?(sessionID)` for both `agent_end` and `turn_end` (`PiAgentRunnerService.swift:387-391`).
- Session fields `needsAttention`/`lastNotificationAt` are codable and persist in `~/Library/Application Support/Pi Manager/agent-sessions.json` via `PiAgentSessionStore` (`PiAgentSessionStore.swift:14-18`).

## Architecture
Pi RPC event stream -> `PiAgentRunnerService` marks turn idle and invokes `onTurnFinished` -> `AppViewModel` decides whether the active session is visible -> persists `needsAttention` -> schedules a delayed task -> after 60s revalidates and posts a macOS local notification through `UNUserNotificationCenter`. UI reads the same store state for sidebar badge (`ContentView.swift:798-851`), attention-only filtering (`PiAgentViews.swift:262-266`), and row bell (`PiAgentViews.swift:2679-2699`).

There is also Swift `NotificationCenter` usage for an in-process skill import toolbar event only (`ContentView.swift:355-363`, `4495-4513`, `6069-6073`); it is unrelated to user notifications.

## Start Here
Open `pi-manager/AppViewModel.swift` at `handlePiAgentTurnFinished` (`1075`) through `sendPiAgentCompletionNotification` (`1123`); it contains nearly all OS notification behavior.

## Constraints And Risks
- Suspicious: no `UNUserNotificationCenterDelegate` or notification response handling exists; clicking a notification likely will not select/open the session despite `userInfo["sessionID"]`.
- Suspicious: authorization is requested lazily on every send; no centralized permission state/UI, no error handling from `requestAuthorization` or `add`.
- Suspicious: `.badge` authorization is requested but no app badge count is set/cleared.
- Suspicious: `lastNotificationAt` is written before `UNUserNotificationCenter.add`; if add fails/permission denied, state still implies notification happened.
- Suspicious: both `agent_end` and `turn_end` trigger the same callback; if both fire for one turn, the second cancels/restarts the pending 60s task and delays/duplicates attention logic.
- Pending tasks are in memory only; app restart preserves `needsAttention` but not scheduled notifications.
- `isPiAgentSessionActuallyVisible` depends on selected sidebar/session and key/main window; minimized/background app sessions become attention notifications as intended, but multi-window/focus edge cases may misclassify.
- Subagent `control.notifyChannels` and `needsAttentionAfterMs` are config/documentation for pi/subagents, not connected to the app’s 60s local notification delay.

## Pi-intercom handoff
No safe orchestrator target provided; no intercom handoff sent.
