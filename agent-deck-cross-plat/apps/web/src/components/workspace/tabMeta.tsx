import { FolderTree, GitCompareArrows, History, MonitorPlay } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import type { WorkspaceTabKind } from "../../state/store.ts";

/**
 * Static metadata for each workspace tab kind (Slice L1) — the tab strip label +
 * icon, the "+" menu entry, and the pane width the kind wants. Kept in one table
 * so the strip, the menu, and the pane stay in lock-step, and so adding the
 * deferred "browser" surface later is a single new entry here.
 *
 * The icons intentionally match the header toggle buttons (FolderTree /
 * MonitorPlay / GitCompareArrows / History) so a tool reads the same in the
 * header and in its tab.
 */
export interface WorkspaceTabMeta {
  /** Short label shown in the tab and the "+" menu. */
  title: string;
  icon: LucideIcon;
  /**
   * The pane width this kind wants when it is the ACTIVE tab. A single width per
   * kind (not per inner-expanded state) keeps the pane logic outside the panels'
   * component-local view state; the values match each tool's current EXPANDED
   * width so the wide diff file-view / preview embed never regress. See
   * TabbedPane for the rationale.
   */
  width: string;
}

export const WORKSPACE_TAB_META: Record<WorkspaceTabKind, WorkspaceTabMeta> = {
  files: { title: "Files", icon: FolderTree, width: "min(42vw, 560px)" },
  preview: { title: "Preview", icon: MonitorPlay, width: "min(46vw, 640px)" },
  diff: { title: "Changes", icon: GitCompareArrows, width: "min(42vw, 560px)" },
  checkpoints: { title: "Checkpoints", icon: History, width: "300px" },
};

/**
 * The order tools appear in the "+" menu (matches the header button order:
 * files, preview, diff, checkpoints). Tab STRIP order is insertion order and is
 * independent of this.
 */
export const WORKSPACE_TAB_MENU_ORDER: readonly WorkspaceTabKind[] = [
  "files",
  "preview",
  "diff",
  "checkpoints",
];
