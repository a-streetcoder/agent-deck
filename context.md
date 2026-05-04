---
head: 584345607c26d3a527e4e190a6222b7aaa6c5b29
dirty: true
generatedAt: 2026-05-04T21:28:37Z
taskScope: pi-manager ask-user extension UI rendering and RPC response handling
changeSummarySincePrevious: previous cache was unrelated/stale; refreshed targeted context; working tree dirty in AppViewModel/ContentView/ExtensionManagement but relevant ask-user files inspected are not listed dirty
reusedCache: false
---

# Code Context

## Scope
Investigate why Pi Manager renders ask-user options but tapping a real option or custom response does not behave like Pi CLI/TUI/RPC expects.

## Files Retrieved
1. `pi-manager/PiAgentRunnerService.swift` (lines 92-104, 704-731) - sends extension UI responses and parses incoming UI requests.
2. `pi-manager/PiRPCClient.swift` (lines 56-64) - RPC command shape for `extension_ui_response`.
3. `pi-manager/PiAgentSessionModels.swift` (lines 283-299) - `PiAgentUIRequest` model.
4. `pi-manager/PiAgentViews.swift` (lines 394-400, 1320-1407) - card rendering and button actions.
5. `~/Library/Application Support/Pi Manager/agent-sessions.json` session `C10E3294-D29C-43C1-89A9-2521DE6D6BE4` entries 4-5, 17-18 - app transcript evidence.
6. `~/.pi/agent/sessions/--Users-andrea-Documents-GitHub--/2026-05-04T21-20-37-547Z_019df4dd-4eaa-75b9-a2d1-711764cfc631.jsonl` lines 7-15 - real session evidence.
7. `~/.pi/agent/extensions/ask-user/index.ts` (lines 1250-1313) - ask-user RPC/headless fallback behavior.
8. `node_modules/@mariozechner/pi-coding-agent/dist/modes/rpc/rpc-mode.js` (source map/source around RPC UI context) - expected RPC request/response protocol.

## Key Code
- App receives `extension_ui_request` and stores a `PiAgentUIRequest` only if method is `select|confirm|input|editor`; options are parsed only as `[String]`:
  ```swift
  if let requestMethod = PiAgentUIRequest.Method(rawValue: method), let requestID = event.id {
      let options: [String]
      if case let .array(values)? = event.options { options = values.compactMap(\.stringValue) } else { options = [] }
      store.setUIRequest(.init(id: requestID, sessionID: sessionID, method: requestMethod, title: title,
          message: event.message?.compactDescription, options: options, placeholder: event.placeholder, prefill: event.prefill))
      store.append(.init(sessionID: sessionID, role: .status, title: "Input Needed", text: title, rawJSON: rawLine))
  }
  ```
  `PiAgentRunnerService.swift:704-731`
- App sends select/input/editor responses as `{type:"extension_ui_response", id, value}` and immediately clears UI:
  ```swift
  func respondToExtensionUI(...) {
      clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: value)
      store.clearUIRequest(sessionID: sessionID, id: requestID)
  }
  ```
  `PiAgentRunnerService.swift:92-95`, `PiRPCClient.swift:62`
- UI card for `.select` blindly treats every option as final and submits its label:
  ```swift
  ForEach(request.options, id: \.self) { option in
      Button { onSubmitValue(option) } label: { Text(option) ... }
  }
  ```
  `PiAgentViews.swift:1345-1364`
- ask-user RPC fallback intentionally uses two-step custom flow:
  ```ts
  const selected = await ui.select(prompt, selectOptions, dialogOpts)
  if (selected === FREEFORM_SENTINEL) {
      const answer = await ui.input(prompt, "Type your answer...", dialogOpts)
      return createFreeformResponse(answer)
  }
  return createSelectionResponse([selected])
  ```
  `~/.pi/agent/extensions/ask-user/index.ts:1291-1304`
- Pi RPC protocol expects select response value to be the selected string, and will emit a *new* `extension_ui_request` for `input` if the sentinel is selected. `rpc-mode.js` parses `extension_ui_response` by `id` and resolves the pending request.

## Architecture
`pi --mode rpc` emits `extension_ui_request` for ask-user. Pi Manager maps that into one `PiAgentUIRequest` shown above the transcript. User taps -> `AppViewModel.respondToPiAgentUIRequest` -> `PiAgentRunnerService.respondToExtensionUI` -> `PiRPCClient.send(type:"extension_ui_response", fields:["id":id,"value":value])` -> Pi RPC resolves the pending dialog. For ask-user with freeform enabled, resolving the select with `✏️ Type custom response...` should cause ask-user to call `ui.input`, generating another `extension_ui_request` that Pi Manager should render as a text field.

## Start Here
Open `pi-manager/PiAgentViews.swift` at `PiAgentUIRequestCard` (`1320-1407`). The likely fix is in the select-option handling/rendering, then verify `PiAgentRunnerService.respondToExtensionUI`/`PiRPCClient.respondToExtensionUI` around response sending.

## Constraints And Risks
- Logs show the app got the ask-user requests correctly:
  - First request raw JSON: `method:"select"`, title `How old are you?`, options `["31","35","42","✏️ Type custom response..."]`.
  - Second request raw JSON includes context in title and same options.
- Logs do **not** show a resulting ask-user `toolResult` after user interaction in the GitHub-root session; transcript instead shows user steering text then stop. So the selection/custom response did not complete the tool from the app path.
- Likely product/UX bug: the app renders the sentinel `✏️ Type custom response...` as a normal final option. It should behave like CLI/TUI: tapping it should transition to/respond through the subsequent `input` request, not be treated as the final user answer. If Pi emits the input request after the sentinel, the app must not obscure/lose it; consider not clearing old UI until next request/response is observed or adding a local “waiting for custom input…” state.
- Possible protocol bug to test: `respondToExtensionUI` uses `clientsBySessionID[sessionID]?` optional chaining and clears the UI even if no live client exists or send fails. If the process already ended/restarted or client is missing, the user sees the card disappear but no response reaches Pi. Safer behavior: only clear after a known live client/send, or append/status on missing client.
- Options with descriptions are lost in app UI because `event.options` from RPC is only strings; the detailed option descriptions are present in `tool_execution_update.partialResult.details.options`, not in `extension_ui_request`. Rendering descriptions like TUI would need correlating with ask_user tool details or changing upstream RPC to include object options.
- Working tree is dirty (`AppViewModel.swift`, `ContentView.swift`, `ExtensionManagement.swift`); do not assume clean baseline.

## Pi-intercom handoff
No safe orchestrator target required; findings written to this file.
