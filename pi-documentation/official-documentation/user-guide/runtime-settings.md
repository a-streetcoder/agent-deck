# Runtime Settings, Models, and Environment

## Settings

Agent Deck has its own app settings stored in macOS `UserDefaults` under `agentDeckAppSettings`. These include project root, GitHub cache lifetime, Pi Agent notification delay, transcript visibility, terminal application path, and whether native subagents are enabled for new sessions.

Pi itself uses global and project settings files:

```text
~/.pi/agent/settings.json
PROJECT/.pi/settings.json
```

Agent Deck reads and writes selected fields, especially resource/package paths, prompts, and subagent override/configuration fields.

## Models

The Models screen shows Pi model information. Agent Deck can query the Pi CLI and Pi RPC model APIs. Prefer runtime RPC results when exact currently available models matter.

## Environment

Agent Deck scans:

```text
~/.pi/agent/.env
PROJECT/.pi/.env
```

Project environment values win over global values with the same key. Secret values are hidden by default in the UI.
