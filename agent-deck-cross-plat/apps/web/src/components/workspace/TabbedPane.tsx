import { cn } from "@/lib/cn";
import { useAppStore, type WorkspaceTabKind } from "../../state/store.ts";
import { ResizeHandle, useResizable } from "../common/Resizable.tsx";
import { BrowserPanel } from "../browser/BrowserPanel.tsx";
import { CheckpointsPanel } from "../CheckpointsPanel.tsx";
import { DiffPanel } from "../diff/DiffPanel.tsx";
import { FilesPanel } from "../files/FilesPanel.tsx";
import { PreviewPanel } from "../preview/PreviewPanel.tsx";
import { TabStrip } from "./TabStrip.tsx";
import { WORKSPACE_TAB_META } from "./tabMeta.tsx";

const WORKSPACE_WIDTH_KEY = "agentdeck:workspace-width";

/** Evaluate a tabMeta width CSS string (`min(42vw, 560px)`, `300px`) to a px
 * number, so the resizable pane can SEED its default from the per-kind width the
 * L1 pane used to hard-code. `min(...)` takes the smallest term; a bare value is
 * used as-is; vw is resolved against the current viewport. */
function evalTabWidth(expr: string): number {
  const vwUnit = (typeof window === "undefined" ? 1280 : window.innerWidth) / 100;
  const terms: number[] = [];
  const re = /([\d.]+)(px|vw)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(expr)) !== null) {
    terms.push(
      match[2] === "vw" ? Number.parseFloat(match[1]!) * vwUnit : Number.parseFloat(match[1]!),
    );
  }
  if (terms.length === 0) return 560;
  return expr.trim().startsWith("min") ? Math.min(...terms) : Math.max(...terms);
}

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
 * PANE WIDTH (Slice L4a): the aside is USER-RESIZABLE — a single width persisted
 * via useResizable, seeded on first open from the active kind's WORKSPACE_TAB_META
 * width (so the initial size matches the old L1 per-kind sizing) and drag-adjusted
 * thereafter. A `maxWidth` viewport cap keeps it from overflowing + collapsing the
 * chat column when the window shrinks below the persisted width.
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

  // The pane width is now user-resizable (Slice L4a). A SINGLE persisted width
  // subsumes the old per-kind fixed width; its default seeds from the active
  // kind's tabMeta width (so a first open matches the previous L1 sizing), and
  // the wider files split is the same drag mechanism. Called unconditionally
  // (before any early return) to keep hook order stable.
  const pane = useResizable({
    storageKey: WORKSPACE_WIDTH_KEY,
    defaultWidth: evalTabWidth(WORKSPACE_TAB_META[activeTab ?? tabs[0] ?? "files"]!.width),
    min: 360,
    max: Math.max(
      720,
      Math.round((typeof window === "undefined" ? 1600 : window.innerWidth) * 0.8),
    ),
    edge: "left",
  });

  // The pane only exists on the chat surface for a session with >=1 open tab.
  if (view !== "chat" || sessionId === null || tabs.length === 0) return null;

  return (
    <>
      <ResizeHandle
        handleProps={pane.handleProps}
        isDragging={pane.isDragging}
        testId="workspace-resize"
        ariaLabel="Resize workspace pane"
        width={pane.width}
        min={pane.min}
        max={pane.max}
      />
      <aside
        className="flex shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
        // maxWidth caps the persisted px width to the viewport live, so a wide
        // pane can't overflow + collapse the chat column when the window shrinks.
        style={{ width: `${pane.width}px`, maxWidth: "85vw" }}
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
    </>
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
    case "browser":
      return <BrowserPanel />;
  }
}
