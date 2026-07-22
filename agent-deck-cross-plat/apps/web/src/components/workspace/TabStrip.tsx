import { useEffect, useRef, useState } from "react";
import { Plus, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { isElectron } from "@/lib/native";
import { useAppStore, type WorkspaceTabKind } from "../../state/store.ts";
import { WORKSPACE_TAB_MENU_ORDER, WORKSPACE_TAB_META } from "./tabMeta.tsx";

/**
 * The Chrome-style tab strip for the right workspace pane (Slice L1), ported from
 * t3code's RightPanelTabs strip + "+" menu + tab context menu and restyled onto
 * our tokens (border-border-subtle / bg-surface-elevated / selection-fill accent)
 * and our homegrown dismiss idiom (the OpenInPicker outside-click/Escape pattern)
 * rather than a component library.
 *
 * Adapted from the donor: no "terminal" surface (the terminal stays a bottom
 * drawer), our four singleton kinds (diff / files / preview / checkpoints), and
 * the "+" menu gates Diff on the session being a git repo (the moved diffRepo
 * gate). "browser" is a deferred kind — adding it is a new WORKSPACE_TAB_META
 * entry plus its availability rule here.
 */

const DISABLED_REASON: Partial<Record<WorkspaceTabKind, string>> = {
  diff: "Changes are only available for a git repository.",
  browser: "Available in the desktop app.",
};

interface TabContextMenuState {
  kind: WorkspaceTabKind;
  x: number;
  y: number;
}

export function TabStrip(props: {
  sessionId: string;
  tabs: readonly WorkspaceTabKind[];
  activeTab: WorkspaceTabKind | null;
  /** Whether the current session's cwd is a git repo (gates the Diff entry). */
  diffRepo: boolean;
}) {
  const { sessionId, tabs, activeTab, diffRepo } = props;
  const openWorkspaceTab = useAppStore((state) => state.openWorkspaceTab);
  const activateWorkspaceTab = useAppStore((state) => state.activateWorkspaceTab);
  const closeWorkspaceTab = useAppStore((state) => state.closeWorkspaceTab);
  const closeOtherWorkspaceTabs = useAppStore((state) => state.closeOtherWorkspaceTabs);
  const closeWorkspaceTabsToRight = useAppStore((state) => state.closeWorkspaceTabsToRight);
  const closeAllWorkspaceTabs = useAppStore((state) => state.closeAllWorkspaceTabs);

  const [addOpen, setAddOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<TabContextMenuState | null>(null);
  const addRef = useRef<HTMLDivElement>(null);

  // Availability per kind for the "+" menu: Diff needs a git repo; Browser is a
  // real Chromium guest (<webview>) that only exists in the desktop shell.
  const available = (kind: WorkspaceTabKind): boolean => {
    if (kind === "diff") return diffRepo;
    if (kind === "browser") return isElectron();
    return true;
  };

  // Dismiss the "+" menu on outside click / Escape (the OpenInPicker idiom).
  useEffect(() => {
    if (!addOpen) return;
    const onMouse = (event: MouseEvent): void => {
      if (addRef.current && !addRef.current.contains(event.target as Node)) setAddOpen(false);
    };
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") setAddOpen(false);
    };
    document.addEventListener("mousedown", onMouse);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onMouse);
      document.removeEventListener("keydown", onKey);
    };
  }, [addOpen]);

  return (
    <div
      className="flex items-center gap-1 border-b border-border-subtle px-1.5 py-1"
      data-testid="workspace-tab-strip"
    >
      <div
        role="tablist"
        aria-label="Open tools"
        className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
      >
        {tabs.map((kind) => {
          const meta = WORKSPACE_TAB_META[kind];
          const Icon = meta.icon;
          const active = kind === activeTab;
          return (
            <div
              key={kind}
              className={cn(
                "group flex h-7 min-w-0 max-w-40 shrink-0 items-center gap-1.5 rounded-md pl-2 pr-1 text-xs",
                active
                  ? "bg-[var(--color-selection-fill)] text-text-primary"
                  : "text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
              )}
              onContextMenu={(event) => {
                event.preventDefault();
                setContextMenu({ kind, x: event.clientX, y: event.clientY });
              }}
            >
              <button
                type="button"
                role="tab"
                id={`ws-tab-${kind}`}
                aria-selected={active}
                aria-controls={`ws-panel-${kind}`}
                className="flex min-w-0 flex-1 items-center gap-1.5"
                data-testid={`workspace-tab-${kind}`}
                data-active={active}
                title={meta.title}
                onClick={() => activateWorkspaceTab(sessionId, kind)}
              >
                <Icon className="h-3.5 w-3.5 shrink-0" aria-hidden />
                <span className="truncate">{meta.title}</span>
              </button>
              <button
                type="button"
                className={cn(
                  "flex size-4 shrink-0 items-center justify-center rounded hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
                  active ? "opacity-100" : "opacity-0 group-hover:opacity-100",
                )}
                data-testid={`workspace-tab-close-${kind}`}
                aria-label={`Close ${meta.title}`}
                title={`Close ${meta.title}`}
                onClick={(event) => {
                  event.stopPropagation();
                  closeWorkspaceTab(sessionId, kind);
                }}
              >
                <X className="h-3 w-3" aria-hidden />
              </button>
            </div>
          );
        })}
      </div>

      {/* The "+" menu: open another tool as a tab. Diff is disabled (with a
          reason tooltip) when the session is not a git repo. */}
      <div ref={addRef} className="relative shrink-0">
        <button
          type="button"
          className="flex size-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          data-testid="workspace-tab-add"
          aria-label="Open a tool"
          aria-haspopup="menu"
          aria-expanded={addOpen}
          onClick={() => setAddOpen((open) => !open)}
        >
          <Plus className="h-4 w-4" aria-hidden />
        </button>
        {addOpen ? (
          <div
            role="menu"
            aria-label="Open a tool"
            data-testid="workspace-add-menu"
            className="absolute right-0 top-full z-30 mt-1.5 w-52 rounded-xl border border-border-strong bg-surface-elevated p-1.5 shadow-elevated"
          >
            {WORKSPACE_TAB_MENU_ORDER.map((kind) => {
              const meta = WORKSPACE_TAB_META[kind];
              const Icon = meta.icon;
              const enabled = available(kind);
              const isOpen = tabs.includes(kind);
              return (
                <button
                  key={kind}
                  type="button"
                  role="menuitem"
                  data-testid={`workspace-add-${kind}`}
                  disabled={!enabled}
                  title={!enabled ? DISABLED_REASON[kind] : undefined}
                  className={cn(
                    "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs",
                    enabled
                      ? "text-text-secondary hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
                      : "cursor-not-allowed text-text-muted opacity-40",
                  )}
                  onClick={() => {
                    if (!enabled) return;
                    setAddOpen(false);
                    openWorkspaceTab(sessionId, kind);
                  }}
                >
                  <Icon className="h-3.5 w-3.5 shrink-0" aria-hidden />
                  <span className="flex-1 truncate">{meta.title}</span>
                  {isOpen ? <span className="text-[10px] text-text-muted">open</span> : null}
                </button>
              );
            })}
          </div>
        ) : null}
      </div>

      {contextMenu ? (
        <TabContextMenu
          state={contextMenu}
          tabCount={tabs.length}
          isLast={tabs.indexOf(contextMenu.kind) === tabs.length - 1}
          onClose={() => setContextMenu(null)}
          onCloseTab={() => closeWorkspaceTab(sessionId, contextMenu.kind)}
          onCloseOthers={() => closeOtherWorkspaceTabs(sessionId, contextMenu.kind)}
          onCloseToRight={() => closeWorkspaceTabsToRight(sessionId, contextMenu.kind)}
          onCloseAll={() => closeAllWorkspaceTabs(sessionId)}
        />
      ) : null}
    </div>
  );
}

/** The right-click tab menu (Close / Close others / Close to the right / Close
 * all), positioned at the cursor and dismissed on outside click / Escape. */
function TabContextMenu(props: {
  state: TabContextMenuState;
  tabCount: number;
  isLast: boolean;
  onClose: () => void;
  onCloseTab: () => void;
  onCloseOthers: () => void;
  onCloseToRight: () => void;
  onCloseAll: () => void;
}) {
  const { state, tabCount, isLast, onClose } = props;
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onMouse = (event: MouseEvent): void => {
      if (ref.current && !ref.current.contains(event.target as Node)) onClose();
    };
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", onMouse);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onMouse);
      document.removeEventListener("keydown", onKey);
    };
  }, [onClose]);

  const items: { label: string; disabled: boolean; run: () => void; testId: string }[] = [
    { label: "Close", disabled: false, run: props.onCloseTab, testId: "workspace-tab-menu-close" },
    {
      label: "Close others",
      disabled: tabCount <= 1,
      run: props.onCloseOthers,
      testId: "workspace-tab-menu-close-others",
    },
    {
      label: "Close to the right",
      disabled: isLast,
      run: props.onCloseToRight,
      testId: "workspace-tab-menu-close-right",
    },
    {
      label: "Close all",
      disabled: tabCount === 0,
      run: props.onCloseAll,
      testId: "workspace-tab-menu-close-all",
    },
  ];

  return (
    <div
      ref={ref}
      role="menu"
      aria-label="Tab actions"
      data-testid="workspace-tab-menu"
      className="fixed z-40 w-44 rounded-xl border border-border-strong bg-surface-elevated p-1.5 shadow-elevated"
      style={{ left: state.x, top: state.y }}
    >
      {items.map((item) => (
        <button
          key={item.testId}
          type="button"
          role="menuitem"
          data-testid={item.testId}
          disabled={item.disabled}
          className={cn(
            "flex w-full items-center rounded-md px-2 py-1.5 text-left text-xs",
            item.disabled
              ? "cursor-not-allowed text-text-muted opacity-40"
              : "text-text-secondary hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
          )}
          onClick={() => {
            if (item.disabled) return;
            item.run();
            onClose();
          }}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}
