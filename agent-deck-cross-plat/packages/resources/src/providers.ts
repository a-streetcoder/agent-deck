import path from "node:path";
import { AuthStorage } from "@earendil-works/pi-coding-agent";
import { piAgentHome, type ResourceRoots } from "./paths.ts";

/**
 * Provider auth (native provider-login surface). auth.json is a global resource
 * (~/.pi/agent/auth.json), so it lives here alongside the other catalog access.
 * pi's AuthStorage owns the file format + locking; we read status and remove a
 * stored credential. Interactive OAuth sign-in is a follow-up milestone.
 */

export interface ProviderAuthInfo {
  id: string;
  name: string;
  /** Any auth configured (stored credential OR an environment variable). */
  configured: boolean;
  /** Where the configured auth came from (stored / environment / …). */
  source?: string;
  label?: string;
  /** A credential stored in auth.json — the only state logout can act on. */
  signedIn: boolean;
}

function authStorage(roots: ResourceRoots): AuthStorage {
  return AuthStorage.create(path.join(piAgentHome(roots), "auth.json"));
}

/** The OAuth-capable providers pi knows about, with each one's sign-in status. */
export function listProviders(roots: ResourceRoots): ProviderAuthInfo[] {
  const auth = authStorage(roots);
  return auth.getOAuthProviders().map((provider) => {
    const status = auth.getAuthStatus(provider.id);
    return {
      id: provider.id,
      name: provider.name,
      configured: status.configured,
      source: status.source,
      label: status.label,
      signedIn: auth.has(provider.id),
    };
  });
}

/** True if `id` is a provider pi registers (so we never poke arbitrary keys). */
export function isKnownProvider(roots: ResourceRoots, id: string): boolean {
  return authStorage(roots)
    .getOAuthProviders()
    .some((provider) => provider.id === id);
}

/** Remove a provider's stored credential (native logout). */
export function logoutProvider(roots: ResourceRoots, id: string): void {
  authStorage(roots).logout(id);
}
