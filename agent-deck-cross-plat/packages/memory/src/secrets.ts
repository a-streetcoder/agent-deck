/**
 * Pre-write secret scanning (memory.md §Secret Scanning): a memory's title,
 * summary, or body must never persist credentials. Matches are conservative —
 * recognizable key/token shapes and explicit secret assignments — so a normal
 * fact about, say, "the API key rotation runbook" is not blocked while an
 * actual `api_key = sk-...` is.
 */

interface SecretPattern {
  name: string;
  regex: RegExp;
}

const PATTERNS: SecretPattern[] = [
  { name: "private key", regex: /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/ },
  {
    name: "GitHub token",
    regex: /\b(?:gh[posru]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/,
  },
  { name: "OpenAI API key", regex: /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/ },
  { name: "AWS access key", regex: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { name: "Slack token", regex: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ },
  {
    name: "secret assignment",
    // An identifier key ending in a credential word (password / token / secret /
    // api_key / access_key — including prefixed forms like AUTH_TOKEN,
    // SESSION_SECRET, DB_PASSWORD) assigned a 8+ non-space value.
    regex:
      /(?:^|[^a-z0-9])(?:[a-z0-9]+[_-])?(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)\s*[:=]\s*["']?[^\s"']{8,}/i,
  },
];

export interface SecretScanResult {
  hasSecret: boolean;
  /** Names of the patterns that matched (no captured values — never surfaced). */
  matched: string[];
}

/** Scan text for credential shapes. Values are never returned, only pattern names. */
export function scanForSecrets(...texts: Array<string | undefined>): SecretScanResult {
  const joined = texts.filter(Boolean).join("\n");
  const matched: string[] = [];
  for (const pattern of PATTERNS) {
    if (pattern.regex.test(joined)) matched.push(pattern.name);
  }
  return { hasSecret: matched.length > 0, matched };
}
