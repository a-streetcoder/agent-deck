---
name: fixture-user-old
description: legacy global agent
tools: read, mcp:astro
model: openai/gpt-4.1
fallbackModels: openai/gpt-4o-mini
thinking: low
systemPromptMode: replace
inheritProjectContext: false
inheritSkills: false
skills: legacy-skill
extensions:
output: old.md
defaultReads: old.txt
defaultProgress: true
interactive: true
maxSubagentDepth: 2
customField: yes
---

# Legacy Global

Legacy global body.
