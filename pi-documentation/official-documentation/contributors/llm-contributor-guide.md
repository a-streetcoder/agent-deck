# LLM Contributor Guide

This repository is likely to be modified by coding agents. Follow these rules to avoid stale or unsafe changes.

## Read first

Before editing, inspect the actual source files that own the behavior. Do not rely only on old `plan.md`, `progress.md`, or exploratory docs.

Common task reads:

- scanner/resource behavior: `agent-deck/PiScanner.swift`, `agent-deck/Models.swift`
- native subagents: `agent-deck/PiSubagentRunService.swift`, `agent-deck/PiNativeSubagentBridgeExtensions.swift`, `agent-deck/bundled-agents/*.md`
- Pi Agent RPC: `agent-deck/PiRPCClient.swift`, `agent-deck/PiAgentRunnerService.swift`
- persistence: `agent-deck/*Persistence.swift`
- UI changes: relevant SwiftUI view plus `AppViewModel.swift`

## Preserve product invariants

- Do not edit read-only builtin files directly.
- Do not make report-only native subagents write project files.
- Do not hide write targets.
- Describe current app-managed native subagents directly.
- Do not assume a library resource is active until linked globally or into a project.
- Do not inject stale file contents into long-lived system prompts.

## Evidence standard

When documenting or reviewing behavior, cite source files or current official docs. If behavior is uncertain, mark it as a gap instead of inventing it.

## Validation

Run a focused build/test when possible. If you cannot run validation, say so in the final summary and describe the exact command a maintainer should run.

## Documentation changes

For public docs, write stable behavior, not temporary implementation plans. Deprecated package-era behavior belongs in archive material and must be labeled historical.
