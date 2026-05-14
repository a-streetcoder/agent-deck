# Onboarding Artwork Plan

TourKit works best with 16:10 artwork. Use 1600x1000 PNG images, dark-mode native macOS UI, and keep important detail above the lower third because the slide adds a dark gradient into the text panel.

Style direction: polished native macOS product screenshots/concept art for Agent Deck. Use SF Symbol-style icons, precise inspector/list/table UI, subtle scope/status colors, and real app surfaces. Avoid robot faces, chat bubbles, mascots, neon cyberpunk, playful AI imagery, and generic SaaS dashboards.

## Proposed Assets

1. `onboarding-command-pi`
   Prompt: A refined dark-mode macOS app window for Agent Deck, mission-control layout with sidebar, central Pi coding session overview, model selector, project context, repo activity, and compact status indicators. Native Apple UI, crisp typography, SF Symbol-style icons, teal/blue/amber status accents, no mascot, no chat bubbles, no neon.

2. `onboarding-coding-chat`
   Prompt: A focused Agent Deck coding chat workspace in dark-mode macOS style. Show a transcript with user request, assistant response, visible tool-call rows, file preview panel, attachments, and run controls. Emphasize implementation work and readable code/file context. Native split view, precise spacing, calm professional color, no marketing hero, no robot imagery.

3. `onboarding-subagents`
   Prompt: Agent Deck supervising multiple subagent runs in parallel. Show supervisor cards, child session lanes, worktree/status chips, decision request indicators, and progress states in a native macOS interface. The feeling is orchestration and control under load, not playful automation. Use SF Symbol-style icons and restrained teal/green/amber accents.

4. `onboarding-resources`
   Prompt: Agent Deck resource management screen showing agents, skills, and prompt templates across builtin, global, library, and project scopes. Use a dense native macOS table/list with scope chips, assignment controls, search/filter toolbar, and a right inspector with metadata. Precise, operational, dark mode, no generic web dashboard.

5. `onboarding-instructions`
   Prompt: Agent Deck project instructions manager. Show AGENTS.md, CLAUDE.md, system instructions, and project-scoped guidance in a native macOS editor/inspector layout with file path metadata, scope indicators, and assignment state. Calm dark UI, readable text blocks, subtle cyan/violet scope accents, no fantasy or mascot imagery.

6. `onboarding-workflow`
   Prompt: Agent Deck connected workflow setup screen. Show GitHub account status, project folder, model availability, environment keys, and setup checks in a native macOS checklist/inspector layout. Include repo/change indicators and issue workflow hints without making GitHub dominate the image. Polished dark mode, trustworthy utility feel.

## Wiring

After creating the images, add each as an `.imageset` in `agent-deck/Assets.xcassets`, then update `WelcomeTourContent.pages` in `agent-deck/OnboardingViews.swift` to use the asset names above.
