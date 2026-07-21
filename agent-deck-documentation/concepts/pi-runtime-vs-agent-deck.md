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

## Pi updates

The Doctor detects how the resolved Pi executable was installed and always shows the current version, the latest official Pi release, and the latest release available through that installation source. A Homebrew installation checks Homebrew's formula version; Bun, npm, pnpm, Yarn, and other self-managed installations follow Pi's official release channel.

Only a release available through the detected source is actionable. Homebrew's formula API supplies the Homebrew version, while Bun, npm, pnpm, and Yarn use the package version published in the npm registry. If an official Pi release is newer than the detected source, the Doctor shows both versions and a waiting state, but does not offer or automatically run an update that cannot deliver it. Updates preserve the installation method: a Homebrew-owned Pi runs `brew upgrade pi-coding-agent`; other existing installations, including pi.dev curl installs, run `pi update pi`, whose updater preserves supported global package managers including Bun.

For a missing Pi, Agent Deck installs only through pi.dev's official package-manager methods: npm, then pnpm, then Bun. If none is available, it opens Pi's official curl installer in Terminal. It never installs Pi through Homebrew, but continues to recognize and update existing Homebrew and Yarn installations.

Agent Deck searches Bun's default `~/.bun/bin/pi` path as well as `BUN_INSTALL/bin/pi` and the configurable `BUN_INSTALL_BIN` location. It also searches `PNPM_HOME` plus macOS pnpm homes (`~/Library/pnpm`, `~/Library/Application Support/pnpm`, and `~/.local/share/pnpm`), common npm prefixes (including `~/.local` and `~/.hermes/node`), the process `PATH`, and explicit Agent Deck Pi path overrides.

An updater exit code of zero is not enough to report success. Agent Deck probes the same resolved executable again and requires its installed version to meet or exceed the source-specific target release.

The manual Doctor flow refreshes runtime status after a verified update. The launch auto-updater uses the same shared installer, and an already-open Doctor refreshes when that background update completes.

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
