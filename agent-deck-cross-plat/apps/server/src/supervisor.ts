import { randomUUID } from "node:crypto";

/**
 * The supervisor channel: a child subagent talks UP to its parent through the
 * `contact_supervisor` bridge tool (native-subagent-bridge.md). This registry
 * records those requests keyed by parent + child. v1 handles only the
 * non-blocking `progress_update`; the blocking methods (need_decision,
 * interview_request) and the parent's list/answer flow are later slices.
 */

export type SupervisorMethod = "progress_update" | "need_decision" | "interview_request";

/** need_decision / interview_request suspend the child until answered. */
export function isBlockingMethod(method: SupervisorMethod): boolean {
  return method === "need_decision" || method === "interview_request";
}

export type SupervisorStatus = "recorded" | "pending" | "answered" | "cancelled";

export interface SupervisorRequest {
  id: string;
  parentSessionId: string;
  /** The parent transcript's subagent cell this child streams into. */
  cellId: string;
  method: SupervisorMethod;
  title?: string;
  message: string;
  /** recorded = non-blocking progress; pending = awaiting an answer; answered. */
  status: SupervisorStatus;
  response?: string;
  createdAt: string;
}

export class SupervisorLog {
  private readonly entries: SupervisorRequest[] = [];

  record(entry: {
    id?: string;
    parentSessionId: string;
    cellId: string;
    method: SupervisorMethod;
    title?: string;
    message: string;
    now?: string;
  }): SupervisorRequest {
    const request: SupervisorRequest = {
      id: entry.id ?? randomUUID(),
      parentSessionId: entry.parentSessionId,
      cellId: entry.cellId,
      method: entry.method,
      title: entry.title,
      message: entry.message,
      status: isBlockingMethod(entry.method) ? "pending" : "recorded",
      createdAt: entry.now ?? new Date().toISOString(),
    };
    this.entries.push(request);
    return request;
  }

  /** Mark a pending blocking request answered with the response. No-op if unknown. */
  markAnswered(id: string, response: string): void {
    const request = this.entries.find((e) => e.id === id);
    if (!request) return;
    request.status = "answered";
    request.response = response;
  }

  /** Mark a pending request cancelled (timed out / subagent ended). No-op if
   * unknown or already answered. */
  markCancelled(id: string, reason: string): void {
    const request = this.entries.find((e) => e.id === id);
    if (!request || request.status === "answered") return;
    request.status = "cancelled";
    request.response = reason;
  }

  /** All recorded requests, optionally filtered to one parent session. */
  list(parentSessionId?: string): SupervisorRequest[] {
    return parentSessionId
      ? this.entries.filter((e) => e.parentSessionId === parentSessionId)
      : [...this.entries];
  }
}
