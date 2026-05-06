#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 ITEM RESULT EVIDENCE NOTES..." >&2
  exit 64
fi

item="$1"
result="$2"
evidence="$3"
shift 3
notes="$*"

printf '| %s | %s | %s | %s |\n' "$item" "$result" "$evidence" "$notes" >> validation-results.md
