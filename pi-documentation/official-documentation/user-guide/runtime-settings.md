# Runtime Settings, Models, Extensions, and Environment

## Settings

Pi Manager has its own app settings stored in macOS `UserDefaults` under `piManagerAppSettings`. These include project root, GitHub cache lifetime, Pi Agent notification delay, transcript visibility, terminal application path, and whether native subagents are enabled for new sessions.

Pi itself uses global and project settings files:

```text
~/.pi/agent/settings.json
PROJECT/.pi/settings.json
```

Pi Manager reads and writes selected fields, especially resource/package paths, extension toggles, prompts, and subagent override/configuration fields.

## Models

The Models screen shows Pi model information. Pi Manager can query the Pi CLI and Pi RPC model APIs. Prefer runtime RPC results when exact currently available models matter.

## Extensions

Pi extensions are TypeScript/JavaScript modules loaded by Pi. Pi Manager scans package/local extensions and writes explicit enable/disable entries with `+` and `-` settings modifiers instead of deleting files.

A changed extension setting usually affects new sessions or sessions after Pi reload, not already-running child processes.

## Environment

Pi Manager scans:

```text
~/.pi/agent/.env
PROJECT/.pi/.env
```

Project environment values win over global values with the same key. Secret values are hidden by default in the UI.
