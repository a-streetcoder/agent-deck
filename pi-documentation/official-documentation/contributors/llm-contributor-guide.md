# LLM Contributor Guide

This repository is likely to be modified by coding agents. Follow these rules to avoid stale or unsafe changes.

## Read first

Before editing, inspect the actual source files that own the behavior. Do not rely only on old `plan.md`, `progress.md`, or exploratory docs.

Common task reads:

- scanner/resource behavior: `pi-manager/PiScanner.swift`, `pi-manager/Models.swift`
- native subagents: `pi-manager/PiSubagentRunService.swift`, `pi-manager/PiNativeSubagentBridgeExtensions.swift`, `pi-manager/bundled-agents/*.md`
- Pi Agent RPC: `pi-manager/PiRPCClient.swift`, `pi-manager/PiAgentRunnerService.swift`
- persistence: `pi-manager/*Persistence.swift`
- UI changes: relevant SwiftUI view plus `AppViewModel.swift`

## Preserve product invariants

- Do not edit read-only builtin files directly.
- Do not make report-only native subagents write project files.
- Do not hide write targets.
- Do not confuse old package-managed `pi-subagents` flows with current app-managed native subagents.
- Do not assume a library resource is active until linked globally or into a project.
- Do not inject stale file contents into long-lived system prompts.

## Evidence standard

When documenting or reviewing behavior, cite source files or current official docs. If behavior is uncertain, mark it as a gap instead of inventing it.

## Validation

Run a focused build/test when possible. If you cannot run validation, say so in the final summary and describe the exact command a maintainer should run.

## Documentation changes

For public docs, write stable behavior, not temporary implementation plans. Deprecated package-era behavior belongs in archive material and must be labeled historical.
