import { describe, expect, it } from "vitest";
import type * as domain from "@agent-deck/domain";
import type * as contracts from "../src/index.ts";

/**
 * Type-level parity: the Effect-derived types must be mutually assignable with
 * the originals in @agent-deck/domain (zod-inferred ClientMessage; hand-written
 * ServerMessage/SessionMeta/ProjectMeta/DiscoveredProject/ProjectType). The
 * ServerMessage side has no runtime zod validation, so this compile-time check
 * is its whole parity story. Any drift fails `tsc --noEmit` (and vitest, which
 * type-checks this file on transform).
 */

type MutuallyAssignable<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;

// Wire messages
const clientMessage: MutuallyAssignable<contracts.ClientMessage, domain.ClientMessage> = true;
const serverMessage: MutuallyAssignable<contracts.ServerMessage, domain.ServerMessage> = true;

// Metadata shapes
const sessionMeta: MutuallyAssignable<contracts.SessionMeta, domain.SessionMeta> = true;
const projectMeta: MutuallyAssignable<contracts.ProjectMeta, domain.ProjectMeta> = true;
const discoveredProject: MutuallyAssignable<contracts.DiscoveredProject, domain.DiscoveredProject> =
  true;
const projectType: MutuallyAssignable<contracts.ProjectType, domain.ProjectType> = true;

// Plan shapes referenced by SessionMeta
const sessionPlanItem: MutuallyAssignable<contracts.SessionPlanItem, domain.SessionPlanItem> = true;
const planItemStatus: MutuallyAssignable<contracts.PlanItemStatus, domain.PlanItemStatus> = true;

describe("contracts ⇄ domain type parity", () => {
  it("derived Effect types are mutually assignable with the domain originals", () => {
    // The real assertions are the compile-time `true` literals above.
    expect([
      clientMessage,
      serverMessage,
      sessionMeta,
      projectMeta,
      discoveredProject,
      projectType,
      sessionPlanItem,
      planItemStatus,
    ]).toEqual([true, true, true, true, true, true, true, true]);
  });
});
