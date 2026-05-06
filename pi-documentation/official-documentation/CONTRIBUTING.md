# Contributing to Pi Manager

Thanks for contributing. This file summarizes the contributor workflow; detailed verification lives in `contributors/development-and-verification.md`.

## Setup

1. Install Xcode on macOS.
2. Clone the repository.
3. Install or configure the Pi CLI if you need Pi Agent/runtime features.
4. Optionally install GitHub CLI (`gh`) for GitHub integration testing.

## Build

```bash
xcodebuild -project pi-manager.xcodeproj -target pi-manager -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Contribution expectations

- Keep user-visible write targets explicit.
- Preserve builtin read-only behavior.
- Update official docs when behavior changes.
- Prefer small, focused PRs with clear validation notes.
- Mark unvalidated changes honestly.

## Documentation expectations

Official docs live in this `pi-documentation/official-documentation/` tree. Planning docs outside this tree may be useful context but should not be treated as maintained public truth unless promoted and reviewed.
