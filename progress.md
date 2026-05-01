# Progress

## Status
In Progress

## Tasks
- Inspected Pi Agent composer/input code and Pi RPC message sending path.

## Files Changed
- `/tmp/pi-manager-composer-scout.md` - Scout findings for image paste attachments.
- `progress.md` - Progress update.

## Notes
- Composer starts in `pi-manager/PiAgentViews.swift`; text flows through `AppViewModel.sendPiAgentMessage`, `PiAgentRunnerService.send/start`, `PiRPCClient.prompt`, then `PiAgentProcess.writeJSONLine`.
- Need confirm Pi RPC attachment payload schema before implementation.

2026-05-01T10:54:55Z - Scout: inspected installed pi-coding-agent docs/source for CLI/RPC image attachment formats. Findings written to /tmp/pi-attachments-scout.md. Key result: CLI uses @file paths for initial messages; RPC uses inline images array with {type:"image", data:base64, mimeType}. 
- 2026-05-01T10:55:22Z: Completed t3code chat composer attachments scout; wrote /tmp/t3code-attachments-scout.md
