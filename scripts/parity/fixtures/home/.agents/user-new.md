---
name: fixture-user-new
description: modern global agent
tools: read, write, mcp:docs
model: openai/gpt-4.1
fallbackModels: openai/gpt-4o-mini, openai/gpt-4.1-mini
thinking: medium
skill: global-skill
extensions: swift, md
output: new.md
defaultReads: README.md, docs.md
defaultProgress: true
interactive: true
maxSubagentDepth: 3
customField: retained
---

# Modern Global

This body should round-trip.
