import { afterEach, describe, expect, it, vi } from "vitest";
import { FileSaveCoordinator } from "./fileSaveCoordinator.ts";

/**
 * Unit tests for the Slice-L4b debounced autosave coordinator (ported from
 * t3code's fileSaveCoordinator, plain-TS boolean-persist variant). Covers the
 * debounce (only the latest contents persist), the in-flight guard + reschedule
 * (an edit during a write is also saved), and the failure path (a failed write
 * leaves the buffer pending). Fake timers drive the debounce deterministically.
 */

function deferred() {
  let resolve!: (ok: boolean) => void;
  const promise = new Promise<boolean>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

describe("FileSaveCoordinator", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("debounces edits and persists only the latest contents", async () => {
    vi.useFakeTimers();
    const persist = vi.fn<(contents: string) => Promise<boolean>>().mockResolvedValue(true);
    const onPendingChange = vi.fn();
    const onConfirmed = vi.fn();
    const coordinator = new FileSaveCoordinator({
      debounceMs: 500,
      persist,
      onPendingChange,
      onConfirmed,
    });

    coordinator.change("first");
    await vi.advanceTimersByTimeAsync(300);
    coordinator.change("latest");
    await vi.advanceTimersByTimeAsync(499);
    expect(persist).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(persist).toHaveBeenCalledOnce();
    expect(persist).toHaveBeenCalledWith("latest");
    expect(onConfirmed).toHaveBeenCalledWith("latest");
    expect(onPendingChange.mock.calls).toEqual([[true], [true], [false]]);
  });

  it("keeps pending state until an edit made during a write is also saved", async () => {
    vi.useFakeTimers();
    const firstWrite = deferred();
    const persist = vi
      .fn<(contents: string) => Promise<boolean>>()
      .mockReturnValueOnce(firstWrite.promise)
      .mockResolvedValueOnce(true);
    const onPendingChange = vi.fn();
    const coordinator = new FileSaveCoordinator({
      debounceMs: 500,
      persist,
      onPendingChange,
      onConfirmed: vi.fn(),
    });

    coordinator.change("first");
    await vi.advanceTimersByTimeAsync(500);
    coordinator.change("latest");
    await vi.advanceTimersByTimeAsync(500);
    expect(persist).toHaveBeenCalledTimes(1);

    firstWrite.resolve(true);
    await vi.runAllTimersAsync();
    expect(persist).toHaveBeenCalledTimes(2);
    expect(persist).toHaveBeenLastCalledWith("latest");
    expect(onPendingChange.mock.calls.at(-1)).toEqual([false]);
  });

  it("leaves the file pending when the latest write fails (or conflicts)", async () => {
    vi.useFakeTimers();
    const onPendingChange = vi.fn();
    const coordinator = new FileSaveCoordinator({
      debounceMs: 500,
      persist: vi.fn<(contents: string) => Promise<boolean>>().mockResolvedValue(false),
      onPendingChange,
      onConfirmed: vi.fn(),
    });

    coordinator.change("latest");
    await vi.advanceTimersByTimeAsync(500);
    await Promise.resolve();
    expect(onPendingChange).toHaveBeenCalledWith(true);
    expect(onPendingChange).not.toHaveBeenCalledWith(false);
  });

  it("flushes a pending edit immediately on dispose (before the debounce elapses)", async () => {
    vi.useFakeTimers();
    const persist = vi.fn<(contents: string) => Promise<boolean>>().mockResolvedValue(true);
    const coordinator = new FileSaveCoordinator({
      debounceMs: 500,
      persist,
      onPendingChange: vi.fn(),
      onConfirmed: vi.fn(),
    });

    coordinator.change("unsaved");
    // Dispose well before the 500ms debounce would have fired.
    coordinator.dispose();
    await Promise.resolve();
    expect(persist).toHaveBeenCalledOnce();
    expect(persist).toHaveBeenCalledWith("unsaved");
  });
});
