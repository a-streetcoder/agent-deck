# Project Types & Dev-Server Controls

Summary of the feature added on branch `claude/project-type-server-controls-0wzAa`.

## What changed

### 1. Project-type recognition

- New `ProjectType` enum (`agent-deck/ProjectType.swift`) — the single source of
  truth for what kind of project a folder is. Detection moved out of
  `ProjectDiscovery` into `ProjectType.detect(...)`.
- Expanded from 6 to 11 recognised types: added **Go, Python, Ruby, Static
  Site** (Tauri and Electron were also split into separate types).
- `DiscoveredProject` now carries a real `projectType` value.
- `ProjectIconView` renders a **custom asset-catalog image** for the type when
  one exists, and otherwise falls back to the built-in SF Symbol. Today no
  custom artwork ships, so every icon is still an SF Symbol — dropping artwork
  into `Assets.xcassets` later upgrades it automatically (see below).

### 2. Dev-server controls

- New **"Dev Server"** button in the Pi Agent toolbar opens a popover to
  **start / stop / restart** the selected project's dev server.
- Commands are auto-detected: `package.json` scripts (`dev`, `start`, `serve`),
  Rust (`cargo run`), Django (`manage.py runserver`), and static sites
  (`python3 -m http.server`).
- The popover shows live status and a clickable `localhost` URL parsed from the
  server's output.
- If another running server already uses the same port, those conflicting
  servers are listed with their own Stop buttons.
- Running servers are terminated when the app quits.
- New files: `ProjectServerService.swift`, `ProjectServerToolbarButton.swift`,
  `ProjectServerPopover.swift`.

> Note: this is a macOS app and was not compiled in this environment — build
> and test it in Xcode on a Mac.

## Custom symbols you can add

The app looks for an `Assets.xcassets` entry named **`project-<type>`** for each
project type. If the asset exists it is used; if not, the SF Symbol fallback is
shown. **Adding artwork requires no code change.**

To add one: in Xcode open `agent-deck/Assets.xcassets`, create a new **Image
Set**, and name it **exactly** as listed below (names are case-sensitive — note
the camelCase in `project-swiftPackage` and `project-staticSite`). Icons render
square at roughly 24–34 pt, so supply PNGs at @1x/@2x/@3x or a single PDF/SVG.

| Asset name to create | Project type | Detected by (files in project root) | Current SF Symbol fallback |
|---|---|---|---|
| `project-xcode`        | Xcode         | `.xcodeproj` / `.xcworkspace` (within 2 levels) | `apple.logo` |
| `project-nextjs`       | Next.js       | `next.config.js` / `.mjs` / `.ts`               | `globe` |
| `project-tauri`        | Tauri         | `tauri.conf.json`                               | `macwindow` |
| `project-electron`     | Electron      | `electron-builder.json` / `electron.vite.config.ts` | `macwindow` |
| `project-swiftPackage` | Swift Package | `Package.swift`                                 | `shippingbox` |
| `project-go`           | Go            | `go.mod`                                        | `chevron.left.forwardslash.chevron.right` |
| `project-rust`         | Rust          | `Cargo.toml`                                    | `gearshape.2` |
| `project-python`       | Python        | `pyproject.toml` / `requirements.txt` / `manage.py` / `setup.py` / `Pipfile` | `terminal` |
| `project-ruby`         | Ruby          | `Gemfile` / `Rakefile` / `.ruby-version`        | `diamond` |
| `project-staticSite`   | Static Site   | `_config.yml` / `astro.config.*` / `mkdocs.yml` / `index.html` | `doc.richtext` |
| `project-node`         | Node          | `package.json`                                  | `curlybraces` |

Projects that match nothing are classed as **Unknown** — they have **no custom
asset slot** and always use the `folder` SF Symbol.

You do not need to add all of them. Any asset you skip simply keeps its SF
Symbol fallback.
