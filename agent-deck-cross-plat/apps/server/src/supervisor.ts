import { randomUUID } from "node:crypto";

/**
 * The supervisor channel: a child subagent talks UP to its parent through the
 * `contact_supervisor` bridge tool (native-subagent-bridge.md). This registry
 * records those requests keyed by parent + child. v1 handles only the
 * non-blocking `progress_update`; the blocking methods (need_decision,
 * interview_request) and the parent's list/answer flow are later slices.
 */

export type SupervisorMethod = "progress_update" | "need_decision" | "interview_request";

export interface SupervisorRequest {
  id: string;
  parentSessionId: string;
  /** The parent transcript's subagent cell this child streams into. */
  cellId: string;
  method: SupervisorMethod;
  title?: string;
  message: string;
  createdAt: string;
}

export class SupervisorLog {
  private readonly entries: SupervisorRequest[] = [];

  record(entry: {
    parentSessionId: string;
    cellId: string;
    method: SupervisorMethod;
    title?: string;
    message: string;
    now?: string;
  }): SupervisorRequest {
    const request: SupervisorRequest = {
      id: randomUUID(),
      parentSessionId: entry.parentSessionId,
      cellId: entry.cellId,
      method: entry.method,
      title: entry.title,
      message: entry.message,
      createdAt: entry.now ?? new Date().toISOString(),
    };
    this.entries.push(request);
    return request;
  }

  /** All recorded requests, optionally filtered to one parent session. */
  list(parentSessionId?: string): SupervisorRequest[] {
    return parentSessionId
      ? this.entries.filter((e) => e.parentSessionId === parentSessionId)
      : [...this.entries];
  }
}
