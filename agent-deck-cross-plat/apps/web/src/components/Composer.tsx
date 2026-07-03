import { useCallback, useEffect, useState } from "react";
import TextareaAutosize from "react-textarea-autosize";
import { useAppStore } from "../state/store.ts";
import { useAgents } from "../state/useAgents.ts";
import {
  sendAbort,
  sendPrompt,
  sendSetModel,
  sendSetThinking,
  switchToAgent,
} from "../state/wsBridge.ts";
import {
  ModelChip,
  SendStopButton,
  ThinkingChip,
  chipClass,
  type PiComposerState,
  type PiModelInfo,
} from "./composer/pickers.tsx";

/**
 * The composer, styled per the native PiAgentComposerBox: a single radius-20
 * content surface with the text editor on top and a footer chip bar (agent,
 * model, thinking) ending in the prominent circular send/stop button.
 */
export function Composer() {
  const [draft, setDraft] = useState("");
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const connection = useAppStore((state) => state.connection);
  const session = useAppStore((state) => state.session);
  const currentAgentName = useAppStore((state) => state.currentAgentName);
  const agents = useAgents();
  const running = agentStatus === "running";
  const pickableAgents = agents.filter((agent) => !agent.shadowed);

  const [piState, setPiState] = useState<PiComposerState | null>(null);
  const [models, setModels] = useState<PiModelInfo[]>([]);

  const refreshPiState = useCallback(async (): Promise<void> => {
    if (!session) return;
    try {
      const response = await fetch(`/sessions/${encodeURIComponent(session.id)}/state`);
      if (!response.ok) return;
      const { state } = (await response.json()) as {
        state: { model?: { provider: string; id: string }; thinkingLevel: string };
      };
      setPiState({
        provider: state.model?.provider,
        modelId: state.model?.id,
        thinkingLevel: state.thinkingLevel,
      });
    } catch {
      // Session may be mid-restart; the next refresh wins.
    }
  }, [session?.id]);

  useEffect(() => {
    setPiState(null);
    setModels([]);
    if (!session) return;
    void refreshPiState();
    void fetch(`/sessions/${encodeURIComponent(session.id)}/models`)
      .then((response) => (response.ok ? response.json() : { models: [] }))
      .then((data: { models: Array<{ provider: string; id: string }> }) =>
        setModels(data.models.map((m) => ({ provider: m.provider, id: m.id }))),
      )
      .catch(() => {});
  }, [session?.id, refreshPiState]);

  const submit = (): void => {
    const message = draft.trim();
    if (!message || connection !== "open" || running) return;
    sendPrompt(message);
    setDraft("");
  };

  return (
    <div className="px-6 pb-5 pt-2">
      <div className="rounded-[20px] border border-border-subtle bg-surface-elevated shadow-card">
        <TextareaAutosize
          data-testid="composer-input"
          className="block w-full resize-none bg-transparent px-4 pb-1 pt-3.5 text-sm text-text-primary outline-none placeholder:text-text-muted"
          placeholder={running ? "pi is responding — Enter to queue…" : "Message pi"}
          minRows={2}
          maxRows={6}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              submit();
            }
          }}
        />
        <div className="flex items-center gap-2 px-3 pb-3 pt-1">
          <label className={chipClass()} title="Agent">
            <select
              data-testid="agent-picker"
              className="max-w-[18ch] cursor-pointer truncate bg-transparent text-xs font-medium outline-none"
              value={currentAgentName ?? ""}
              disabled={running}
              onChange={(event) => void switchToAgent(event.target.value || null)}
            >
              <option value="">Pi Agent</option>
              {pickableAgents.map((agent) => (
                <option key={agent.filePath} value={agent.name}>
                  {agent.name} ({agent.scope})
                </option>
              ))}
            </select>
          </label>
          <ModelChip
            state={piState}
            models={models}
            onSelect={(model) => {
              sendSetModel(model.provider, model.id);
              setPiState((prev) =>
                prev ? { ...prev, provider: model.provider, modelId: model.id } : prev,
              );
              setTimeout(() => void refreshPiState(), 300);
            }}
          />
          <ThinkingChip
            state={piState}
            onSelect={(level) => {
              sendSetThinking(level);
              setPiState((prev) => (prev ? { ...prev, thinkingLevel: level } : prev));
              setTimeout(() => void refreshPiState(), 300);
            }}
          />
          <div className="flex-1" />
          <SendStopButton
            running={running}
            disabled={!draft.trim() || connection !== "open"}
            onSend={submit}
            onStop={sendAbort}
          />
        </div>
      </div>
    </div>
  );
}
