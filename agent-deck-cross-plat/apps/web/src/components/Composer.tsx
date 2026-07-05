import { useCallback, useEffect, useRef, useState } from "react";
import { Paperclip, X } from "lucide-react";
import TextareaAutosize from "react-textarea-autosize";
import { useAppStore } from "../state/store.ts";
import { useAgents } from "../state/useAgents.ts";
import {
  sendAbort,
  sendPrompt,
  sendSetModel,
  sendSetThinking,
  switchToAgent,
  type ImageAttachment,
} from "../state/wsBridge.ts";
import {
  ModelChip,
  SendStopButton,
  ThinkingChip,
  chipClass,
  type PiComposerState,
  type PiModelInfo,
} from "./composer/pickers.tsx";
import { SuggestionPanel } from "./composer/SuggestionPanel.tsx";
import { useSuggestions } from "./composer/useSuggestions.ts";

interface PendingImage extends ImageAttachment {
  id: string;
  name: string;
}

async function fileToImage(file: File): Promise<PendingImage | null> {
  if (!file.type.startsWith("image/")) return null;
  const buffer = await file.arrayBuffer();
  let binary = "";
  const bytes = new Uint8Array(buffer);
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]!);
  return {
    type: "image",
    data: btoa(binary),
    mimeType: file.type,
    id: `${file.name}-${bytes.length}`,
    name: file.name || "pasted image",
  };
}

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
  const pickableAgents = agents.filter((agent) => !agent.shadowed && !agent.disabled);

  const [piState, setPiState] = useState<PiComposerState | null>(null);
  const [models, setModels] = useState<PiModelInfo[]>([]);
  const sessionId = session?.id ?? null;
  // Guards against a stale session's response/timer clobbering the new one.
  const activeSessionRef = useRef<string | null>(null);
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const refreshPiState = useCallback(async (): Promise<void> => {
    if (!sessionId) return;
    try {
      const response = await fetch(`/sessions/${encodeURIComponent(sessionId)}/state`);
      if (!response.ok || activeSessionRef.current !== sessionId) return;
      const { state } = (await response.json()) as {
        state: { model?: { provider: string; id: string }; thinkingLevel: string };
      };
      if (activeSessionRef.current !== sessionId) return;
      setPiState({
        provider: state.model?.provider,
        modelId: state.model?.id,
        thinkingLevel: state.thinkingLevel,
      });
    } catch {
      // Session may be mid-restart; the next refresh wins.
    }
  }, [sessionId]);

  const scheduleRefresh = useCallback((): void => {
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    refreshTimerRef.current = setTimeout(() => void refreshPiState(), 300);
  }, [refreshPiState]);

  useEffect(() => {
    activeSessionRef.current = sessionId;
    setPiState(null);
    setModels([]);
    if (!sessionId) return;
    void refreshPiState();
    void fetch(`/sessions/${encodeURIComponent(sessionId)}/models`)
      .then((response) => (response.ok ? response.json() : { models: [] }))
      .then((data: { models: Array<{ provider: string; id: string }> }) => {
        if (activeSessionRef.current === sessionId) {
          setModels(data.models.map((m) => ({ provider: m.provider, id: m.id })));
        }
      })
      .catch(() => {});
    return () => {
      if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    };
  }, [sessionId, refreshPiState]);

  const suggestions = useSuggestions(sessionId);
  const [images, setImages] = useState<PendingImage[]>([]);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const applyAccept = (accepted: { value: string; caret: number }): void => {
    setDraft(accepted.value);
    // Restore the caret after React commits the new value.
    requestAnimationFrame(() => {
      const el = textareaRef.current;
      if (el) {
        el.selectionStart = accepted.caret;
        el.selectionEnd = accepted.caret;
      }
    });
  };

  const addFiles = useCallback(async (files: FileList | File[]): Promise<void> => {
    // Cap to the remaining slots *before* encoding so many/huge files can't
    // freeze the tab base64-encoding images that would be discarded anyway.
    const remaining = 8 - images.length;
    if (remaining <= 0) return;
    const candidates = [...files].filter((f) => f.type.startsWith("image/")).slice(0, remaining);
    const imgs = (await Promise.all(candidates.map(fileToImage))).filter(
      (i): i is PendingImage => i !== null,
    );
    if (imgs.length > 0) setImages((prev) => [...prev, ...imgs].slice(0, 8));
  }, [images.length]);

  const submit = (): void => {
    const message = draft.trim();
    if ((!message && images.length === 0) || connection !== "open" || running) return;
    sendPrompt(
      message,
      images.length > 0
        ? images.map(({ type, data, mimeType }) => ({ type, data, mimeType }))
        : undefined,
    );
    setDraft("");
    setImages([]);
    suggestions.close();
  };

  return (
    <div className="px-6 pb-5 pt-2">
      <div className="relative rounded-[20px] border border-border-subtle bg-surface-elevated shadow-card">
        {suggestions.mode ? (
          <SuggestionPanel
            items={suggestions.items}
            selectedIndex={suggestions.selectedIndex}
            onHover={suggestions.setSelectedIndex}
            onAccept={(item) => {
              const accepted = suggestions.accept(item);
              if (accepted) applyAccept(accepted);
              textareaRef.current?.focus();
            }}
            testid={suggestions.mode === "slash" ? "slash-panel" : "file-panel"}
          />
        ) : null}

        {images.length > 0 ? (
          <div className="flex flex-wrap gap-2 px-3 pt-3" data-testid="attachments">
            {images.map((image) => (
              <span
                key={image.id}
                data-testid={`attachment-${image.id}`}
                className="flex items-center gap-1.5 rounded-lg border border-border-strong bg-surface px-2 py-1 text-xs text-text-secondary"
              >
                <img
                  src={`data:${image.mimeType};base64,${image.data}`}
                  alt={image.name}
                  className="h-8 w-8 rounded object-cover"
                />
                <span className="max-w-[12ch] truncate">{image.name}</span>
                <button
                  className="text-text-muted hover:text-[var(--color-role-error)]"
                  aria-label="Remove attachment"
                  onClick={() => setImages((prev) => prev.filter((i) => i.id !== image.id))}
                >
                  <X size={12} />
                </button>
              </span>
            ))}
          </div>
        ) : null}

        <TextareaAutosize
          ref={textareaRef}
          data-testid="composer-input"
          className="block w-full resize-none bg-transparent px-4 pb-1 pt-3.5 text-sm text-text-primary outline-none placeholder:text-text-muted"
          placeholder={
            running ? "pi is responding — Enter to queue…" : "Message pi ( / commands, @ files )"
          }
          minRows={2}
          maxRows={6}
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value);
            suggestions.update(
              event.target.value,
              event.target.selectionStart ?? event.target.value.length,
            );
          }}
          onPaste={(event) => {
            const files = [...event.clipboardData.items]
              .map((item) => item.getAsFile())
              .filter((f): f is File => f !== null);
            if (files.some((f) => f.type.startsWith("image/"))) {
              event.preventDefault();
              void addFiles(files);
            }
          }}
          onKeyDown={(event) => {
            if (suggestions.handleKeyDown(event)) return;
            if ((event.key === "Enter" || event.key === "Tab") && suggestions.mode) {
              const item = suggestions.items[suggestions.selectedIndex];
              if (item) {
                event.preventDefault();
                const accepted = suggestions.accept(item);
                if (accepted) applyAccept(accepted);
                return;
              }
            }
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
              scheduleRefresh();
            }}
          />
          <ThinkingChip
            state={piState}
            onSelect={(level) => {
              sendSetThinking(level);
              setPiState((prev) => (prev ? { ...prev, thinkingLevel: level } : prev));
              scheduleRefresh();
            }}
          />
          <div className="flex-1" />
          <label
            className="flex h-8 w-8 cursor-pointer items-center justify-center rounded-full text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Attach image"
            data-testid="attach-button"
          >
            <Paperclip size={15} />
            <input
              type="file"
              accept="image/*"
              multiple
              className="hidden"
              data-testid="attach-input"
              onChange={(event) => {
                if (event.target.files) void addFiles(event.target.files);
                event.target.value = "";
              }}
            />
          </label>
          <SendStopButton
            running={running}
            disabled={(!draft.trim() && images.length === 0) || connection !== "open"}
            onSend={submit}
            onStop={sendAbort}
          />
        </div>
      </div>
    </div>
  );
}
