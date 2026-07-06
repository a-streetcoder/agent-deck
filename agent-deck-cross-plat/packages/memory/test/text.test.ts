import { describe, expect, it } from "vitest";
import { informativeTerms, memoryTerms, overlapCoefficient, sharedTerms } from "../src/text.ts";

describe("lexical text primitives", () => {
  it("drops stopwords and 1-char tokens, keeps informative terms", () => {
    const terms = informativeTerms("How do I run the deploy pipeline?");
    expect(terms.has("deploy")).toBe(true);
    expect(terms.has("pipeline")).toBe(true); // ends in "e" — not stemmed
    expect(terms.has("the")).toBe(false);
    expect(terms.has("do")).toBe(false);
    expect(terms.has("i")).toBe(false);
  });

  it("stems plurals and -ing/-ed so paraphrases overlap", () => {
    const a = informativeTerms("running the tests");
    const b = informativeTerms("run a test");
    expect([...sharedTerms(a, b)].sort()).toEqual(["run", "test"]);
  });

  it("stems -s / -es / -ies plurals to their singular", () => {
    // services->service, boxes->box, parties->party (not over-trimmed).
    expect(sharedTerms(informativeTerms("services"), informativeTerms("service"))).toEqual([
      "service",
    ]);
    expect(sharedTerms(informativeTerms("boxes"), informativeTerms("box"))).toEqual(["box"]);
    expect(sharedTerms(informativeTerms("parties"), informativeTerms("party"))).toEqual(["party"]);
    expect(sharedTerms(informativeTerms("releases"), informativeTerms("release"))).toEqual([
      "release",
    ]);
  });

  it("memoryTerms draws only from title/summary/tags", () => {
    const terms = memoryTerms({
      title: "Deploy runbook",
      summary: "push to release",
      tags: ["ci"],
    });
    expect(terms.has("deploy")).toBe(true);
    expect(terms.has("release")).toBe(true); // ends in "e" — not stemmed
    expect(terms.has("ci")).toBe(true);
  });

  it("overlap coefficient is 1 when one term set is a subset of the other", () => {
    const small = informativeTerms("deploy server");
    const big = informativeTerms("deploy the production server pipeline");
    expect(overlapCoefficient(small, big)).toBe(1);
  });

  it("overlap coefficient is 0 for disjoint or empty sets", () => {
    expect(overlapCoefficient(informativeTerms("apples"), informativeTerms("oranges"))).toBe(0);
    expect(overlapCoefficient(new Set(), informativeTerms("anything"))).toBe(0);
  });
});
