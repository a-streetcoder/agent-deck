import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronDown, SquareArrowOutUpRight } from "lucide-react";
import { EDITORS, type EditorId } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import { fetchAvailableEditors, openFileInEditor } from "../../state/wsBridge.ts";
import { useAppStore } from "../../state/store.ts";
import type { Icon } from "./EditorIcons.tsx";
import {
  CursorIcon,
  KiroIcon,
  TraeIcon,
  VSCodiumIcon,
  VisualStudioCodeIcon,
  VisualStudioCodeInsidersIcon,
  ZedIcon,
} from "./EditorIcons.tsx";
import {
  AquaIcon,
  CLionIcon,
  DataGripIcon,
  DataSpellIcon,
  GoLandIcon,
  IntelliJIdeaIcon,
  PhpStormIcon,
  PyCharmIcon,
  RiderIcon,
  RubyMineIcon,
  RustRoverIcon,
  WebStormIcon,
} from "./JetBrainsIcons.tsx";

/**
 * The open-in-editor picker (Slice 11), pattern-ported from t3code's
 * `chat/OpenInPicker.tsx` (MIT) onto our idioms: a split control — a primary
 * button that opens in the REMEMBERED editor (one click on the second use)
 * plus a chevron menu listing every editor the SERVER detected (its own PATH
 * probe; editors not installed simply don't appear), each with its brand icon.
 * The menu uses the composer pickers' dismiss idiom (pickers.tsx useDismiss),
 * not a component library. The remembered choice persists in AppSettings
 * (`preferredEditor` via PATCH /settings) instead of the donor's localStorage,
 * so it follows the app, not the browser profile.
 */

const EDITOR_ICONS: Partial<Record<EditorId, Icon>> = {
  cursor: CursorIcon,
  trae: TraeIcon,
  kiro: KiroIcon,
  vscode: VisualStudioCodeIcon,
  "vscode-insiders": VisualStudioCodeInsidersIcon,
  vscodium: VSCodiumIcon,
  zed: ZedIcon,
  idea: IntelliJIdeaIcon,
  aqua: AquaIcon,
  clion: CLionIcon,
  datagrip: DataGripIcon,
  dataspell: DataSpellIcon,
  goland: GoLandIcon,
  phpstorm: PhpStormIcon,
  pycharm: PyCharmIcon,
  rider: RiderIcon,
  rubymine: RubyMineIcon,
  rustrover: RustRoverIcon,
  webstorm: WebStormIcon,
};

export function editorLabel(id: EditorId): string {
  return EDITORS.find((editor) => editor.id === id)?.label ?? id;
}

function EditorGlyph({ id, className }: { id: EditorId; className?: string }) {
  const BrandIcon = EDITOR_ICONS[id] ?? SquareArrowOutUpRight;
  return <BrandIcon aria-hidden="true" className={className} />;
}

// ---------------------------------------------------------------------------
// Detected-editor list + remembered default (AppSettings), page-load cached.
// ---------------------------------------------------------------------------

let preferredEditorCache: string | null | undefined;

async function loadPreferredEditor(): Promise<string | null> {
  if (preferredEditorCache !== undefined) return preferredEditorCache;
  try {
    const response = await fetch("/settings");
    if (!response.ok) throw new Error(await response.text());
    const data = (await response.json()) as { settings?: { preferredEditor?: string | null } };
    preferredEditorCache = data.settings?.preferredEditor ?? null;
  } catch {
    preferredEditorCache = null;
  }
  return preferredEditorCache;
}

function persistPreferredEditor(editor: EditorId): void {
  preferredEditorCache = editor;
  void fetch("/settings", {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ preferredEditor: editor }),
  }).catch(() => {
    // Persistence is a convenience — the in-memory cache still applies.
  });
}

/**
 * The picker's data + actions: the server-detected editor list, the effective
 * preferred editor (the remembered choice when still detected, else the first
 * detected — the donor's `usePreferredEditor` resolution), and an `open` that
 * launches AND remembers.
 */
export function useOpenInEditor() {
  const [available, setAvailable] = useState<readonly EditorId[]>([]);
  const [stored, setStored] = useState<EditorId | null>(null);
  // The list op needs a live socket: keyed on the connection status so a
  // panel mounted before the transport opened (or across a reconnect) fetches
  // once the socket is actually up instead of caching an empty list.
  const connection = useAppStore((state) => state.connection);

  useEffect(() => {
    if (connection !== "open") return;
    let stale = false;
    void Promise.all([fetchAvailableEditors(), loadPreferredEditor()]).then(
      ([editors, preferred]) => {
        if (stale) return;
        setAvailable(editors);
        setStored(preferred as EditorId | null);
      },
    );
    return () => {
      stale = true;
    };
  }, [connection]);

  const preferred = stored !== null && available.includes(stored) ? stored : (available[0] ?? null);

  const open = useCallback(
    (path: string, line: number | undefined, editor?: EditorId): void => {
      const target = editor ?? preferred;
      if (target === null || target === undefined) return;
      setStored(target);
      persistPreferredEditor(target);
      void openFileInEditor(path, line, target).catch((error: unknown) => {
        useAppStore.getState().setError(String(error));
      });
    },
    [preferred],
  );

  return { available, preferred, open };
}

// ---------------------------------------------------------------------------
// The split control (primary open + chevron menu)
// ---------------------------------------------------------------------------

export function OpenInPicker({
  available,
  preferred,
  onOpen,
  className,
}: {
  available: readonly EditorId[];
  preferred: EditorId | null;
  /** Open in `editor` (a picked option) or the preferred one (undefined). */
  onOpen: (editor?: EditorId) => void;
  /**
   * Reveal classes (e.g. `hidden group-hover/…:flex`) — the affordance stays
   * out of the resting layout (visual-baseline-neutral); ignored while the
   * menu is open so it can't vanish when the pointer moves into the popup.
   */
  className?: string;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  // The composer pickers' dismiss idiom (pickers.tsx): outside click / Escape.
  useEffect(() => {
    if (!menuOpen) return;
    const onMouse = (event: MouseEvent): void => {
      if (ref.current && !ref.current.contains(event.target as Node)) setMenuOpen(false);
    };
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") setMenuOpen(false);
    };
    document.addEventListener("mousedown", onMouse);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onMouse);
      document.removeEventListener("keydown", onKey);
    };
  }, [menuOpen]);

  if (available.length === 0 || preferred === null) return null;

  const buttonClass =
    "flex items-center rounded p-0.5 text-text-muted transition-colors " +
    "hover:bg-[var(--color-hover-fill)] hover:text-text-primary";

  return (
    <div
      ref={ref}
      className={cn("relative flex shrink-0 items-center", menuOpen ? undefined : className)}
    >
      <button
        type="button"
        className={buttonClass}
        title={`Open in ${editorLabel(preferred)}`}
        aria-label={`Open in ${editorLabel(preferred)}`}
        data-testid="open-in-editor"
        onClick={() => {
          setMenuOpen(false);
          onOpen();
        }}
      >
        <EditorGlyph id={preferred} className="h-3.5 w-3.5" />
      </button>
      <button
        type="button"
        className={buttonClass}
        title="Choose editor"
        aria-label="Choose editor"
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        data-testid="open-in-menu-trigger"
        onClick={() => setMenuOpen((open) => !open)}
      >
        <ChevronDown aria-hidden="true" className="h-3 w-3" />
      </button>
      {menuOpen && (
        <div
          role="menu"
          aria-label="Open in editor"
          data-testid="open-in-menu"
          className="absolute right-0 top-full z-20 mt-1.5 w-48 rounded-xl border border-border-strong bg-surface-elevated p-1.5 shadow-elevated"
        >
          {available.map((editor) => (
            <button
              key={editor}
              type="button"
              role="menuitem"
              data-testid={`open-in-option-${editor}`}
              className={cn(
                "flex w-full items-center gap-2 rounded-md px-2 py-1 text-left text-xs",
                editor === preferred
                  ? "bg-[var(--color-selection-fill)] text-text-primary"
                  : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
              )}
              onClick={() => {
                setMenuOpen(false);
                onOpen(editor);
              }}
            >
              <EditorGlyph id={editor} className="h-3.5 w-3.5 shrink-0" />
              <span className="truncate">{editorLabel(editor)}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
