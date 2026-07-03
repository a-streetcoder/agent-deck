import { useState } from "react";
import { useAppStore } from "../state/store.ts";
import { sendAbort, sendPrompt } from "../state/wsBridge.ts";

export function Composer() {
  const [draft, setDraft] = useState("");
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const connection = useAppStore((state) => state.connection);
  const running = agentStatus === "running";

  const submit = (): void => {
    const message = draft.trim();
    if (!message || connection !== "open") return;
    sendPrompt(message);
    setDraft("");
  };

  return (
    <div className="border-t border-border-subtle bg-surface-elevated px-6 py-4">
      <div className="flex items-end gap-3">
        <textarea
          data-testid="composer-input"
          className="min-h-[44px] flex-1 resize-none rounded-md border border-border-strong bg-surface px-3 py-2.5 text-text-primary outline-none focus:border-accent"
          placeholder={running ? "pi is responding…" : "Message pi"}
          value={draft}
          rows={1}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              submit();
            }
          }}
        />
        {running ? (
          <button
            data-testid="abort-button"
            className="rounded-md px-4 py-2.5 font-medium text-white"
            style={{ background: "var(--color-role-error)" }}
            onClick={sendAbort}
          >
            Stop
          </button>
        ) : (
          <button
            data-testid="send-button"
            className="rounded-md bg-primary px-4 py-2.5 font-medium disabled:opacity-40"
            style={{ color: "var(--color-accent-foreground)" }}
            disabled={!draft.trim() || connection !== "open"}
            onClick={submit}
          >
            Send
          </button>
        )}
      </div>
    </div>
  );
}
