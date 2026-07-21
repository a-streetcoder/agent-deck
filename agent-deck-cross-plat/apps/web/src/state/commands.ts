import { type KeybindingCommand } from "@agent-deck/contracts";
import { type AppView, useAppStore } from "./store.ts";
import { newChat, sendAbort, switchToSession } from "./wsBridge.ts";

/**
 * The single command catalog (Slice 14). Every rebindable action lives here
 * exactly once, so the global keyboard handler
 * ({@link ../state/useKeyboardShortcuts}) and the command palette dispatch
 * through the SAME `run` — there is no parallel hardcoded shortcut path. Each
 * entry carries a display label, a palette group, fuzzy keywords, an optional
 * focus rule (only the terminal toggle fires while the terminal owns focus), and
 * the effect itself (reading the store at call time via `getState`).
 */

export type CommandGroup = "actions" | "navigation";

export interface CommandDefinition {
  readonly command: KeybindingCommand;
  readonly label: string;
  readonly group: CommandGroup;
  readonly keywords: readonly string[];
  /** Fires even while the terminal owns focus (only `terminal.toggle`). */
  readonly firesInTerminal?: boolean;
  readonly run: () => void;
}

/** Nav commands are `view.<AppView>`; this is their canonical order + label. */
const NAV_VIEWS: ReadonlyArray<{ view: AppView; label: string; keywords: readonly string[] }> = [
  { view: "chat", label: "Chat", keywords: ["session", "agent", "pi"] },
  { view: "projects", label: "Projects", keywords: ["repos", "folders"] },
  { view: "instructions", label: "Instructions", keywords: ["agents.md", "context"] },
  { view: "issues", label: "Issues", keywords: ["github", "tickets"] },
  { view: "git", label: "Git", keywords: ["vcs", "commit", "branch", "diff"] },
  { view: "agents", label: "Agents", keywords: ["subagents"] },
  { view: "skills", label: "Skills", keywords: ["tools", "import"] },
  { view: "loops", label: "Loops", keywords: ["automation", "schedule"] },
  { view: "prompts", label: "Prompts", keywords: ["templates"] },
  { view: "memory", label: "Memory", keywords: ["notes"] },
  { view: "models", label: "Models", keywords: ["llm", "picker"] },
  { view: "providers", label: "Providers", keywords: ["auth", "login", "api key"] },
  { view: "environment", label: "Environment", keywords: ["env", "variables", "secrets"] },
  { view: "extensions", label: "Extensions", keywords: ["plugins"] },
  { view: "mcp", label: "MCP", keywords: ["servers", "tools"] },
  { view: "doctor", label: "Doctor", keywords: ["health", "diagnostics"] },
];

// switchToSession() clears the store's `session` synchronously while the resume
// is in flight, so a fast repeat would otherwise recompute from "no selection"
// and jump to the first/last session. Anchor on the last session we targeted so
// successive taps advance adjacently even before the switch resolves.
let lastCycleTargetId: string | null = null;

/** Move selection to the next (+1) or previous (-1) session, wrapping around. */
export function cycleSession(direction: 1 | -1): void {
  const { sessions, session, setView } = useAppStore.getState();
  if (sessions.length === 0) return;
  const anchorId = session?.id ?? lastCycleTargetId;
  const currentIndex = anchorId ? sessions.findIndex((s) => s.id === anchorId) : -1;
  const nextIndex =
    currentIndex === -1
      ? direction === 1
        ? 0
        : sessions.length - 1
      : (currentIndex + direction + sessions.length) % sessions.length;
  const target = sessions[nextIndex];
  if (!target) return;
  lastCycleTargetId = target.id;
  if (target.id !== session?.id) {
    setView("chat");
    void switchToSession(target);
  }
}

const ACTION_COMMANDS: readonly CommandDefinition[] = [
  {
    command: "commandPalette.toggle",
    label: "Command Palette",
    group: "actions",
    keywords: ["search", "commands", "go to"],
    run: () => {
      const store = useAppStore.getState();
      store.setCommandPaletteOpen(!store.commandPaletteOpen);
    },
  },
  {
    command: "terminal.toggle",
    label: "Toggle Terminal",
    group: "actions",
    keywords: ["shell", "console", "drawer"],
    firesInTerminal: true,
    run: () => {
      const store = useAppStore.getState();
      // The terminal lives on the chat surface only (matches the header toggle).
      if (store.view !== "chat") return;
      store.setTerminalOpen(!store.terminalOpen);
    },
  },
  {
    command: "diff.toggle",
    label: "Toggle Changed Files",
    group: "actions",
    keywords: ["diff", "review", "git", "changes"],
    run: () => {
      const store = useAppStore.getState();
      store.setDiffPanelOpen(!store.diffPanelOpen);
    },
  },
  {
    command: "files.toggle",
    label: "Toggle Files Panel",
    group: "actions",
    keywords: ["explorer", "tree", "browse"],
    run: () => {
      const store = useAppStore.getState();
      store.setFilesPanelOpen(!store.filesPanelOpen);
    },
  },
  {
    command: "session.new",
    label: "New Session",
    group: "actions",
    keywords: ["chat", "new chat", "create"],
    run: () => {
      useAppStore.getState().setView("chat");
      void newChat();
    },
  },
  {
    command: "session.stop",
    label: "Stop Session",
    group: "actions",
    keywords: ["abort", "cancel", "interrupt"],
    run: () => {
      sendAbort();
    },
  },
  {
    command: "session.next",
    label: "Next Session",
    group: "actions",
    keywords: ["cycle", "switch", "forward"],
    run: () => {
      cycleSession(1);
    },
  },
  {
    command: "session.previous",
    label: "Previous Session",
    group: "actions",
    keywords: ["cycle", "switch", "back"],
    run: () => {
      cycleSession(-1);
    },
  },
  {
    command: "panel.sessions.toggle",
    label: "Toggle Sessions Panel",
    group: "actions",
    keywords: ["sidebar", "list", "expand"],
    run: () => {
      const store = useAppStore.getState();
      store.setPanelExpanded(!store.panelExpanded);
    },
  },
  {
    command: "keybindings.open",
    label: "Edit Keybindings…",
    group: "actions",
    keywords: ["shortcuts", "keys", "bindings", "customize"],
    run: () => {
      const store = useAppStore.getState();
      store.setCommandPaletteOpen(false);
      store.setKeybindingsEditorOpen(true);
    },
  },
];

const NAV_COMMANDS: readonly CommandDefinition[] = NAV_VIEWS.map(({ view, label, keywords }) => ({
  command: `view.${view}` as KeybindingCommand,
  label: `Go to ${label}`,
  group: "navigation" as const,
  keywords: [label.toLowerCase(), ...keywords],
  run: () => {
    useAppStore.getState().setView(view);
  },
}));

export const COMMAND_DEFINITIONS: readonly CommandDefinition[] = [
  ...ACTION_COMMANDS,
  ...NAV_COMMANDS,
];

const COMMANDS_BY_ID: ReadonlyMap<KeybindingCommand, CommandDefinition> = new Map(
  COMMAND_DEFINITIONS.map((definition) => [definition.command, definition]),
);

export function commandDefinition(command: KeybindingCommand): CommandDefinition | undefined {
  return COMMANDS_BY_ID.get(command);
}

/** Human label for a command id (used by the editor + the conflict toast). */
export function commandLabel(command: KeybindingCommand): string {
  return COMMANDS_BY_ID.get(command)?.label ?? command;
}

/** Run a command by id (the palette and the shortcut handler share this). */
export function runCommand(command: KeybindingCommand): void {
  COMMANDS_BY_ID.get(command)?.run();
}
