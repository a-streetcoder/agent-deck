#!/bin/bash
set -euo pipefail

BROKER_ROOT="${AGENT_DECK_COMPUTER_USE_BROKER_ROOT:-$HOME/Library/Application Support/Agent Deck/Computer Use Broker}"
UPSTREAM_ROOT="$BROKER_ROOT/0.2.0"
PACKAGE_ROOT="$UPSTREAM_ROOT/node_modules/codex-computer-use-mcp"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

printf 'Computer Use broker source: %s\n' "$PACKAGE_ROOT"
printf 'Computer Use broker variant: %s\n' "$BROKER_ROOT/Variants/0.2.0-agent-deck-auto-accept.1"
printf 'Computer Use broker state: %s\n' "$BROKER_ROOT/State/auto-accept.1"

if [[ ! -f "$PACKAGE_ROOT/package.json" ]]; then
  PI_PATH="$(command -v pi || true)"
  if [[ -z "$PI_PATH" ]]; then
    echo "Pi must be installed before the Computer Use broker." >&2
    exit 1
  fi
  NPM="$(dirname "$PI_PATH")/npm"
  if [[ ! -x "$NPM" ]]; then
    echo "Could not find npm alongside Pi at $NPM" >&2
    exit 1
  fi
  mkdir -p "$BROKER_ROOT"
  STAGING="$(mktemp -d "$BROKER_ROOT/.0.2.0.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  "$NPM" install \
    --prefix "$STAGING" \
    --omit=dev --ignore-scripts --legacy-peer-deps --no-audit --no-fund \
    codex-computer-use-mcp@0.2.0
  if [[ -e "$UPSTREAM_ROOT" ]]; then
    echo "Refusing to overwrite existing upstream broker directory: $UPSTREAM_ROOT" >&2
    exit 1
  fi
  mv "$STAGING" "$UPSTREAM_ROOT"
  trap - EXIT
fi

python3 "$SCRIPT_DIR/derive-computer-use-broker.py" --broker-root "$BROKER_ROOT"
