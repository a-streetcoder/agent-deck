# Pi Manager Session Relay

The native app concept is **Session Relay**: app-managed coordination between Pi sessions.

## Goal

Provide native Pi Manager coordination with app-native naming and UX.

## Scope

### Phase 1: Pi Manager-owned sessions

- List Pi Agent sessions known to Pi Manager.
- Show status, project, cwd/worktree, model, and last activity.
- Send a one-way relay note to another app-managed session.
- Ask a question and track the pending reply as a native card.
- Reply from the target session UI.

### Phase 2: external Pi sessions

- Add a small local Session Relay bus for external Pi processes that opt in.
- Support list/send/ask/reply/pending across opted-in sessions.
- Keep the protocol separate from external coordination naming and UI.

## Current native coverage

Pi Manager already has the most important subagent-specific part: app-managed parent/child supervisor relay for `contact_supervisor` requests. General arbitrary session messaging remains future work.

## Non-goals

- Do not copy external coordination naming or terminal UX.
- Do not require native subagent execution to depend on Session Relay.
- Do not make external sessions visible unless they explicitly opt in.
