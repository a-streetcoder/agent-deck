import { useCallback, useEffect, useRef, useState } from "react";
import { Paperclip, Shrink, X } from "lucide-react";
import TextareaAutosize from "react-textarea-autosize";
import { thinkingLevelsForModel } from "@agent-deck/domain";
import { useAppStore } from "../state/store.ts";
import { useAgents } from "../state/useAgents.ts";
import {
  sendAbort,
  sendCompact,
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
import { ComposerPendingReviewComments } from "./composer/ComposerPendingReviewComments.tsx";
import { appendReviewCommentsToPrompt, type PendingReviewComment } from "../lib/reviewComments.ts";
import { ComposerPendingElementContexts } from "./composer/ComposerPendingElementContexts.tsx";
import {
  appendElementContextsToPrompt,
  type PendingElementContext,
} from "../lib/elementContext.ts";

interface PendingImage extends ImageAttachment {
  id: string;
  name: string;
}

/** Stable empty reference so the pending-comments selector never returns a
 * fresh array (which would re-render the composer every store change). */
const EMPTY_COMMENTS: readonly PendingReviewComment[] = [];
/** Stable empty reference for the pending element-context selector (Slice 16). */
const EMPTY_ELEMENT_CONTEXTS: readonly PendingElementContext[] = [];

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

/** Native `PiAgentRuntimeFooter.compact`: 1_234 → "1k", 2_500_000 → "2.5M". */
function compactTokens(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${Math.floor(value / 1_000)}k`;
  return `${value}`;
}

/**
 * The composer, styled per the native PiAgentComposerBox: a single radius-20
 * content surface with the text editor on top and a footer chip bar (agent,
 * model, thinking) ending in the prominent circular send/stop button.
 */
export function Composer() {
  const [draft, setDraft] = useState("");
  const pendingComposerText = useAppStore((state) => state.pendingComposerText);
  const setPendingComposerText = useAppStore((state) => state.setPendingComposerText);
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const contextRevision = useAppStore((state) => state.transcript.contextRevision);
  const connection = useAppStore((state) => state.connection);
  const session = useAppStore((state) => state.session);
  const currentAgentName = useAppStore((state) => state.currentAgentName);
  // Pending review comments (Slice 12) for the CURRENT session: captured on
  // diff rows, shown as cards above the editor, serialized into the next send.
  const sessionIdForComments = session?.id ?? null;
  const pendingComments = useAppStore((state) =>
    sessionIdForComments
      ? (state.pendingReviewComments[sessionIdForComments] ?? EMPTY_COMMENTS)
      : EMPTY_COMMENTS,
  );
  const removeReviewComment = useAppStore((state) => state.removeReviewComment);
  const clearReviewComments = useAppStore((state) => state.clearReviewComments);
  const requestDiffJump = useAppStore((state) => state.requestDiffJump);
  const setDiffPanelOpen = useAppStore((state) => state.setDiffPanelOpen);
  // Pending preview element contexts (Slice 16) for the CURRENT session:
  // captured in the preview panel, shown as cards, serialized into the next send.
  const pendingElementContexts = useAppStore((state) =>
    sessionIdForComments
      ? (state.pendingElementContexts[sessionIdForComments] ?? EMPTY_ELEMENT_CONTEXTS)
      : EMPTY_ELEMENT_CONTEXTS,
  );
  const removeElementContext = useAppStore((state) => state.removeElementContext);
  const clearElementContexts = useAppStore((state) => state.clearElementContexts);
  const agents = useAgents();
  const running = agentStatus === "running";
  const pickableAgents = agents.filter((agent) => !agent.shadowed && !agent.disabled);

  const [piState, setPiState] = useState<PiComposerState | null>(null);
  const [models, setModels] = useState<PiModelInfo[]>([]);
  // Live context-window usage (native session context-usage indicator). null
  // until the first LLM response establishes a token estimate.
  const [contextUsage, setContextUsage] = useState<{
    tokens: number | null;
    contextWindow: number;
    percent: number | null;
  } | null>(null);
  // Cumulative session token + cost totals (native composer footer: "{n} tokens"
  // and "$x.xx"). null until the first turn establishes a count; cost is null
  // when the provider reports no pricing (free/custom providers price at 0).
  const [sessionTotals, setSessionTotals] = useState<{
    tokens: number;
    cost: number | null;
  } | null>(null);
  // True while a manual compaction is in flight, so the button can't double-fire.
  // Reset on the compaction's contextRevision bump (success) or a safety timeout.
  const [compacting, setCompacting] = useState(false);
  const sessionId = session?.id ?? null;
  // Guards against a stale session's response/timer clobbering the new one.
  const activeSessionRef = useRef<string | null>(null);
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Latest-wins token for the two stats refresh triggers (idle + compaction).
  const statsSeqRef = useRef(0);
  // Previous values so stats refresh only on genuine transitions (a turn
  // completing / a compaction), never on the fresh/initial session state.
  const prevAgentStatusRef = useRef<"idle" | "running" | null>(null);
  /** Blocks a same-frame double-submit (see submit(); reset on the next tick). */
  const sendLockRef = useRef(false);
  const prevContextRevisionRef = useRef(0);

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

  const refreshStats = useCallback(async (): Promise<void> => {
    if (!sessionId) return;
    // Monotonic token: two triggers (idle + contextRevision) fire near a turn
    // boundary, so an older in-flight /stats response must not overwrite a newer
    // one — only the latest request's result is applied.
    const seq = ++statsSeqRef.current;
    try {
      const response = await fetch(`/sessions/${encodeURIComponent(sessionId)}/stats`);
      if (!response.ok || activeSessionRef.current !== sessionId) return;
      const { stats } = (await response.json()) as {
        stats: {
          contextUsage?: { tokens: number | null; contextWindow: number; percent: number | null };
          tokens?: { total?: number };
          cost?: number;
        };
      };
      if (activeSessionRef.current !== sessionId || seq !== statsSeqRef.current) return;
      setContextUsage(stats.contextUsage ?? null);
      // Native hides the token metric until a real count exists (totalTokens !=
      // nil); pi reports 0 pre-turn, so gate on > 0. Cost mirrors native's
      // `if let cost` nil-guard exactly: pi's SessionStats.cost is a non-optional
      // number, so it shows whenever present — a free/custom provider reports 0,
      // which native surfaces as "$0.00" (only a truly absent cost → null).
      const total = stats.tokens?.total;
      setSessionTotals(
        typeof total === "number" && total > 0
          ? {
              tokens: total,
              cost: typeof stats.cost === "number" ? stats.cost : null,
            }
          : null,
      );
    } catch {
      // Session may be mid-restart; the next refresh wins.
    }
  }, [sessionId]);

  useEffect(() => {
    activeSessionRef.current = sessionId;
    setPiState(null);
    setModels([]);
    setContextUsage(null);
    setSessionTotals(null);
    prevAgentStatusRef.current = null;
    if (!sessionId) return;
    void refreshPiState();
    void fetch(`/sessions/${encodeURIComponent(sessionId)}/models`)
      .then((response) => (response.ok ? response.json() : { models: [] }))
      .then((data: { models: Array<{ provider: string; id: string; reasoning?: boolean }> }) => {
        if (activeSessionRef.current === sessionId) {
          setModels(
            data.models.map((m) => ({
              provider: m.provider,
              id: m.id,
              reasoning: m.reasoning,
            })),
          );
        }
      })
      .catch(() => {});
    return () => {
      if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    };
  }, [sessionId, refreshPiState]);

  // Re-read the context fill ONLY on the two events that change it: a completed
  // TURN (a genuine running→idle transition) and a COMPACTION (contextRevision
  // actually increases — pi runs threshold auto-compaction AFTER agent_end, which
  // the ingest surfaces from the runtime `compaction_end` event). Gating on the
  // transition (not the bare idle/mount state) is deliberate: calling
  // get_session_stats on a FRESH, pre-first-turn session (e.g. just after picking
  // an agent) serialises ahead of the user's prompt in pi's RPC pipeline and can
  // stall the turn — so we never touch stats until a turn has actually run.
  useEffect(() => {
    const prev = prevAgentStatusRef.current;
    prevAgentStatusRef.current = agentStatus;
    if (prev === "running" && agentStatus === "idle" && sessionId) void refreshStats();
  }, [agentStatus, sessionId, refreshStats]);
  useEffect(() => {
    const prev = prevContextRevisionRef.current;
    prevContextRevisionRef.current = contextRevision;
    if (contextRevision > prev && sessionId) {
      void refreshStats();
      setCompacting(false); // a compaction (manual or threshold) landed → re-enable
    }
  }, [contextRevision, sessionId, refreshStats]);

  const suggestions = useSuggestions(sessionId);
  // The current model gates the thinking ladder: a non-reasoning model offers
  // only "off" (native supportsThinking fallback). reasoning comes from the
  // already-fetched models catalog; unknown → full ladder (no flash).
  const currentModel = models.find(
    (m) => m.provider === piState?.provider && m.id === piState?.modelId,
  );
  const thinkingLevels = thinkingLevelsForModel(currentModel?.reasoning);
  const [images, setImages] = useState<PendingImage[]>([]);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Seed the composer from elsewhere (e.g. an issue) — replaces the draft,
  // since seeding is a deliberate "start on this" action, not an append.
  useEffect(() => {
    if (pendingComposerText === null) return;
    setDraft(pendingComposerText);
    setPendingComposerText(null);
    requestAnimationFrame(() => textareaRef.current?.focus());
  }, [pendingComposerText, setPendingComposerText]);

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

  const addFiles = useCallback(
    async (files: FileList | File[]): Promise<void> => {
      // Cap to the remaining slots *before* encoding so many/huge files can't
      // freeze the tab base64-encoding images that would be discarded anyway.
      const remaining = 8 - images.length;
      if (remaining <= 0) return;
      const candidates = [...files].filter((f) => f.type.startsWith("image/")).slice(0, remaining);
      const imgs = (await Promise.all(candidates.map(fileToImage))).filter(
        (i): i is PendingImage => i !== null,
      );
      if (imgs.length > 0) setImages((prev) => [...prev, ...imgs].slice(0, 8));
    },
    [images.length],
  );

  const submit = (): void => {
    // Same-frame re-entry guard: `running` only disables the send control after
    // an async WS echo, so two click events dispatched in one frame (fast
    // double-click, or Enter+click) both pass the `running` check against the
    // same render-scope closures and send TWICE — duplicating the turn AND its
    // serialized review comments (which the first call clears but the second
    // still sees pre-re-render). The synchronous ref blocks the second; a
    // microtask reset reopens it next tick (legitimate rapid sends still work).
    if (sendLockRef.current) return;
    const message = draft.trim();
    // A send is valid with just pending review comments or element contexts (a
    // context-only turn), matching the donor's append-and-send when the composer
    // text is empty.
    if (
      (!message &&
        images.length === 0 &&
        pendingComments.length === 0 &&
        pendingElementContexts.length === 0) ||
      connection !== "open" ||
      running
    )
      return;
    sendLockRef.current = true;
    queueMicrotask(() => {
      sendLockRef.current = false;
    });
    // Attach the pending review comments (Slice 12) then the pending element
    // contexts (Slice 16) as the donor serializes each — a <review_comment>
    // block per comment, an <element_context> block for the contexts — and clear
    // both sets. They ride this single prompt turn to pi, not a new server op.
    const outgoing = appendElementContextsToPrompt(
      appendReviewCommentsToPrompt(message, pendingComments),
      pendingElementContexts,
    );
    sendPrompt(
      outgoing,
      images.length > 0
        ? images.map(({ type, data, mimeType }) => ({ type, data, mimeType }))
        : undefined,
    );
    if (pendingComments.length > 0 && sessionIdForComments) {
      clearReviewComments(sessionIdForComments);
    }
    if (pendingElementContexts.length > 0 && sessionIdForComments) {
      clearElementContexts(sessionIdForComments);
    }
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

        <ComposerPendingReviewComments
          comments={pendingComments}
          onRemove={(commentId) => {
            if (sessionIdForComments) removeReviewComment(sessionIdForComments, commentId);
          }}
          onJump={(comment) => {
            setDiffPanelOpen(true);
            requestDiffJump({ path: comment.filePath, side: comment.side, line: comment.line });
          }}
        />

        <ComposerPendingElementContexts
          contexts={pendingElementContexts}
          onRemove={(contextId) => {
            if (sessionIdForComments) removeElementContext(sessionIdForComments, contextId);
          }}
        />

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
        {/* flex-wrap: with the Slice-10 diff panel open the chat column can
            drop under this row's intrinsic width — the chips wrap instead of
            sliding (unclickably) beneath the panel. */}
        <div className="flex flex-wrap items-center gap-2 px-3 pb-3 pt-1">
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
            levels={thinkingLevels}
            onSelect={(level) => {
              sendSetThinking(level);
              setPiState((prev) => (prev ? { ...prev, thinkingLevel: level } : prev));
              scheduleRefresh();
            }}
          />
          {/* Context-window usage (native session context-usage indicator). Only
              shown once pi has a token estimate (after the first response). */}
          {contextUsage && contextUsage.percent != null ? (
            <span
              data-testid="context-usage"
              className={chipClass()}
              title={
                contextUsage.tokens != null
                  ? `${contextUsage.tokens.toLocaleString()} / ${contextUsage.contextWindow.toLocaleString()} context tokens`
                  : `context window ${contextUsage.contextWindow.toLocaleString()} tokens`
              }
            >
              {Math.round(contextUsage.percent)}% ctx
            </span>
          ) : null}
          {/* Cumulative session token + cost totals (native footer metrics).
              Shown once a turn has reported tokens; cost only when priced. */}
          {sessionTotals ? (
            <span
              data-testid="session-tokens"
              className={chipClass()}
              title={`${sessionTotals.tokens.toLocaleString()} tokens this session`}
            >
              {compactTokens(sessionTotals.tokens)} tokens
            </span>
          ) : null}
          {sessionTotals && sessionTotals.cost != null ? (
            <span
              data-testid="session-cost"
              className={chipClass()}
              title={`$${sessionTotals.cost.toFixed(4)} this session`}
            >
              ${sessionTotals.cost.toFixed(2)}
            </span>
          ) : null}
          {/* Manual "Compact context" (native PiAgentComposerViews.swift:1464):
              pi summarizes older history to free context. Shown alongside the
              context chip (after a turn); disabled mid-stream. */}
          {contextUsage ? (
            <button
              type="button"
              data-testid="compact-button"
              className="flex h-7 w-7 items-center justify-center rounded-full text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary disabled:opacity-40"
              title="Compact context — Pi summarizes older history to free up context"
              disabled={running || compacting}
              onClick={() => {
                if (
                  window.confirm(
                    "Compact context? Pi will summarize older conversation history to free up context.",
                  )
                ) {
                  setCompacting(true);
                  sendCompact();
                  // Safety re-enable if no contextRevision bump arrives (e.g. pi
                  // rejects "nothing to compact") — the success path resets sooner.
                  window.setTimeout(() => setCompacting(false), 15_000);
                }
              }}
            >
              <Shrink size={13} />
            </button>
          ) : null}
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
            disabled={
              (!draft.trim() &&
                images.length === 0 &&
                pendingComments.length === 0 &&
                pendingElementContexts.length === 0) ||
              connection !== "open"
            }
            onSend={submit}
            onStop={sendAbort}
          />
        </div>
      </div>
    </div>
  );
}
