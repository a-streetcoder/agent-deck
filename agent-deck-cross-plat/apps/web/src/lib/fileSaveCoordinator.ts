/**
 * Debounced file autosave coordinator (Slice L4b) — ported from t3code's
 * framework-agnostic `fileSaveCoordinator.ts` (MIT), re-expressed in plain TS
 * (no Effect / no AtomCommandResult): the caller's `persist` resolves to a plain
 * boolean (`true` = the write landed, `false` = it failed or hit an on-disk
 * conflict, so the buffer stays pending).
 *
 * Behaviour it guarantees:
 *   - DEBOUNCE: `change()` coalesces bursts of keystrokes into one write
 *     `debounceMs` after the LAST keystroke (only the latest contents persist).
 *   - IN-FLIGHT GUARD: only one `persist` runs at a time; an edit made DURING a
 *     write reschedules a follow-up write so the newest contents are never lost.
 *   - REVISION TRACKING: `onPendingChange(false)` (and `onConfirmed`) fire only
 *     when the persisted revision is still the latest — a stale write never
 *     clears the pending flag for a buffer that changed since.
 *   - FLUSH ON DISPOSE: `dispose()` (tab close / file switch / unmount) cancels
 *     the timer and flushes any pending contents immediately, so a debounce
 *     that had not yet elapsed still reaches disk.
 */
export interface FileSaveCoordinatorOptions {
  readonly debounceMs: number;
  /** Persist the latest contents; resolves true on success, false on failure. */
  readonly persist: (contents: string) => Promise<boolean>;
  /** Pending edits exist (true) / everything is saved (false). */
  readonly onPendingChange: (pending: boolean) => void;
  /** A write of exactly these contents landed on disk. */
  readonly onConfirmed: (contents: string) => void;
}

export class FileSaveCoordinator {
  private timer: ReturnType<typeof setTimeout> | null = null;
  private latestContents = "";
  private latestRevision = 0;
  private lastChangeAt = 0;
  private saving = false;
  private disposed = false;

  constructor(private readonly options: FileSaveCoordinatorOptions) {}

  change(contents: string): void {
    this.latestContents = contents;
    this.latestRevision += 1;
    this.lastChangeAt = Date.now();
    this.options.onPendingChange(true);
    this.schedule(this.options.debounceMs);
  }

  dispose(): void {
    this.disposed = true;
    this.clearTimer();
    if (this.latestRevision > 0) void this.persistLatest();
  }

  /**
   * Drop any pending edit WITHOUT persisting it (Slice L4b conflict reload) —
   * the losing buffer is discarded in favour of the reloaded on-disk content.
   * A write already in flight cannot be recalled, but no queued/debounced write
   * survives. Clears the pending flag.
   */
  cancel(): void {
    this.clearTimer();
    this.latestRevision = 0;
    this.latestContents = "";
    this.options.onPendingChange(false);
  }

  private schedule(delay: number): void {
    this.clearTimer();
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.persistLatest();
    }, delay);
  }

  private clearTimer(): void {
    if (this.timer === null) return;
    clearTimeout(this.timer);
    this.timer = null;
  }

  private async persistLatest(): Promise<void> {
    if (this.saving || this.latestRevision === 0) return;

    this.saving = true;
    const contents = this.latestContents;
    const revision = this.latestRevision;
    const succeeded = await this.options.persist(contents);
    if (succeeded) {
      this.options.onConfirmed(contents);
    }

    this.saving = false;
    if (revision === this.latestRevision) {
      if (succeeded) this.options.onPendingChange(false);
      return;
    }

    // A newer edit arrived while this write was in flight — reschedule so the
    // latest contents also get persisted (debounced from that last keystroke).
    const remainingDebounce = Math.max(
      0,
      this.options.debounceMs - (Date.now() - this.lastChangeAt),
    );
    if (this.disposed) {
      void this.persistLatest();
    } else {
      this.schedule(remainingDebounce);
    }
  }
}
