import { cn } from "@/lib/cn";
import { useAppStore, type WorkspaceTabKind } from "../../state/store.ts";
import { CheckpointsPanel } from "../CheckpointsPanel.tsx";
import { DiffPanel } from "../diff/DiffPanel.tsx";
import { FilesPanel } from "../files/FilesPanel.tsx";
import { PreviewPanel } from "../preview/PreviewPanel.tsx";
import { TabStrip } from "./TabStrip.tsx";
import { WORKSPACE_TAB_META } from "./tabMeta.tsx";

/**
 * The single right-side workspace pane (Slice L1). Replaces the four side-by-side
 * <aside> tool panels (diff / files / preview / checkpoints) with ONE aside that
 * has a Chrome-style tab strip on top and the tool bodies below. Ported from
 * t3code's RightPanelTabs shell, restyled onto our tokens. The DeckPanel (auto
 * subagent aside) and the TerminalDrawer (bottom drawer) are unaffected — only
 * the four toggle-driven tool panels move into this pane.
 *
 * KEEP-ALIVE (load-bearing): every OPEN tab's body is rendered and the inactive
 * ones are hidden with `display:none` (the `hidden` class), NOT unmounted. This
 * keeps the Preview tab's live cross-origin dev-server iframe and its
 * component-local state (url / logs / selected script) alive across tab switches,
 * and likewise preserves the diff/files scroll position and selected-file view.
 * A tab only unmounts when it is CLOSED (removed from the strip).
 *
 * PANE WIDTH: the aside width follows the ACTIVE tab's kind via
 * WORKSPACE_TAB_META (preview ~640, diff/files ~560, checkpoints 300). Width is
 * chosen per-KIND, not per inner-expanded state, because the "expanded" flags
 * (diff's selected file, preview's running server) are component-local useState
 * the pane can't cheaply read; each kind's width is set to its EXPANDED value so
 * the wide diff file-view and the preview embed never regress (the only cost is a
 * slightly wider tree-only diff/files view, which is harmless).
 */
export function TabbedPane() {
  const view = useAppStore((state) => state.view);
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const diffRepo = useAppStore((state) => state.diffRepo);
  const tabsState = useAppStore((state) =>
    sessionId ? state.workspaceTabs[sessionId] : undefined,
  );

  const tabs = tabsState?.tabs ?? [];
  const activeTab = tabsState?.activeTab ?? null;

  // The pane only exists on the chat surface for a session with >=1 open tab.
  if (view !== "chat" || sessionId === null || tabs.length === 0) return null;

  const width = WORKSPACE_TAB_META[activeTab ?? tabs[0]!].width;

  return (
    <aside
      className="flex shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
      style={{ width }}
      data-testid="workspace-pane"
    >
      <TabStrip sessionId={sessionId} tabs={tabs} activeTab={activeTab} diffRepo={diffRepo} />
      <div className="flex min-h-0 flex-1 flex-col">
        {tabs.map((kind) => (
          <div
            key={kind}
            role="tabpanel"
            id={`ws-panel-${kind}`}
            aria-labelledby={`ws-tab-${kind}`}
            aria-hidden={kind !== activeTab}
            data-testid={`workspace-body-${kind}`}
            className={cn("min-h-0 flex-1 flex-col", kind === activeTab ? "flex" : "hidden")}
          >
            <TabBody kind={kind} />
          </div>
        ))}
      </div>
    </aside>
  );
}

function TabBody({ kind }: { kind: WorkspaceTabKind }) {
  switch (kind) {
    case "diff":
      return <DiffPanel />;
    case "files":
      return <FilesPanel />;
    case "preview":
      return <PreviewPanel />;
    case "checkpoints":
      return <CheckpointsPanel />;
  }
}
