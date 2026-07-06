import { describe, expect, it } from "vitest";
import { scanForSecrets } from "../src/secrets.ts";

describe("secret scanning", () => {
  it("flags key/token shapes and secret assignments", () => {
    expect(scanForSecrets("api_key = sk-abcdefghijklmnop0123").hasSecret).toBe(true);
    expect(scanForSecrets("token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").hasSecret).toBe(true);
    expect(scanForSecrets("AKIAIOSFODNN7EXAMPLE").hasSecret).toBe(true);
    expect(scanForSecrets("-----BEGIN OPENSSH PRIVATE KEY-----").hasSecret).toBe(true);
    expect(scanForSecrets("password = hunter2hunter2").hasSecret).toBe(true);
    // Fine-grained GitHub PAT and identifier-prefixed keys.
    expect(scanForSecrets(`github_pat_${"A".repeat(24)}`).hasSecret).toBe(true);
    expect(scanForSecrets("AUTH_TOKEN=abcdef0123456789").hasSecret).toBe(true);
    expect(scanForSecrets("SESSION_SECRET: s3cr3tvalue99").hasSecret).toBe(true);
    expect(scanForSecrets("DB_PASSWORD=verySecretPw1").hasSecret).toBe(true);
  });

  it("does not flag ordinary prose that merely mentions secrets", () => {
    expect(scanForSecrets("The API key rotation runbook lives in ops/").hasSecret).toBe(false);
    expect(scanForSecrets("Store the token in the vault, never in memory").hasSecret).toBe(false);
    expect(scanForSecrets("").hasSecret).toBe(false);
  });

  it("reports matched pattern names but never the value", () => {
    const result = scanForSecrets("api_key = sk-abcdefghijklmnop0123");
    expect(result.matched.length).toBeGreaterThan(0);
    expect(JSON.stringify(result)).not.toContain("sk-abcdefghijklmnop0123");
  });
});
