import { Composer } from "./components/Composer.tsx";
import { Sidebar } from "./components/Sidebar.tsx";
import { Transcript } from "./components/Transcript.tsx";
import { PiAgentProcessingIndicatorBar } from "@/components/transcript/PiAgentProcessingIndicatorBar";
import { AgentsScreen } from "./screens/AgentsScreen.tsx";
import { InstructionsScreen } from "./screens/InstructionsScreen.tsx";
import { ModelsScreen } from "./screens/ModelsScreen.tsx";
import { ProjectsScreen } from "./screens/ProjectsScreen.tsx";
import { PromptsScreen } from "./screens/PromptsScreen.tsx";
import { DoctorScreen, EnvironmentScreen } from "./screens/RuntimeScreens.tsx";
import { SkillsScreen } from "./screens/SkillsScreen.tsx";
import { cn } from "@/lib/cn";
import { isMacDesktop } from "@/lib/native";
import { projectDisplayName, sessionDisplayTitle } from "@/lib/sessionTitle";
import { useAppStore } from "./state/store.ts";
import { useMenuCommands } from "./state/useMenuCommands.ts";

/**
 * Detail routing mirrors the native ContentView: the chat surface stays
 * PERMANENTLY MOUNTED and is shown/hidden purely via opacity + a whisper of
 * scale (SidebarTransition spring ≈ 340ms), so returning to it is instant and
 * streaming state never tears down. Other screens mount on demand and slide
 * in on the same curve.
 */
const DETAIL_MOVE = "transform 340ms cubic-bezier(0.3, 1.04, 0.4, 1)";
const DETAIL_FADE = "opacity 200ms ease-out";

const VIEW_TITLES: Record<string, string> = {
  agents: "Agents",
  skills: "Skills",
  projects: "Projects",
  instructions: "Instructions",
  prompts: "Prompts",
  models: "Models",
  environment: "Environment",
  doctor: "Doctor",
};

function ChatColumn() {
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  return (
    <div className="flex h-full min-w-0 flex-col">
      <Transcript />
      <PiAgentProcessingIndicatorBar
        message={agentStatus === "running" ? "Pi is working…" : null}
        className="px-6"
      />
      <Composer />
    </div>
  );
}

export function App() {
  const connection = useAppStore((state) => state.connection);
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const session = useAppStore((state) => state.session);
  const projects = useAppStore((state) => state.projects);
  const error = useAppStore((state) => state.error);
  const view = useAppStore((state) => state.view);
  const isChat = view === "chat";
  const chatTitle = session
    ? sessionDisplayTitle(session.title, projectDisplayName(projects, session.projectId))
    : "Pi Agent";
  useMenuCommands();
  // The frameless macOS window needs a drag region across the top bar so the
  // window can be moved by its header (the sidebar strip is already draggable).
  const macDesktop = isMacDesktop();

  const statusLabel =
    connection !== "open" ? connection : agentStatus === "running" ? "responding" : "idle";
  const statusColor =
    connection !== "open"
      ? "var(--color-warning)"
      : agentStatus === "running"
        ? "var(--color-brand-accent)"
        : "var(--color-success)";

  return (
    <div className="flex h-full">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        <header
          className={cn(
            "flex items-center justify-between border-b border-border-subtle bg-surface-elevated px-6 py-2.5",
            macDesktop && "[-webkit-app-region:drag]",
          )}
        >
          <div className="flex items-baseline gap-3">
            <h1
              className="text-sm font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {isChat ? chatTitle : VIEW_TITLES[view]}
            </h1>
            {session && isChat ? (
              <span
                className="max-w-[40ch] truncate font-mono text-xs text-text-muted"
                data-testid="session-cwd"
              >
                {session.cwd}
              </span>
            ) : null}
          </div>
          <div
            className="flex items-center gap-2"
            data-testid="status-indicator"
            data-status={statusLabel}
          >
            <span
              className="inline-block h-2.5 w-2.5 rounded-full"
              style={{ background: statusColor }}
            />
            <span className="text-sm text-text-secondary">{statusLabel}</span>
          </div>
        </header>
        {error ? (
          <div
            className="px-6 py-2 text-sm"
            style={{ background: "rgba(229,116,108,0.15)", color: "var(--color-role-error)" }}
            data-testid="error-banner"
          >
            {error}
          </div>
        ) : null}

        <main className="relative min-h-0 flex-1">
          {/* Chat layer: always mounted. */}
          <div
            className="absolute inset-0"
            data-testid="chat-layer"
            inert={!isChat}
            aria-hidden={!isChat}
            style={{
              transition: `${DETAIL_MOVE}, ${DETAIL_FADE}`,
              transform: isChat ? "none" : "scale(0.985)",
              opacity: isChat ? 1 : 0,
              pointerEvents: isChat ? "auto" : "none",
            }}
          >
            <ChatColumn />
          </div>

          {/* Other screens: mount on demand, slide in on the same curve. */}
          {!isChat ? (
            <div className="detail-enter absolute inset-0 flex flex-col overflow-hidden">
              {view === "agents" ? (
                <AgentsScreen />
              ) : view === "skills" ? (
                <SkillsScreen />
              ) : view === "projects" ? (
                <ProjectsScreen />
              ) : view === "instructions" ? (
                <InstructionsScreen />
              ) : view === "prompts" ? (
                <PromptsScreen />
              ) : view === "models" ? (
                <ModelsScreen />
              ) : view === "environment" ? (
                <EnvironmentScreen />
              ) : (
                <DoctorScreen />
              )}
            </div>
          ) : null}
        </main>
      </div>
    </div>
  );
}
