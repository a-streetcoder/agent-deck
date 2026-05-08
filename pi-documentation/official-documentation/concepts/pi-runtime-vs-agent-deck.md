# Pi Runtime vs Agent Deck

Agent Deck is a companion app around Pi, not a fork of Pi.

## Pi runtime

Pi provides:

- CLI and TUI modes
- JSONL RPC mode
- sessions and session files
- provider/model/auth settings
- extension loading
- prompt templates
- skills
- themes and keybindings
- package discovery

Agent Deck launches the installed `pi` executable and uses public runtime surfaces where possible.

## Agent Deck

Agent Deck provides:

- native macOS UI for scanning and editing Pi resources
- project and GitHub workflows
- native SwiftUI Pi Agent session UI over `pi --mode rpc`
- app-managed native subagent runtime
- app-owned artifacts, run graphs, transcripts, supervisor requests, and worktrees
- safer library/active resource management

## Important distinction: subagents

Parent Pi sessions receive generated bridge tools such as `managed_subagent`, while the app launches and tracks child Pi RPC processes itself.

## MCP note

Pi core intentionally does not provide built-in MCP. MCP-like or direct tool behavior is extension/package/app-specific. In Agent Deck docs, fields such as `mcpDirectTools` are Agent Deck/native-subagent integration concepts, not Pi core MCP guarantees.
