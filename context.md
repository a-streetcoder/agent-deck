---
head: a6a8d6ec774e6d202fe05801d1e6382193b98fd8
dirty: true
generatedAt: 2026-05-03T07:07:16Z
taskScope: SwiftUI Models, MCP, Diagnostics screens and PiScanner duplicate-warning simplification targets
changeSummarySincePrevious: previous cache was unrelated/stale; HEAD changed in SwiftUI/design files, refreshed targeted context
reusedCache: false
---

# Code Context

## Scope
Concise recommendations and exact edit targets for simplifying nested cards in Models/MCP/Diagnostics while staying within existing `DesignSystem`, plus scanner duplicate-warning target.

## Files Retrieved
1. `pi-manager/ContentView.swift` (lines 1269-1354) - `ModelsScreen` grid, explanatory card, nested provider groups with `AppRowCard` per model.
2. `pi-manager/ContentView.swift` (lines 3208-3339) - `MCPScreen` intro/summary/impact cards, per-config cards, `AppRowCard` agents list, helper funcs.
3. `pi-manager/ContentView.swift` (lines 3341-3477) - `DiagnosticsScreen`, per-settings card with internal sections/dividers, warning grouping, `warningSection`.
4. `pi-manager/DesignSystem.swift` (lines 1-144) - existing primitives: `AppPage`, `AppCard`, `AppMetricTile`, `AppLabelTag`, `AppKeyValueList`; use these rather than new visual language.
5. `pi-manager/PiScanner.swift` (lines 720-784, 830-863) - agent resolution precedence and duplicate warning generation.
6. `pi-manager/Models.swift` (lines 274-320) - `MCPConfigRecord`, `AvailableModel`, `ScanSnapshot` inputs used by screens.

## Key Code
- `ModelsScreen` (`ContentView.swift:1269`) currently has 3 card layers for catalog: `AppCard("Catalog")` -> provider `VStack` group -> `AppRowCard` for each model (`1312-1341`). Good simplification target: keep one `AppCard` and render provider headers + flat rows without row-card backgrounds, or extract `ModelCatalogSection`/`ModelRow` using plain `HStack` + `Divider`.
- `MCPScreen` (`3208`) has redundant education cards: `How MCP Access Works` (`3213`) and `How MCP Affects Agents` (`3232`) say essentially the same thing. Merge into one concise `AppCard`, keep `Summary` as `AppKeyValueList`.
- `MCPScreen` per config (`3245-3282`) is `AppCard` with nested keyed list + server rows. This is acceptable; simplify by removing extra nested `VStack` styling and using a helper `mcpConfigCard(_:)`/`serverRow(_:)` with plain rows and dividers. `Agents with Direct MCP Tools` (`3285-3304`) nests `AppRowCard`; replace with plain rows inside the single `AppCard`.
- `DiagnosticsScreen` (`3341`) has `AppCard` per settings file with several nested `VStack`s and `AppRowCard` for each override (`3414-3425`). Keep settings as card but extract `settingsCard(_:)`, `settingsSection(title:empty:rows:)`, and render overrides as plain monospaced rows; avoid `AppRowCard` inside `AppCard`.
- `warningSection` (`3461-3477`) is already a good lightweight pattern; reuse this approach for row sections instead of adding more cards.
- Duplicate warnings are built from `Dictionary(grouping: rawAgents, by: \.name).filter { $0.value.count > 1 }` (`PiScanner.swift:846`) and emit every duplicate agent name (`852-854`). Because `resolveAgents` intentionally has precedence project > global > builtin (`PiScanner.swift:743-746`), warning text could be less alarming or filtered to actionable duplicates.

## Architecture
`ContentView` routes sidebar destinations to the three screens (`ContentView.swift:357-387`). Screens are read-only views over `AppViewModel`/`ScanSnapshot`. `PiScanner.scan` builds `ScanSnapshot`, `resolveAgents` computes effective agents, and `buildWarnings` populates diagnostics. Design primitives live in `DesignSystem.swift`; no need for new card components unless duplicated plain row/section code becomes noisy.

## Start Here
Open `pi-manager/ContentView.swift` at `ModelsScreen` (`1269`) first. Apply the same pattern: keep top-level `AppCard`s, remove `AppRowCard` nested inside them, extract small private row/section helpers.

## Constraints And Risks
- Do not replace `AppCard`, `AppKeyValueList`, `AppMetricTile`, or `AppLabelTag`; simplification should reduce nested surfaces, not invent a new design system.
- Keep scan/data behavior unchanged for UI-only cleanup.
- If changing duplicate warnings, edit only `PiScanner.buildWarnings` unless product wants new warning categories. Safer first pass: change message to explain resolution precedence, or warn only when duplicate records are in the same effective precedence bucket/scope.
- Exact edit functions/files: `ModelsScreen.body` + `groupedModels` helpers (`ContentView.swift:1269-1354`), `MCPScreen.body`/helpers (`3208-3339`), `DiagnosticsScreen.body` + `warningSection` vicinity (`3341-3477`), optional `PiScanner.buildWarnings` (`830-863`).

## Pi-intercom handoff
No safe orchestrator target required; findings written here.
