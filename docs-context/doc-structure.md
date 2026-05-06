# Proposed official modular documentation structure for pi-manager

## Scope and current-state findings

- There is currently **no root README** (`find . -iname 'readme*'` returned no matches). This is the highest-priority public-doc gap.
- `pi-documentation/official-documentation/` exists but is empty. It is a natural target for future official docs if the project owner wants to keep exploratory/reference notes separate.
- Existing docs are split between:
  - root planning/status docs: `pi-manager-spec.md`, `PI_MANAGER_NATIVE_SUBAGENTS_PLAN.md`, `PI_MANAGER_*`, `plan.md`, `progress.md`, `research.md`, `manual-verification.md`
  - technical reference docs under `pi-documentation/`
  - deprecated package-era docs under `pi-documentation/Deprecated-old-pi-subagents-and-intercom/`
- The app already has an in-app Docs screen with tabs `Core System`, `Skills`, `Prompts & Commands`, `Agents & Chains`, `Architecture`, `Intercom` (`pi-manager/ContentView.swift:4592-4638`). Some strings appear stale relative to native subagents, e.g. builtin agents shown as `<pi-subagents package>/agents/*.md` (`pi-manager/ContentView.swift:4654-4668`) while newer docs say bundled native agents are app-bundled builtins.
- Current sidebar concepts are a useful public IA source: Workspace (`Projects`, `GitHub`), Pi Resources (`Agents`, `Chains`, `Skills`, `Prompts`), Runtime (`Extensions`, `Models`, `Settings`, `Environment`, `Diagnostics`), Reference (`Docs`) (`pi-manager/AppViewModel.swift:3850-3907`).

## Relevant source-backed product facts to preserve in official docs

- Product purpose: `pi-manager` is a native macOS app for browsing, understanding, editing, and creating Pi resources; it is not a generic prompt manager (`pi-manager-spec.md:3-18`).
- Core product goals include showing effective resolved agents, safe builtin overrides, skill assignment/inheritance, project/global precedence, safe writes, and missing dependency diagnostics (`pi-manager-spec.md:21-36`).
- Target users in current spec are Pi power users and repo developers (`pi-manager-spec.md:85-99`). Public docs should add a third explicit audience: **LLM contributors/agents** working on the repo.
- Current app resource scopes are `Builtin`, `Global`, `Project`, `Legacy Project`, `Override`, `Package`, and `Library` (`pi-manager/Models.swift:55-63`).
- Agent config fields exposed by the model include `model`, `fallbackModels`, `thinking`, `systemPromptMode`, `inheritProjectContext`, `inheritSkills`, `defaultContext`, `tools`, `mcpDirectTools`, `extensions`, `skills`, `output`, `defaultReads`, `defaultProgress`, `interactive`, `maxSubagentDepth`, and unknown preserved fields (`pi-manager/Models.swift:73-119`).
- Effective agent resolution tracks builtin/global/project records plus global/project overrides and resolution kinds like `Builtin + Override`, `Global Replacement`, and `Project Replacement` (`pi-manager/Models.swift:156-184`).
- Scanner paths currently include global/project/library agents, chains, skills, prompts, settings, env, package skills, runtime commands, and warnings (`pi-manager/PiScanner.swift:6-122`). These paths should be documented as the app's source of truth, not just historical Pi/package behavior.
- App resource-management docs intentionally distinguish Pi runtime discovery from Pi Manager's narrower library/active/project/symlink model (`pi-documentation/pi-manager-resource-management.md:1-17`, `21-35`).
- Pi Manager app-managed chains live in `~/.pi/agent/chains/*.chain.md`, `~/.pi/agent/agent-library/chains/*.chain.md`, and `PROJECT/.pi/chains/*.chain.md`; the docs warn the app does **not** actively discover legacy chain files in `.agents/` (`pi-documentation/pi-manager-resource-management.md:101-118`).
- Skills have subtle discovery rules (`.pi/skills` accepts root `.md` and `SKILL.md` dirs; `.agents/skills` ignores root `.md`) that deserve their own page (`pi-documentation/pi-skills-discovery.md:19-65`).
- Native subagents are app-managed child Pi RPC sessions, not package `/run`; the app owns run records, transcripts, artifacts, supervisor requests, worktrees, chains, and parallel graphs (`pi-documentation/native-subagents.md:1-17`).
- Bundled starter agents are `scout`, `planner`, `worker`, `reviewer` and are treated as global builtins replaceable/disableable by same-name custom agents or overrides (`pi-documentation/native-subagents.md:19-30`; `pi-documentation/pi-manager-resource-management.md:89-97`).
- Native expected outcome policy is central to safety: report-only artifacts by default; worktree edits; explicit project-file writes; direct project writes only after approval (`pi-documentation/native-subagents.md:44-56`).
- Read-first files are hints/current-file reads, not injected stale context (`pi-documentation/native-subagents.md:57-70`).
- Prompt/command docs should explain the slash-command distinction: built-ins, extension commands, prompt templates, skill commands (`pi-documentation/pi-commands-and-prompt-templates.md:1-29`).

## Intended audiences

### 1. End users / operators
People who install Pi Manager to inspect and manage Pi resources. They need:
- quick install/build/run instructions
- explanation of what Pi Manager manages and what it does not
- safe mental models for global vs project vs library resources
- recipes for creating/overriding agents, assigning skills, running native subagents, configuring env/extensions/models
- troubleshooting and diagnostics

### 2. Repo contributors / app developers
Humans changing Swift code, docs, workflows, or scanner/runtime behavior. They need:
- architecture overview
- source map and data flow
- coding/build/test/manual verification instructions
- contribution standards and release process
- where docs must be updated when behavior changes

### 3. LLM contributors / agentic workers
LLM agents working in the repo. They need machine-readable high-signal context:
- `AGENTS.md`/contributor instructions at repo root
- docs index with canonical source-of-truth files
- architecture map with stable file paths and validation commands
- guardrails around no-edit/report-only vs write tasks, native subagent safety, and stale-plan avoidance
- issue/PR task templates and review checklist

## Recommended official file tree

Recommended: create a conventional public `docs/` directory for official docs, and either migrate or link current `pi-documentation/` content into it. Keep old exploratory/planning docs outside official docs or under an explicit archive.

```text
README.md
AGENTS.md
CONTRIBUTING.md
CODE_OF_CONDUCT.md
SECURITY.md
CHANGELOG.md
LICENSE

docs/
  README.md
  index.md
  getting-started/
    installation.md
    build-from-source.md
    first-run.md
    upgrade-and-uninstall.md
  user-guide/
    overview.md
    projects.md
    agents.md
    chains.md
    skills.md
    prompts-and-commands.md
    native-subagents.md
    extensions.md
    models.md
    settings.md
    environment.md
    diagnostics.md
    github-integration.md
  concepts/
    resource-scopes.md
    resource-resolution.md
    library-vs-active-resources.md
    pi-runtime-vs-pi-manager.md
    safety-and-write-policy.md
  reference/
    file-locations.md
    agent-frontmatter.md
    chain-format.md
    skill-discovery.md
    prompt-template-format.md
    native-subagent-api.md
    mcp-and-extensions.md
    troubleshooting.md
  contributors/
    architecture.md
    source-map.md
    development-setup.md
    testing-and-verification.md
    release-process.md
    documentation-style-guide.md
    llm-contributor-guide.md
  recipes/
    create-agent.md
    override-builtin-agent.md
    assign-skill-to-project.md
    run-report-only-subagent.md
    run-worker-in-worktree.md
    configure-env-and-mcp.md
  archive/
    deprecated-pi-subagents-package-flow.md
    old-intercom-flow.md
```

### Why this structure

- `README.md` should be the landing page for GitHub and search results. It should not try to be a full manual.
- `docs/index.md` should be the canonical doc map and should distinguish user docs, contributor docs, and low-level reference.
- `user-guide/` should follow UI tasks and sidebar concepts.
- `concepts/` should explain mental models that span multiple features.
- `reference/` should hold exact formats, paths, and behavior details.
- `contributors/` should target app maintainers and LLM agents changing code.
- `recipes/` should provide short task-oriented walkthroughs.
- `archive/` should keep deprecated package-era docs accessible without presenting them as current truth.

## Content outline

### `README.md`

Audience: all users, first-time visitors.

Outline:
- What Pi Manager is: native macOS manager for Pi resources.
- Current status: open-source app, current supported macOS/Xcode/Pi assumptions.
- Screens/features summary:
  - Projects/GitHub
  - Agents/chains/skills/prompts
  - Native subagents
  - Extensions/models/settings/env/diagnostics
- Install/build quickstart.
- First run: select project, refresh scan, inspect warnings.
- Safety promise: visible write targets; report-only native runs default to artifacts.
- Link map: User Guide, Contributor Guide, Reference, Troubleshooting.
- Project status / roadmap link.

### `AGENTS.md`

Audience: LLM contributors and human contributors who use agentic tools.

Outline:
- Repo purpose and non-goals.
- High-level source map.
- Rules for editing: preserve safety semantics, do not silently write project files, verify scanner/runtime behavior from code.
- Required reads for common tasks:
  - docs changes: `docs/index.md`, `docs/contributors/documentation-style-guide.md`
  - scanner changes: `pi-manager/PiScanner.swift`, `pi-documentation/pi-manager-resource-management.md`
  - native subagent changes: `pi-manager/PiSubagentRunService.swift`, `pi-documentation/native-subagents.md`
- Validation commands:
  - `xcodebuild -project pi-manager.xcodeproj -target pi-manager -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
  - focused tests where available
- Escalation/decision rules for product behavior.

### `CONTRIBUTING.md`

Audience: human app/doc contributors.

Outline:
- Development setup prerequisites: macOS, Xcode 26.4+ as implied by CI, Pi CLI/runtime expectations.
- Branch/PR workflow.
- Coding style and architecture principles.
- Test/build/manual verification expectations.
- Documentation update policy.
- How to file useful issues.

### `docs/index.md` / `docs/README.md`

Audience: all docs readers.

Outline:
- Choose your path:
  - New user
  - Power user configuring resources
  - Contributor
  - LLM contributor
  - Debugging reference
- Current docs source of truth and archive warning.
- Link table for every major feature.

### `docs/getting-started/installation.md`

Audience: end users.

Outline:
- Supported platform.
- Install options: release download if available; build from source if not.
- Required/optional dependencies: Pi CLI, Xcode for source build, GitHub CLI/auth if relevant, package/extensions if needed.
- macOS permissions/codesigning caveats.
- Verify app launches.

### `docs/getting-started/build-from-source.md`

Audience: contributors and advanced users.

Outline:
- Clone repo.
- Select Xcode.
- Build command matching CI.
- Open Xcode project.
- Common build failures.
- Where app artifacts/logs are.

### `docs/user-guide/overview.md`

Audience: end users.

Outline:
- What the app scans and why.
- Sidebar map matching current app sections.
- Resource counts/warnings.
- Safe editing model.

### `docs/user-guide/agents.md`

Audience: users managing agents.

Outline:
- Builtin/global/project/library agents.
- Replacement vs override.
- Effective resolved view.
- Supported frontmatter summary with link to reference.
- Creating/duplicating/importing agents.
- Common warnings: duplicate names, malformed frontmatter, missing tools/extensions/skills.

### `docs/user-guide/chains.md`

Audience: users authoring chains.

Outline:
- App-managed chain locations.
- Chain step mental model.
- Native graph execution.
- Legacy `.agents/*.chain.md` warning/gap.

### `docs/user-guide/skills.md`

Audience: users assigning skills.

Outline:
- Active vs library skills.
- Global vs project skills.
- Agent `skills:` references do not bundle skill files.
- Directory-based skill activation.
- Discovery edge cases, with link to reference.

### `docs/user-guide/prompts-and-commands.md`

Audience: users managing prompt templates.

Outline:
- Difference between built-in commands, extension commands, prompt templates, skill invocations.
- Prompt locations.
- Prompt frontmatter and arguments.
- Why skills stay in Skills rather than duplicated in Prompts.

### `docs/user-guide/native-subagents.md`

Audience: users running app-managed subagents.

Outline:
- Native subagents replace app-managed package `/run` flows.
- Bundled agents: scout/planner/worker/reviewer.
- Manual run sheet.
- Expected outcomes and safety.
- Read-first files.
- Supervisor requests.
- Worktrees and artifacts.

### `docs/concepts/resource-scopes.md`

Audience: users and contributors.

Outline:
- Builtin, Global, Project, Legacy Project, Override, Package, Library.
- Active vs library resources.
- Visibility and symlink model.

### `docs/concepts/resource-resolution.md`

Audience: users and contributors.

Outline:
- Agent precedence.
- Builtin overrides.
- Custom replacements.
- Skills and prompt collision rules.
- Diagnostics/warnings.

### `docs/concepts/pi-runtime-vs-pi-manager.md`

Audience: advanced users/contributors.

Outline:
- Pi core discovery vs Pi Manager app model.
- Package `pi-subagents` historical behavior vs native app-managed behavior.
- What the app scans but does not execute.
- What native subagents own.

### `docs/reference/file-locations.md`

Audience: power users/contributors/LLM agents.

Outline:
- Exact paths from `PiScanner.swift` and resource-management docs.
- Global/project/library agents, chains, skills, prompts.
- Settings, env, MCP, extensions.
- Package and legacy paths.
- Mark which paths are Pi runtime-discovered vs Pi Manager-managed.

### `docs/reference/agent-frontmatter.md`

Audience: agent authors and LLM contributors.

Outline:
- Required fields: `name`, `description`.
- Supported native fields from `AgentConfig`.
- Compatibility fields and unknown-field preservation.
- Safe examples for report-only, worker, reviewer.
- `contact_supervisor` guidance.

### `docs/reference/chain-format.md`

Audience: chain authors.

Outline:
- `.chain.md` frontmatter.
- Step headings.
- Per-step fields: output, reads, model, skills, progress.
- Native graph execution semantics.

### `docs/reference/skill-discovery.md`

Audience: power users/debuggers.

Outline:
- Promote/refactor existing `pi-documentation/pi-skills-discovery.md`.
- Include root `.md` vs `SKILL.md` rules by location.
- Package/settings/CLI discovery.
- Collision behavior.

### `docs/reference/native-subagent-api.md`

Audience: contributors and advanced users.

Outline:
- Parent bridge tools: `managed_subagent`, `managed_chain`, `managed_parallel`, `list_supervisor_requests`, `answer_supervisor_request`.
- Child bridge: `contact_supervisor` request kinds.
- Run records/artifacts/transcripts.
- Expected outcome validation.

### `docs/contributors/architecture.md`

Audience: contributors and LLM agents.

Outline:
- App architecture diagram.
- `AppViewModel`, scanner/snapshot, persistence, runner services, native subagent services, views.
- Data flow: scan -> snapshot -> UI -> edit/persist/run.
- Safety gates.

### `docs/contributors/source-map.md`

Audience: LLM contributors and new maintainers.

Outline:
- Key files/directories:
  - `pi-manager/PiScanner.swift` resource discovery/resolution/warnings
  - `pi-manager/Models.swift` shared resource/session models
  - `pi-manager/*Persistence.swift` resource write behavior
  - `pi-manager/PiSubagentRunService.swift` native run execution
  - `pi-manager/PiNativeSubagentBridgeExtensions.swift` bridge extension schemas
  - `pi-manager/PiAgentRunnerService.swift`, `PiRPCClient.swift` parent sessions/RPC
  - `pi-manager/ContentView.swift`, feature views
  - `pi-manager/bundled-agents/*.md`
  - `.github/workflows/macos-build.yml`
- Where to update docs when source behavior changes.

### `docs/contributors/testing-and-verification.md`

Audience: contributors.

Outline:
- CI build command and Xcode requirement.
- Unit tests currently available.
- Manual verification checklist strategy; move stable portions from `manual-verification.md`.
- Smoke tests for RPC/bridge if still current.
- How to document unvalidated changes.

### `docs/contributors/llm-contributor-guide.md`

Audience: LLM agents.

Outline:
- Read-first policy.
- Avoid stale `plan.md`/`progress.md` assumptions.
- Report-only vs edit-file expectations.
- Validation and evidence standards.
- Common pitfalls: confusing package `pi-subagents` with native app-managed subagents; stale in-app docs; legacy `.agents` paths.

## Migration plan for existing docs

Suggested mapping:

| Current file | Proposed destination | Notes |
|---|---|---|
| `pi-manager-spec.md` | `docs/concepts/product-scope.md` or excerpts into `README.md` and `docs/user-guide/overview.md` | Keep full spec either archived or maintained as product reference. |
| `pi-documentation/pi-manager-resource-management.md` | `docs/concepts/library-vs-active-resources.md` + `docs/reference/file-locations.md` | This is one of the strongest existing docs; promote it. |
| `pi-documentation/native-subagents.md` | `docs/user-guide/native-subagents.md` + `docs/reference/native-subagent-api.md` | Split user guide from API/runtime details. |
| `pi-documentation/convert-pi-subagents-agents-to-native.md` | `docs/recipes/migrate-package-agent-to-native.md` | Keep as migration recipe. |
| `pi-documentation/pi-core-system-reference-and-subagents.md` | `docs/concepts/pi-runtime-vs-pi-manager.md` + `docs/reference/file-locations.md` | Remove machine-specific setup from official public docs or move to contributor notes. |
| `pi-documentation/pi-skills-discovery.md` | `docs/reference/skill-discovery.md` | Promote mostly as-is after public tone cleanup. |
| `pi-documentation/pi-commands-and-prompt-templates.md` | `docs/user-guide/prompts-and-commands.md` + `docs/reference/prompt-template-format.md` | Split mental model and format reference. |
| `manual-verification.md` | `docs/contributors/testing-and-verification.md` | Current file is session-specific; extract stable checks. |
| `PI_MANAGER_*_PLAN.md`, `plan.md`, `progress.md`, `research.md`, `subagent-research/*` | `docs/archive/` or leave outside official docs | Do not present as current user docs unless curated. |
| `pi-documentation/Deprecated-old-pi-subagents-and-intercom/*` | `docs/archive/old-package-subagents/` | Must be clearly labeled deprecated. |

## Gaps and open questions

1. **Repo identity and installation path**: Is this intended to ship with GitHub Releases, Homebrew, direct Xcode build, or all of the above? README/install docs need an official answer.
2. **License/code-of-conduct/security**: No root `LICENSE`, `CODE_OF_CONDUCT.md`, or `SECURITY.md` were observed in the repo listing. Open-source docs need these decisions.
3. **Public support matrix**: Need official minimum macOS, Xcode, and Pi CLI versions. CI currently selects Xcode 26.4+ in `.github/workflows/macos-build.yml`, but user-facing requirements should be confirmed.
4. **Official docs location**: Choose between `docs/` (standard GitHub convention) and existing `pi-documentation/official-documentation/`. Recommendation: use `docs/`, and optionally deprecate/redirect `pi-documentation/`.
5. **In-app docs source of truth**: Current `PiDocsScreen` is hardcoded Swift text, not rendered from Markdown. Decide whether in-app Docs should be generated from official Markdown or maintained manually with a sync checklist.
6. **Stale package-era references**: Some in-app docs and older markdown still describe `pi-subagents` package builtins/`/run`/intercom flows. Official docs must explicitly separate current native app-managed behavior from archived package behavior.
7. **GitHub integration docs**: Source has GitHub services/views, but existing markdown docs do not appear to cover setup, auth, or issue workflows.
8. **MCP docs**: Spec lists MCP as a top-level concern, and core reference mentions MCP paths, but current app sidebar has no separate MCP item. Decide whether MCP is part of Environment/Settings docs or deserves its own user-guide page.
9. **Screenshots/assets**: Public docs should include app screenshots, but none are currently organized under docs assets.
10. **Validation docs**: Existing manual checklist is detailed but session-specific. Need a stable contributor verification matrix plus optional release checklist.
11. **LLM contributor contract**: No root `AGENTS.md` exists. This is important because the project itself is agent-heavy and expects LLM contributors to avoid stale plans and unsafe writes.
12. **API/reference stability**: Before documenting bridge tools as public API, confirm whether names/signatures are considered stable.
13. **Roadmap/status policy**: Current root planning docs are numerous. Decide whether to maintain `ROADMAP.md`, GitHub issues/milestones, or both.

## Recommended immediate next step

Create a first official docs pass with only stable, high-value files:

```text
README.md
AGENTS.md
CONTRIBUTING.md
docs/index.md
docs/getting-started/build-from-source.md
docs/user-guide/overview.md
docs/user-guide/native-subagents.md
docs/concepts/library-vs-active-resources.md
docs/reference/file-locations.md
docs/reference/agent-frontmatter.md
docs/contributors/source-map.md
docs/contributors/testing-and-verification.md
```

Then migrate the remaining existing `pi-documentation/` files incrementally, marking deprecated package-era material as archive-only.
