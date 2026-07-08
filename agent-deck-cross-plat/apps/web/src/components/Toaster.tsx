import { useEffect } from "react";
import { CheckCircle2, Info, X, XCircle } from "lucide-react";
import { useAppStore, type Toast, type ToastKind } from "../state/store.ts";

/**
 * Transient notifications (native toasts): a store-driven queue rendered in a
 * corner stack, each auto-dismissed after a few seconds. Complements the
 * persistent error banner for at-a-glance action feedback ("Committed", …).
 */
const TOAST_TTL_MS = 3500;

const KIND_ICON: Record<ToastKind, typeof Info> = {
  success: CheckCircle2,
  error: XCircle,
  info: Info,
};

const KIND_COLOR: Record<ToastKind, string> = {
  success: "var(--color-success)",
  error: "var(--color-role-error)",
  info: "var(--color-brand-accent)",
};

function ToastItem({ toast }: { toast: Toast }) {
  const dismiss = useAppStore((state) => state.dismissToast);
  useEffect(() => {
    const timer = setTimeout(() => dismiss(toast.id), TOAST_TTL_MS);
    return () => clearTimeout(timer);
  }, [toast.id, dismiss]);
  const Icon = KIND_ICON[toast.kind];
  return (
    <div
      data-testid="toast"
      data-kind={toast.kind}
      role="status"
      className="flex items-center gap-2 rounded-xl border bg-surface-elevated px-3 py-2 text-sm text-text-primary shadow-elevated"
      style={{ borderColor: KIND_COLOR[toast.kind] }}
    >
      <Icon size={15} style={{ color: KIND_COLOR[toast.kind] }} className="shrink-0" />
      <span className="min-w-0 flex-1">{toast.message}</span>
      <button
        aria-label="Dismiss"
        className="shrink-0 rounded p-0.5 text-text-muted hover:text-text-primary"
        onClick={() => dismiss(toast.id)}
      >
        <X size={13} />
      </button>
    </div>
  );
}

export function Toaster() {
  const toasts = useAppStore((state) => state.toasts);
  if (toasts.length === 0) return null;
  return (
    <div
      className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-[min(20rem,90vw)] flex-col gap-2"
      data-testid="toaster"
    >
      {toasts.map((toast) => (
        <div key={toast.id} className="pointer-events-auto">
          <ToastItem toast={toast} />
        </div>
      ))}
    </div>
  );
}
