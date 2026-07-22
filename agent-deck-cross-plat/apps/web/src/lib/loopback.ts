/**
 * Loopback-URL validation shared by the preview surfaces. A dev-server URL is
 * only ever embedded (iframe src) or attached to a pi prompt (element context)
 * if it resolves to a loopback origin — localhost, the 127.0.0.0/8 block, or
 * IPv6 ::1. Discovered-server URLs come from parsing an untrusted repo's dev
 * script stdout, so this guard is the trust boundary for anything that origin
 * touches, not a cosmetic check.
 */

/** True iff `hostname` is a loopback host (localhost / 127.0.0.0/8 / ::1). */
export function isLoopbackHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  return h === "localhost" || h === "::1" || /^127(?:\.\d{1,3}){3}$/.test(h);
}

/**
 * Validate a raw string as a loopback http(s) URL, returning the parsed `URL`
 * (host/protocol confirmed) or null. A bare host (`localhost:3000`) gets an
 * `http://` scheme first.
 */
export function parseLoopbackHttpUrl(raw: string): URL | null {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  const candidate = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  try {
    const url = new URL(candidate);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (!isLoopbackHost(url.hostname)) return null;
    return url;
  } catch {
    return null;
  }
}

/**
 * A loopback http(s) URL in NORMALIZED form (`URL.toString()` — control-char
 * and newline free), or "" when the input is not a loopback URL. Use this
 * wherever a URL is serialized into text (a prompt block) rather than used as
 * an iframe src, so a hostile stdout-derived URL can neither smuggle a
 * non-loopback origin nor break the surrounding structure.
 */
export function sanitizeLoopbackUrl(raw: string): string {
  return parseLoopbackHttpUrl(raw)?.toString() ?? "";
}
