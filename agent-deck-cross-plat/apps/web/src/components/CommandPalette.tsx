import { useEffect, useMemo, useRef, useState } from "react";
import {
  formatChordString,
  resolveKeybindings,
  type KeybindingCommand,
} from "@agent-deck/contracts";
import { ArrowRight, Folder, MessageSquareText, Search, Zap } from "lucide-react";
import { cn } from "@/lib/cn";
import { detectPlatform } from "@/lib/platform";
import { projectDisplayName, sessionDisplayTitle } from "@/lib/sessionTitle";
import { COMMAND_DEFINITIONS } from "../state/commands.ts";
import { useAppStore } from "../state/store.ts";
import { switchToSession } from "../state/wsBridge.ts";
import {
  buildPaletteGroups,
  flattenPaletteGroups,
  type PaletteGroupId,
  type PaletteItem,
} from "./CommandPalette.logic.ts";

/**
 * The command palette (Slice 14): a Ctrl/⌘+K overlay over every command, nav
 * destination, session, and project. Command sourcing + fuzzy ranking + grouping
 * are the pure {@link ./CommandPalette.logic} functions; this component wires
 * them to the store, renders the grouped list, and drives arrow/enter/esc
 * keyboard navigation. Pattern-ported in spirit from the t3code donor's
 * CommandPalette (MIT), rewritten against our store + design tokens.
 */

interface PaletteCommandItem extends PaletteItem {
  readonly run: () => void;
  readonly shortcutLabel: string | null;
}

const GROUP_ICON: Record<PaletteGroupId, typeof Zap> = {
  actions: Zap,
  navigation: ArrowRight,
  sessions: MessageSquareText,
  projects: Folder,
};

export function CommandPalette() {
  const open = useAppStore((state) => state.commandPaletteOpen);
  const setOpen = useAppStore((state) => state.setCommandPaletteOpen);
  const sessions = useAppStore((state) => state.sessions);
  const projects = useAppStore((state) => state.projects);
  const currentSessionId = useAppStore((state) => state.session?.id ?? null);
  const keybindings = useAppStore((state) => state.keybindings);
  const setCurrentProject = useAppStore((state) => state.setCurrentProject);
  const setView = useAppStore((state) => state.setView);

  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);

  // A fresh query + top selection every time the palette opens.
  useEffect(() => {
    if (open) {
      setQuery("");
      setHighlight(0);
      // Focus after the overlay mounts.
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  const items = useMemo<PaletteCommandItem[]>(() => {
    const platform = detectPlatform();
    const resolved = resolveKeybindings(keybindings);
    const shortcutFor = (command: KeybindingCommand): string | null => {
      const chord = resolved.get(command);
      return chord ? formatChordString(chord, platform) : null;
    };

    const commandItems: PaletteCommandItem[] = COMMAND_DEFINITIONS.map((definition) => ({
      id: `command:${definition.command}`,
      title: definition.label,
      keywords: definition.keywords,
      group: definition.group,
      shortcutLabel: shortcutFor(definition.command),
      run: definition.run,
    }));

    const sortedSessions = [...sessions].sort((left, right) =>
      (right.updatedAt ?? right.createdAt).localeCompare(left.updatedAt ?? left.createdAt),
    );
    const sessionItems: PaletteCommandItem[] = sortedSessions.map((session) => {
      const projectName = projectDisplayName(projects, session.projectId);
      const title = sessionDisplayTitle(session.title, projectName);
      return {
        id: `session:${session.id}`,
        title,
        subtitle: session.id === currentSessionId ? `${projectName} · Current` : projectName,
        keywords: [title, projectName],
        group: "sessions",
        shortcutLabel: null,
        run: () => {
          setView("chat");
          void switchToSession(session);
        },
      };
    });

    const projectItems: PaletteCommandItem[] = projects.map((project) => ({
      id: `project:${project.id}`,
      title: project.name,
      subtitle: project.path,
      keywords: [project.name, project.path],
      group: "projects",
      shortcutLabel: null,
      run: () => {
        setCurrentProject(project.id);
      },
    }));

    return [...commandItems, ...sessionItems, ...projectItems];
  }, [sessions, projects, currentSessionId, keybindings, setCurrentProject, setView]);

  const groups = useMemo(() => buildPaletteGroups({ items, query }), [items, query]);
  const flat = useMemo(() => flattenPaletteGroups(groups), [groups]);

  // Keep the highlight in range as the filtered list shrinks/grows.
  useEffect(() => {
    setHighlight((current) => (flat.length === 0 ? 0 : Math.min(current, flat.length - 1)));
  }, [flat.length]);

  // Scroll the highlighted row into view as it moves.
  useEffect(() => {
    if (!open) return;
    const node = listRef.current?.querySelector<HTMLElement>('[data-selected="true"]');
    node?.scrollIntoView({ block: "nearest" });
  }, [highlight, open]);

  if (!open) return null;

  const runItem = (item: PaletteCommandItem | undefined): void => {
    if (!item) return;
    setOpen(false);
    item.run();
  };

  const onKeyDown = (event: React.KeyboardEvent): void => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setHighlight((current) => (flat.length === 0 ? 0 : (current + 1) % flat.length));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setHighlight((current) =>
        flat.length === 0 ? 0 : (current - 1 + flat.length) % flat.length,
      );
    } else if (event.key === "Enter") {
      event.preventDefault();
      runItem(flat[highlight]);
    } else if (event.key === "Escape") {
      event.preventDefault();
      setOpen(false);
    } else if (event.key === "Tab") {
      // The palette is arrow-key driven: this keydown handler lives on the search
      // input, and selection is tracked by `highlight` state (not DOM focus). The
      // command rows ARE focusable buttons, so a bare Tab would move DOM focus off
      // the input onto a row — which both silences arrow navigation (the handler
      // is on the input) and splits selection between DOM focus and `highlight`.
      // Trapping Tab on the input keeps the single, arrow-driven selection model.
      event.preventDefault();
    }
  };

  let flatIndex = -1;

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/40 p-4 pt-[12vh] backdrop-blur-sm"
      data-testid="command-palette"
      onMouseDown={(event) => {
        // Click on the backdrop (not the panel) closes.
        if (event.target === event.currentTarget) setOpen(false);
      }}
    >
      <div
        className="flex max-h-[72vh] w-full max-w-[600px] flex-col overflow-hidden rounded-xl border border-border-strong bg-surface-elevated shadow-card"
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        data-testid="command-palette-dialog"
      >
        <div className="flex items-center gap-2 border-b border-border-subtle px-3.5 py-2.5">
          <Search className="h-4 w-4 shrink-0 text-text-muted" />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => {
              setQuery(event.target.value);
              setHighlight(0);
            }}
            onKeyDown={onKeyDown}
            placeholder="Search commands, sessions, and projects…"
            className="w-full bg-transparent text-sm text-text-primary placeholder:text-text-muted focus:outline-none"
            data-testid="command-palette-input"
            spellCheck={false}
            autoComplete="off"
          />
        </div>

        <div ref={listRef} className="min-h-0 flex-1 overflow-y-auto py-1.5">
          {flat.length === 0 ? (
            <div
              className="px-4 py-6 text-center text-sm text-text-muted"
              data-testid="command-palette-empty"
            >
              No matching commands
            </div>
          ) : (
            groups.map((group) => {
              const GroupIcon = GROUP_ICON[group.id];
              return (
                <div key={group.id} data-testid="command-palette-group" data-group={group.id}>
                  <div className="px-4 pb-0.5 pt-2 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
                    {group.label}
                  </div>
                  {group.items.map((item) => {
                    flatIndex += 1;
                    const selected = flatIndex === highlight;
                    const index = flatIndex;
                    return (
                      <button
                        key={item.id}
                        type="button"
                        className={cn(
                          "flex w-full items-center gap-2.5 px-3 py-1.5 text-left",
                          selected
                            ? "bg-[var(--color-selection-fill)]"
                            : "hover:bg-[var(--color-hover-fill)]",
                        )}
                        data-testid="command-palette-item"
                        data-command={item.id}
                        data-selected={selected}
                        onMouseMove={() => setHighlight(index)}
                        onClick={() => runItem(item)}
                      >
                        <GroupIcon className="h-4 w-4 shrink-0 text-text-muted" />
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-[13px] text-text-primary">
                            {item.title}
                          </span>
                          {item.subtitle ? (
                            <span className="block truncate text-xs text-text-muted">
                              {item.subtitle}
                            </span>
                          ) : null}
                        </span>
                        {item.shortcutLabel ? (
                          <kbd className="shrink-0 rounded border border-border-subtle bg-surface px-1.5 py-0.5 font-mono text-[11px] text-text-secondary">
                            {item.shortcutLabel}
                          </kbd>
                        ) : null}
                      </button>
                    );
                  })}
                </div>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
}
