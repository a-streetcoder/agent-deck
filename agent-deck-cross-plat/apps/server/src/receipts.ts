/**
 * Test-only milestone bus (enabled by AGENT_DECK_TEST=1): deterministic e2e
 * tests await named milestones instead of polling the DOM or sleeping.
 */

export type ReceiptName =
  | "first_delta"
  | "assistant_final"
  | "idle"
  | "session_created"
  | "title"
  | "diff_refreshed";

interface Waiter {
  name: ReceiptName;
  sessionId: string;
  resolve: () => void;
}

export class ReceiptBus {
  private readonly seen = new Set<string>();
  private readonly waiters: Waiter[] = [];

  constructor(readonly enabled: boolean) {}

  emit(name: ReceiptName, sessionId: string): void {
    if (!this.enabled) return;
    this.seen.add(`${sessionId}:${name}`);
    for (let i = this.waiters.length - 1; i >= 0; i -= 1) {
      const waiter = this.waiters[i]!;
      if (waiter.name === name && waiter.sessionId === sessionId) {
        this.waiters.splice(i, 1);
        waiter.resolve();
      }
    }
  }

  async waitFor(name: ReceiptName, sessionId: string, timeoutMs = 30_000): Promise<void> {
    if (!this.enabled) throw new Error("ReceiptBus is disabled (set AGENT_DECK_TEST=1)");
    if (this.seen.has(`${sessionId}:${name}`)) return;
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`receipt ${name} for ${sessionId} not seen in ${timeoutMs}ms`)),
        timeoutMs,
      );
      timer.unref();
      this.waiters.push({
        name,
        sessionId,
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
      });
    });
  }
}
