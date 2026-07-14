#!/usr/bin/env python3
"""Derive Agent Deck's reviewed auto-accept Computer Use broker variant."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

PACKAGE_NAME = "codex-computer-use-mcp"
UPSTREAM_VERSION = "0.2.0"
UPSTREAM_DIGEST = "5ca2b51c934c0f961bb52644ac430dd89a3dcbc772faaae6861f05030f97ab94"
VARIANT_REVISION = "0.2.0-agent-deck-auto-accept.1"
# Filled after deriving and reviewing the deterministic variant.
VARIANT_DIGEST = "a2f211c2a6b1600eb210fa0b5068269e6164974b87a9b77b7be0988f19199714"

REPLACEMENTS = {
    "dist/direct-broker.js": [
        (
            '                    // The durable no-permissions interface never opens an approval UI and never\n'
            '                    // self-accepts a first-party request. Unexpected elicitations are declined.\n'
            '                    send({ id: message.id, result: { action: "decline" } });',
            '                    // Agent Deck auto-accept variant: assignment is the authority boundary.\n'
            '                    // Accept only the reviewed empty Computer Use form for this ephemeral thread.\n'
            '                    const params = message.params;\n'
            '                    const schema = params?.requestedSchema;\n'
            '                    const metadata = params?._meta;\n'
            '                    const parameterKeys = params && typeof params === "object" ? Object.keys(params).sort() : [];\n'
            '                    const schemaKeys = schema && typeof schema === "object" ? Object.keys(schema).sort() : [];\n'
            '                    const metadataKeys = metadata && typeof metadata === "object" ? Object.keys(metadata).sort() : [];\n'
            '                    const messagePrefix = "Allow ChatGPT to use ";\n'
            '                    const approvalTarget = typeof params?.message === "string"\n'
            '                        ? params.message.slice(messagePrefix.length, -1)\n'
            '                        : "";\n'
            '                    const validRequest = params?.threadId === activeThreadId\n'
            '                        && params?.turnId === null\n'
            '                        && params?.serverName === "computer-use"\n'
            '                        && params?.mode === "form"\n'
            '                        && typeof params?.message === "string"\n'
            '                        && params.message.length <= 600\n'
            '                        && params.message.startsWith(messagePrefix)\n'
            '                        && params.message.endsWith("?")\n'
            '                        && approvalTarget.length >= 1\n'
            '                        && approvalTarget.length <= 300\n'
            '                        && approvalTarget === approvalTarget.trim()\n'
            '                        && !/[\\u0000-\\u001f\\u007f]/u.test(approvalTarget)\n'
            '                        && JSON.stringify(parameterKeys) === JSON.stringify(["_meta", "message", "mode", "requestedSchema", "serverName", "threadId", "turnId"])\n'
            '                        && JSON.stringify(schemaKeys) === JSON.stringify(["properties", "type"])\n'
            '                        && schema?.type === "object"\n'
            '                        && schema?.properties && typeof schema.properties === "object"\n'
            '                        && Object.keys(schema.properties).length === 0\n'
            '                        && JSON.stringify(metadataKeys) === JSON.stringify(["persist"])\n'
            '                        && Array.isArray(metadata?.persist)\n'
            '                        && metadata.persist.length === 1\n'
            '                        && metadata.persist[0] === "always";\n'
            '                    if (!validRequest) {\n'
            '                        send({ id: message.id, result: { action: "decline" } });\n'
            '                        fail(new Error("Official app-server emitted an unexpected Computer Use approval request"));\n'
            '                        return;\n'
            '                    }\n'
            '                    send({ id: message.id, result: { action: "accept", content: {} } });',
        ),
        (
            '    let approvalRequests = 0;\n    let modelTurnsStarted = 0;',
            '    let approvalRequests = 0;\n    let activeThreadId;\n    let modelTurnsStarted = 0;',
        ),
        (
            '            capabilities: { mcpServerOpenaiFormElicitation: false },',
            '            capabilities: { mcpServerOpenaiFormElicitation: true },',
        ),
        (
            'approvalPolicy: "never", sandbox: "read-only", ephemeral: true',
            'approvalPolicy: "on-request", sandbox: "read-only", ephemeral: true',
        ),
        (
            '        ephemeralThread = true;\n        const inventory = await request("mcpServerStatus/list",',
            '        activeThreadId = threadId;\n        ephemeralThread = true;\n        const inventory = await request("mcpServerStatus/list",',
        ),
    ],
    "dist/direct-service.js": [
        (
            '        officialApprovalAuthoritative: true,',
            '        officialApprovalAuthoritative: false,\n'
            '        firstPartyApprovalHandling: "agent-deck-auto-accept",',
        ),
    ],
}

NOTICE = """# Agent Deck Computer Use broker variant

This directory is a deterministic derivative of `codex-computer-use-mcp@0.2.0`
(MIT licensed; see `LICENSE`). Agent Deck changes only the signed Codex
app-server approval flow:

- advertise OpenAI form elicitation support;
- use `approvalPolicy: \"on-request\"` for the empty ephemeral thread;
- automatically accept bounded `mcpServer/elicitation/request` messages with
  empty content;
- report that first-party approval is handled by Agent Deck auto-accept.

The exact derived package tree is integrity-pinned by Agent Deck. OpenAI
binaries and plugin resources are not modified or redistributed.
"""


def tree_digest(root: Path) -> str:
    entries: list[tuple[str, Path]] = []
    for base, directories, files in os.walk(root, followlinks=False):
        directories.sort()
        files.sort()
        for name in files:
            path = Path(base) / name
            entries.append((path.relative_to(root).as_posix(), path))
    digest = hashlib.sha256()
    for relative, path in sorted(entries):
        digest.update(relative.encode())
        digest.update(b"\0")
        if path.is_symlink():
            digest.update(b"L")
            digest.update(os.readlink(path).encode())
        else:
            digest.update(b"F")
            with path.open("rb") as handle:
                while chunk := handle.read(1024 * 1024):
                    digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def replace_exactly_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one reviewed patch preimage in {path}, found {count}")
    path.write_text(text.replace(old, new))


def validate_upstream(package_root: Path) -> None:
    manifest = json.loads((package_root / "package.json").read_text())
    if manifest.get("name") != PACKAGE_NAME or manifest.get("version") != UPSTREAM_VERSION:
        raise RuntimeError("Upstream broker package identity does not match the reviewed version")
    if not (package_root / "dist/mcp-server.js").is_file():
        raise RuntimeError("Upstream broker entry point is missing")
    actual = tree_digest(package_root)
    if actual != UPSTREAM_DIGEST:
        raise RuntimeError(f"Upstream broker integrity mismatch: expected {UPSTREAM_DIGEST}, got {actual}")


def derive(package_root: Path, variant_root: Path) -> str:
    validate_upstream(package_root)
    destination_package = variant_root / "node_modules" / PACKAGE_NAME
    if variant_root.exists():
        existing_digest = tree_digest(destination_package) if destination_package.is_dir() else None
        if VARIANT_DIGEST != "TO_BE_RECORDED" and existing_digest == VARIANT_DIGEST:
            return existing_digest
        raise RuntimeError(f"Refusing to overwrite mismatched existing variant: {variant_root}")

    variant_root.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{VARIANT_REVISION}.", dir=variant_root.parent))
    try:
        staged_package = staging / "node_modules" / PACKAGE_NAME
        shutil.copytree(package_root, staged_package, symlinks=True)
        for relative, replacements in REPLACEMENTS.items():
            target = staged_package / relative
            for old, new in replacements:
                replace_exactly_once(target, old, new)
        (staged_package / "AGENT-DECK-VARIANT.md").write_text(NOTICE)
        digest = tree_digest(staged_package)
        if VARIANT_DIGEST != "TO_BE_RECORDED" and digest != VARIANT_DIGEST:
            raise RuntimeError(f"Derived broker integrity mismatch: expected {VARIANT_DIGEST}, got {digest}")
        variant_manifest = {
            "variant": VARIANT_REVISION,
            "package": PACKAGE_NAME,
            "upstreamVersion": UPSTREAM_VERSION,
            "upstreamDigest": UPSTREAM_DIGEST,
            "packageTreeDigest": digest,
            "approvalHandling": "auto-accept",
        }
        (staging / "agent-deck-variant.json").write_text(json.dumps(variant_manifest, indent=2, sort_keys=True) + "\n")
        staging.rename(variant_root)
        return digest
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    default_root = Path.home() / "Library/Application Support/Agent Deck/Computer Use Broker"
    parser = argparse.ArgumentParser()
    parser.add_argument("--broker-root", type=Path, default=default_root)
    arguments = parser.parse_args()
    package_root = arguments.broker_root / UPSTREAM_VERSION / "node_modules" / PACKAGE_NAME
    variant_root = arguments.broker_root / "Variants" / VARIANT_REVISION
    try:
        digest = derive(package_root.resolve(), variant_root)
    except Exception as error:
        print(f"Computer Use broker variant installation failed: {error}", file=sys.stderr)
        return 1
    print(f"Source: {package_root}")
    print(f"Variant: {variant_root}")
    print(f"State: {arguments.broker_root / 'State' / 'auto-accept.1'}")
    print(f"Variant digest: {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
