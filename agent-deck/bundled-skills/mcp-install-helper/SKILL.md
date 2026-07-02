---
name: mcp-install-helper
description: Use when helping users install, import, repair, or verify MCP server configurations in Agent Deck.
---

# MCP Install Helper

Use this skill when the user wants to add, import, fix, or test an MCP server for Agent Deck.

## Agent Deck MCP model

Agent Deck reads MCP servers from these files, lowest-to-highest precedence:

1. `~/.config/mcp/mcp.json`
2. `~/.pi/agent/mcp.json` — the app-owned writable file
3. `<project>/.mcp.json`
4. `<project>/.pi/mcp.json`

The MCP view writes only to `~/.pi/agent/mcp.json`. Project files can override servers with the same name. Parent Pi sessions receive MCP access through the single `mcp` proxy tool when MCP is enabled in Runtime → MCP and the server is assigned/advertised for that project.

Supported server config shape:

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "package-name"],
      "env": { "KEY": "VALUE" }
    }
  }
}
```

or remote HTTP:

```json
{
  "mcpServers": {
    "server-name": {
      "url": "https://example.com/mcp",
      "headers": { "API_KEY": "VALUE" },
      "transport": "http"
    }
  }
}
```

Agent Deck also imports common pasted formats:

- full JSON with `mcpServers`
- bare server map like `{ "context7": { ... } }`
- single server object like `{ "command": "npx", "args": [...] }` when the UI can ask for a name
- simple `claude mcp add ...` / `codex mcp add ...` commands

## Workflow

1. Ask for the MCP server docs URL, install snippet, or server name if it is not already provided.
2. Prefer official docs. Fetch/read the docs when a URL is available.
3. Identify whether the server supports:
   - remote HTTP/SSE endpoint
   - local stdio command
   - required API keys, tokens, headers, or environment variables
   - optional scopes/features the user requested
4. Choose the simplest working Agent Deck setup:
   - Prefer remote HTTP when the docs provide a stable URL and headers; it avoids local package/runtime issues.
   - Use local stdio when remote is unavailable, OAuth is unsupported in Agent Deck for that server, or the server must access local files/commands.
5. Ask only for missing required decisions or secrets. If a secret is optional, say so and provide a placeholder unless the user wants to add it now.
6. Give the user one copy/paste import block for Agent Deck’s MCP import/edit UI, or write `~/.pi/agent/mcp.json` directly if the user asks/approves and the session has file-write tools.
7. Explain any required follow-up: enable MCP in Runtime → MCP, assign the server to the relevant project/agent if needed, refresh/restart the session, then test with the `mcp` proxy.

## Direct editing from chat

If the user asks you to install it for them from chat, you may edit `~/.pi/agent/mcp.json` directly when write tools are available.

Rules for direct edits:

- Write only to `~/.pi/agent/mcp.json` unless the user explicitly asks for a project-local MCP config.
- Preserve existing `settings`, unknown top-level keys, and unrelated servers.
- Upsert only the named server entry.
- Do not overwrite a same-named server without warning if it comes from a higher-precedence project file.
- Do not store secrets unless the user explicitly provides them for this purpose. Prefer placeholders like `YOUR_API_KEY` or env references like `$MY_SERVER_API_KEY` when appropriate.
- After writing, tell the user the exact file path and server name.

A safe shell/Python upsert pattern:

```sh
python3 - <<'PY'
import json, os
path = os.path.expanduser('~/.pi/agent/mcp.json')
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        root = json.load(f)
except Exception:
    root = {}
root.setdefault('mcpServers', {})['SERVER_NAME'] = SERVER_CONFIG
with open(path, 'w') as f:
    json.dump(root, f, indent=2)
    f.write('\n')
PY
```

Replace `SERVER_NAME` with a JSON string and `SERVER_CONFIG` with a Python dict mirroring the MCP JSON.

## Field mapping cheatsheet

For local stdio:

- UI Command field: executable only, e.g. `npx`, `uvx`, `docker`, `node`, `python`
- UI Arguments field: one argument per line, e.g. `-y` then `@vendor/server`
- UI Environment field: `KEY=VALUE` one per line
- JSON: `command`, `args`, optional `env`, optional `cwd`, optional `transport: "stdio"`

For remote HTTP:

- UI URL: the MCP endpoint
- Headers/environment equivalent: required headers such as `Authorization` or `CONTEXT7_API_KEY`
- JSON: `url`, optional `headers`, optional `transport: "http"`

Do not put a whole shell command in the Command field. For example, use `command: "npx"` and args `["-y", "@upstash/context7-mcp"]`, not `command: "npx -y @upstash/context7-mcp"`.

## Validation checklist

Before finalizing, verify:

- The server name is stable, lowercase/kebab-case when possible.
- Local configs have `command` as one executable and `args` as an array.
- Remote configs have `url` and any required headers.
- Required secrets are present, intentionally omitted as placeholders, or referenced through env vars.
- The config is valid JSON if giving an import block.
- The user knows whether they still need to assign the server or enable MCP globally.

## Example: Context7

Remote HTTP:

```json
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "YOUR_API_KEY"
      },
      "transport": "http"
    }
  }
}
```

Local stdio:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp", "--api-key", "YOUR_API_KEY"]
    }
  }
}
```
