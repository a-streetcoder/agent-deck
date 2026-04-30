---
name: github-issue
description: |
  Write well-structured GitHub issues from verbal ideas or rough notes.
  Use when the user asks to create, draft, or write a GitHub issue.
  Reads the repo code to anchor the issue in real files and architecture.
---

# GitHub Issue Writer

Write issues that an LLM (or human) can pick up and implement with minimal back-and-forth.

## Workflow

1. **Clarify** — Ask the user:
   - Which repo? (clone if needed)
   - Should you read the code first, or write from their notes only?
   - Any deadline, priority, or labels?
2. **Explore** (if code-reading is requested or implied):
   - Find files related to the feature/problem using `grep`, `rg`, `find`
   - Read the 3-5 most relevant files to understand current architecture
   - Identify touchpoints: what exists, what's missing, what breaks
3. **Draft** — Write the issue using the format below
4. **Confirm** — Show the draft to the user before creating

## Issue Format

Use this structure. Omit sections that aren't relevant rather than padding.

### Title

Concise, action-oriented. Prefer "[What] + [context/qualifier]".

- ✅ `Replace AI images with OG image hotlinking (with fallback)`
- ✅ `Add pull-to-refresh to story feed`
- ❌ `Images improvement`
- ❌ `Some bugs and things`

### Body

```markdown
## Context

1-3 sentences. Why does this matter now? What is the current state?
Not the problem itself — just the situation that makes this issue relevant.

## Problem

What's broken, missing, expensive, or wrong.
Be specific with evidence from the code.
Reference files inline: "Current image loading in `StoryCard.swift` uses..."

If the user provided legal, strategic, or product reasoning, include it here.
This is the "why".

## Key Files

Table of files the implementer should read first, with one-line roles.
Keep to 5-8 files max — this is the reading list, not the solution.

| File | Why it matters |
|------|---------------|
| `path/to/File.swift` | One-line summary of what the implementor needs to know |

## Constraints & Considerations

Bullet list of things to keep in mind:

- Technical constraints (API limits, platform specifics, performance)
- UX implications and edge cases
- Things that should NOT change (sacred contracts)
- Dependencies or blocking issues

## Open Questions

2-4 questions the implementer should answer before starting.
These guide investigation — they do NOT prescribe answers.

## Expected Outcome

1-2 sentences. What does "done" look like?
This is the acceptance criteria.
```

## Rules

1. **Never prescribe the implementation.** Link to files, describe the problem, state constraints. Let the implementer find the solution.
2. **Anchor everything in code.** Every claim should reference a file, function, or field name. No hand-waving.
3. **Separate "why" from "how".** The why goes in Context/Problem. The how is left for the implementer.
4. **Keep it scannable.** Someone should understand the issue in 30 seconds by reading only the title, Context, and Key Files.
5. **Open Questions are gold.** Good questions prevent bad implementations. Prefer "Does X already exist?" over "Add X."
6. **No boilerplate.** If a section adds nothing, omit it entirely.
7. **Use GitHub CLI.** Create issues with `gh issue create --repo <owner/repo>`. Always confirm with the user before creating.
