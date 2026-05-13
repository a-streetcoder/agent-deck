# Resource refresh and file watching

Agent Deck keeps its resource catalog current without continuously scanning every few seconds.

## What refresh means

`AppViewModel.refresh()` asks `AppRefreshService` to rebuild the app's current view of:

- discovered projects
- global and project agents
- skills and external skill roots
- prompt templates
- settings and `.env` metadata
- scanner warnings

This refresh does **not** refresh the model catalog. Models are loaded separately through `pi --list-models`.

## Primary path: filesystem events

While the app is active, Agent Deck creates a macOS FSEvents watcher for the current watched roots.

The watched roots are derived from the same paths used by the scanner, including:

- `~/.pi/agent` resource folders
- legacy `~/.agents` paths
- selected project `.pi` resource folders
- selected project `.agents`
- imported external skill paths
- directories containing currently discovered agent, skill, and prompt files

When FSEvents reports a change, Agent Deck waits briefly before doing any work.

Current debounce:

```text
1 second
```

This coalesces save bursts, formatter writes, and directory updates into one check.

## Fingerprint check after an event

After the debounce, Agent Deck computes a lightweight fingerprint for watched files and directories.

The fingerprint tracks modification dates for relevant resource files such as:

- `.env`
- `SKILL.md`
- `.md`
- `.json`

If the fingerprint is unchanged, no refresh runs.
If the fingerprint changed, Agent Deck runs `refresh(includeModels: false)`.

This means FSEvents is used as the trigger, but the fingerprint still protects the app from unnecessary refreshes caused by broad or noisy filesystem events.

## Watch list updates

Every successful refresh updates the watched URL list.

This matters because resource discovery can change the watch set. For example:

- a new external skill root is imported
- a project selection changes
- a resource file appears or disappears
- a settings file points at different package/resource paths

The watcher is restarted only when the normalized watched paths actually change.

## Fallback safety poll

Agent Deck also keeps a slow fallback check while the app is active.

Current interval:

```text
5 minutes
```

This is not the main refresh mechanism. It exists to cover edge cases where filesystem events can be missed or become unreliable, such as:

- watched folders being deleted and recreated
- permission changes
- app activation gaps
- network or external volumes
- watcher setup failures

The old aggressive behavior was a fingerprint scan every few seconds. That path has been replaced by event-driven refresh plus this low-frequency safety check.

## App lifecycle

File watching starts when Agent Deck is active and stops when the app resigns active or shuts down.

Stopping cancels:

- the FSEvents stream
- any pending debounce task
- the fallback timer
- any pending fingerprint task when requested by shutdown/inactive handling

## Implementation map

- `agent-deck/AppRefreshService.swift`
  - `FileWatchFingerprint`
  - `FileWatchEventMonitor`
  - watched URL calculation
- `agent-deck/AppViewModel.swift`
  - watcher lifecycle
  - debounce scheduling
  - fallback timer
  - refresh trigger
