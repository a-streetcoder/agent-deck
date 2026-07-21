/**
 * Command-palette pure logic (Slice 14) — command sourcing shape, fuzzy ranking,
 * and grouping, split out from the React component so it is unit-testable in
 * isolation. Pattern-ported from the t3code donor's CommandPalette.logic.ts
 * (MIT): the same field-indexed substring ranking (exact > prefix > substring,
 * earlier search terms outrank later ones), simplified to our flat command set
 * (no submenu / filesystem-browse modes).
 *
 * Functions are generic over `<T extends PaletteItem>` so the component's richer
 * items (carrying an icon + a `run` closure + an optional shortcut label) flow
 * through filtering and grouping untouched.
 */

export type PaletteGroupId = "actions" | "navigation" | "sessions" | "projects";

/** Display order of the groups; also the order the arrow keys traverse. */
export const PALETTE_GROUP_ORDER: readonly PaletteGroupId[] = [
  "actions",
  "navigation",
  "sessions",
  "projects",
];

export const PALETTE_GROUP_LABELS: Record<PaletteGroupId, string> = {
  actions: "Actions",
  navigation: "Go to",
  sessions: "Sessions",
  projects: "Projects",
};

/** How many sessions the root (empty-query) view shows before the user filters. */
export const RECENT_SESSION_LIMIT = 8;

export interface PaletteItem {
  readonly id: string;
  readonly title: string;
  readonly subtitle?: string;
  /** Extra strings the fuzzy filter matches against (synonyms, project name…). */
  readonly keywords: readonly string[];
  readonly group: PaletteGroupId;
}

export interface PaletteGroup<T extends PaletteItem> {
  readonly id: PaletteGroupId;
  readonly label: string;
  readonly items: readonly T[];
}

export function normalizeSearchText(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function rankFieldMatch(field: string, normalizedQuery: string): number {
  const normalizedField = normalizeSearchText(field);
  if (normalizedField.length === 0 || !normalizedField.includes(normalizedQuery)) {
    return Number.NEGATIVE_INFINITY;
  }
  if (normalizedField === normalizedQuery) return 3;
  if (normalizedField.startsWith(normalizedQuery)) return 2;
  return 1;
}

/**
 * Score an item against a normalized query. The title is the strongest field,
 * then each keyword in order; the first field that contains the query decides
 * the score (`1000 - fieldIndex*100 + matchQuality`), so a title hit always
 * beats a keyword-only hit. Returns `-Infinity` when nothing matches.
 */
export function scorePaletteItem(item: PaletteItem, normalizedQuery: string): number {
  const fields = [item.title, ...item.keywords].filter((field) => field.length > 0);
  for (const [index, field] of fields.entries()) {
    const fieldRank = rankFieldMatch(field, normalizedQuery);
    if (fieldRank !== Number.NEGATIVE_INFINITY) {
      return 1_000 - index * 100 + fieldRank;
    }
  }
  return Number.NEGATIVE_INFINITY;
}

/** Filter + rank a flat item list; stable on ties by original position. */
export function filterPaletteItems<T extends PaletteItem>(items: readonly T[], query: string): T[] {
  const normalizedQuery = normalizeSearchText(query);
  if (normalizedQuery.length === 0) return [...items];

  return items
    .map((item, index) => ({ item, index, score: scorePaletteItem(item, normalizedQuery) }))
    .filter((entry) => entry.score !== Number.NEGATIVE_INFINITY)
    .sort((left, right) => right.score - left.score || left.index - right.index)
    .map((entry) => entry.item);
}

/**
 * Group items for display. With an empty query the groups keep their source
 * order and the sessions group is capped at {@link RECENT_SESSION_LIMIT}
 * (recent-first — the caller pre-sorts). With a query the whole set is ranked
 * flat, then re-bucketed into its groups in {@link PALETTE_GROUP_ORDER}; empty
 * groups drop out.
 */
export function buildPaletteGroups<T extends PaletteItem>(input: {
  readonly items: readonly T[];
  readonly query: string;
  readonly sessionLimit?: number;
}): PaletteGroup<T>[] {
  const sessionLimit = input.sessionLimit ?? RECENT_SESSION_LIMIT;
  const normalizedQuery = normalizeSearchText(input.query);
  const ranked = filterPaletteItems(input.items, input.query);

  const groups: PaletteGroup<T>[] = [];
  for (const groupId of PALETTE_GROUP_ORDER) {
    let items = ranked.filter((item) => item.group === groupId);
    if (normalizedQuery.length === 0 && groupId === "sessions") {
      items = items.slice(0, sessionLimit);
    }
    if (items.length > 0) {
      groups.push({ id: groupId, label: PALETTE_GROUP_LABELS[groupId], items });
    }
  }
  return groups;
}

/** Flatten grouped items back into the visual top-to-bottom order (arrow nav). */
export function flattenPaletteGroups<T extends PaletteItem>(
  groups: readonly PaletteGroup<T>[],
): T[] {
  return groups.flatMap((group) => [...group.items]);
}
