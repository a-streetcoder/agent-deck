import { useCallback, useEffect, useRef, useState } from "react";
import { CheckCircle2, ExternalLink, Loader2, XCircle } from "lucide-react";
import { useAppStore } from "../state/store.ts";

/**
 * Interactive provider OAuth login (native PiProviderLoginService). Starts a
 * login session on the server and polls it, rendering each relayed step — an
 * auth URL / device code to open, a text prompt or a choice to answer, progress
 * lines — until it finishes. Threads prompt/select answers back to the server.
 */
type LoginEvent =
  | { type: "auth_url"; url: string; instructions?: string }
  | { type: "device_code"; userCode: string; verificationUri: string; expiresInSeconds?: number }
  | { type: "prompt"; message: string; placeholder?: string }
  | { type: "select"; message: string; options: Array<{ id: string; label: string }> }
  | { type: "progress"; message: string }
  | { type: "done"; ok: boolean; error?: string };

type LoginStatus = "running" | "done" | "error";

const inputClass =
  "w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent";

export function ProviderLoginSheet({
  provider,
  onClose,
  onDone,
}: {
  provider: { id: string; name: string };
  onClose: () => void;
  onDone: () => void;
}) {
  const pushToast = useAppStore((state) => state.pushToast);
  const [events, setEvents] = useState<LoginEvent[]>([]);
  const [status, setStatus] = useState<LoginStatus>("running");
  const [promptValue, setPromptValue] = useState("");
  const [fatal, setFatal] = useState<string | null>(null);
  const loginIdRef = useRef<string | null>(null);
  const cursorRef = useRef(0);
  const notifiedRef = useRef(false);

  const poll = useCallback(async (): Promise<void> => {
    const loginId = loginIdRef.current;
    if (!loginId) return;
    const response = await fetch(`/runtime/providers/login/${loginId}?since=${cursorRef.current}`);
    if (!response.ok) return;
    const data = (await response.json()) as {
      events: LoginEvent[];
      status: LoginStatus;
      nextCursor: number;
    };
    cursorRef.current = data.nextCursor;
    if (data.events.length > 0) {
      setEvents((prev) => [...prev, ...data.events]);
      setPromptValue("");
    }
    setStatus(data.status);
  }, []);

  // Start the login on mount; cancel it if the sheet closes before it finishes.
  useEffect(() => {
    let closed = false;
    void (async () => {
      try {
        const response = await fetch(
          `/runtime/providers/${encodeURIComponent(provider.id)}/login`,
          {
            method: "POST",
          },
        );
        if (!response.ok) throw new Error(await response.text());
        const { loginId } = (await response.json()) as { loginId: string };
        if (closed) {
          void fetch(`/runtime/providers/login/${loginId}/cancel`, { method: "POST" });
          return;
        }
        loginIdRef.current = loginId;
        void poll();
      } catch (err) {
        setFatal(String(err));
        setStatus("error");
      }
    })();
    return () => {
      closed = true;
      const loginId = loginIdRef.current;
      if (loginId) void fetch(`/runtime/providers/login/${loginId}/cancel`, { method: "POST" });
    };
  }, [provider.id, poll]);

  // Poll while the flow is running.
  useEffect(() => {
    if (status !== "running") return;
    const timer = setInterval(() => void poll(), 1000);
    return () => clearInterval(timer);
  }, [status, poll]);

  // On success (once), toast + let the parent refresh its list. The sheet stays
  // open showing "Signed in" until the user closes it.
  useEffect(() => {
    const last = events.at(-1);
    if (last?.type === "done" && last.ok && !notifiedRef.current) {
      notifiedRef.current = true;
      pushToast({ kind: "success", message: `Signed in to ${provider.name}` });
      onDone();
    }
  }, [events, provider.name, pushToast, onDone]);

  const respond = async (value: string): Promise<void> => {
    const loginId = loginIdRef.current;
    if (!loginId) return;
    await fetch(`/runtime/providers/login/${loginId}/respond`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ value }),
    }).catch(() => {});
    void poll();
  };

  const last = events.at(-1);
  const awaitingPrompt = status === "running" && last?.type === "prompt" ? last : null;
  const awaitingSelect = status === "running" && last?.type === "select" ? last : null;
  const doneEvent = last?.type === "done" ? last : null;

  return (
    <div
      className="fixed inset-0 z-40 flex items-center justify-center bg-black/40 p-8"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        className="flex max-h-[85vh] w-[460px] flex-col gap-3 overflow-y-auto rounded-2xl border border-border-strong bg-surface-elevated p-4 shadow-elevated"
        data-testid="provider-login-sheet"
        role="dialog"
        aria-modal="true"
      >
        <div
          className="text-sm font-semibold text-text-primary"
          style={{ fontStretch: "expanded" }}
        >
          Sign in to {provider.name}
        </div>

        <div className="flex flex-col gap-2" data-testid="login-events">
          {events.map((event, index) => (
            <LoginStep key={index} event={event} />
          ))}
          {fatal ? (
            <div className="text-sm" style={{ color: "var(--color-role-error)" }}>
              {fatal}
            </div>
          ) : null}
          {status === "running" && !awaitingPrompt && !awaitingSelect ? (
            <div className="flex items-center gap-2 text-xs text-text-muted">
              <Loader2 size={13} className="animate-spin" /> Waiting for the provider…
            </div>
          ) : null}
        </div>

        {awaitingPrompt ? (
          <form
            className="flex gap-2"
            onSubmit={(event) => {
              event.preventDefault();
              void respond(promptValue);
            }}
          >
            <input
              autoFocus
              data-testid="login-prompt-input"
              className={inputClass}
              placeholder={awaitingPrompt.placeholder}
              value={promptValue}
              onChange={(event) => setPromptValue(event.target.value)}
            />
            <button
              type="submit"
              data-testid="login-prompt-submit"
              className="rounded-capsule px-3 py-1.5 text-sm font-medium shadow-capsule"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
            >
              Submit
            </button>
          </form>
        ) : null}

        {awaitingSelect ? (
          <div className="flex flex-wrap gap-2" data-testid="login-select">
            {awaitingSelect.options.map((option) => (
              <button
                key={option.id}
                data-testid={`login-select-${option.id}`}
                className="rounded-capsule border border-border-strong px-3 py-1.5 text-sm text-text-primary hover:border-accent"
                onClick={() => void respond(option.id)}
              >
                {option.label}
              </button>
            ))}
          </div>
        ) : null}

        <div className="flex justify-end gap-2 pt-1">
          <button
            className="rounded-capsule border border-border-strong px-4 py-1.5 text-sm text-text-secondary hover:text-text-primary"
            onClick={onClose}
          >
            {doneEvent ? "Close" : "Cancel"}
          </button>
        </div>
      </div>
    </div>
  );
}

function LoginStep({ event }: { event: LoginEvent }) {
  switch (event.type) {
    case "auth_url":
      return (
        <div className="rounded-lg border border-border-subtle bg-surface px-3 py-2 text-sm">
          <div className="text-text-muted">Open this URL to authorize:</div>
          <a
            href={event.url}
            target="_blank"
            rel="noreferrer"
            className="flex items-center gap-1 break-all font-mono text-[12px] text-[var(--color-brand-accent)]"
            data-testid="login-auth-url"
          >
            <ExternalLink size={12} className="shrink-0" /> {event.url}
          </a>
          {event.instructions ? (
            <div className="mt-1 text-xs text-text-muted">{event.instructions}</div>
          ) : null}
        </div>
      );
    case "device_code":
      return (
        <div className="rounded-lg border border-border-subtle bg-surface px-3 py-2 text-sm">
          <div className="text-text-muted">
            Go to{" "}
            <a
              href={event.verificationUri}
              target="_blank"
              rel="noreferrer"
              className="text-[var(--color-brand-accent)]"
            >
              {event.verificationUri}
            </a>{" "}
            and enter:
          </div>
          <div
            className="mt-1 font-mono text-lg tracking-widest text-text-primary"
            data-testid="login-device-code"
          >
            {event.userCode}
          </div>
        </div>
      );
    case "progress":
      return <div className="text-xs text-text-muted">{event.message}</div>;
    case "prompt":
      return <div className="text-sm text-text-primary">{event.message}</div>;
    case "select":
      return <div className="text-sm text-text-primary">{event.message}</div>;
    case "done":
      return event.ok ? (
        <div
          className="flex items-center gap-2 text-sm"
          style={{ color: "var(--color-success)" }}
          data-testid="login-done"
        >
          <CheckCircle2 size={15} /> Signed in.
        </div>
      ) : (
        <div
          className="flex items-center gap-2 text-sm"
          style={{ color: "var(--color-role-error)" }}
          data-testid="login-done"
        >
          <XCircle size={15} /> {event.error ?? "Login failed."}
        </div>
      );
  }
}
