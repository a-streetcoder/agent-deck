# Build From Source

Pi Manager is a macOS SwiftUI application. The repository currently contains an Xcode project, source files, bundled starter agents, tests, and a macOS CI workflow.

## Prerequisites

- macOS with Xcode installed
- the Pi CLI available as `pi` for in-app agent sessions
- Git for project discovery/status features
- optional: GitHub CLI (`gh`) for GitHub authentication workflows

The app can still open without every optional tool, but diagnostics and some screens will report missing dependencies.

## Clone and open

```bash
git clone <repo-url> pi-manager
cd pi-manager
open pi-manager.xcodeproj
```

## Command-line build

```bash
xcodebuild \
  -project pi-manager.xcodeproj \
  -target pi-manager \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Run tests

```bash
xcodebuild \
  -project pi-manager.xcodeproj \
  -scheme pi-manager \
  -destination 'platform=macOS' \
  test
```

At the time of writing, the visible test target includes model-discovery parsing tests.

## Verify Pi CLI discovery

Pi Manager resolves `pi` from:

1. `PI_MANAGER_PI_PATH`
2. `PI_CLI_PATH`
3. shell `command -v pi`
4. common install locations, including NVM-managed installs

If the app cannot start Pi Agent sessions, set `PI_MANAGER_PI_PATH` to the exact `pi` executable path before launching from a shell.

## Application data

Pi Manager stores app-owned session and native subagent data in:

```text
~/Library/Application Support/Pi Manager/
```

Native subagent artifacts are stored under:

```text
~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/
```
