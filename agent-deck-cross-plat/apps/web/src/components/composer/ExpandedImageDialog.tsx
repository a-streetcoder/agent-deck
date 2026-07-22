import { useCallback, useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, X } from "lucide-react";
import type { ExpandedImagePreview } from "../../lib/expandedImage.ts";

/**
 * Slice 17 — full-size overlay for a pending composer image. Click the backdrop
 * or press Escape to close; ←/→ navigate when more than one image is pending.
 * Ported from the donor ExpandedImageDialog, restyled onto our tokens and lucide
 * icons (no shadcn Button dependency).
 */
export function ExpandedImageDialog({
  preview,
  onClose,
}: {
  preview: ExpandedImagePreview;
  onClose: () => void;
}) {
  const [offset, setOffset] = useState(0);
  const count = preview.images.length;
  const index = (((preview.index + offset) % count) + count) % count;

  const navigate = useCallback((direction: -1 | 1) => {
    setOffset((current) => current + direction);
  }, []);

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent): void => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        onClose();
        return;
      }
      if (count <= 1) return;
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        navigate(-1);
      } else if (event.key === "ArrowRight") {
        event.preventDefault();
        navigate(1);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [count, navigate, onClose]);

  const item = preview.images[index];
  if (!item) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-label="Expanded image preview"
      data-testid="expanded-image-dialog"
    >
      <button
        type="button"
        className="absolute inset-0 z-0 cursor-zoom-out"
        aria-label="Close image preview"
        data-testid="expanded-image-backdrop"
        onClick={onClose}
      />
      {count > 1 ? (
        <button
          type="button"
          className="absolute left-2 top-1/2 z-20 flex h-9 w-9 -translate-y-1/2 items-center justify-center rounded-full text-white/90 hover:bg-white/10 sm:left-6"
          aria-label="Previous image"
          onClick={() => navigate(-1)}
        >
          <ChevronLeft size={20} />
        </button>
      ) : null}
      <div className="relative isolate z-10 max-h-[92vh] max-w-[92vw]">
        <button
          type="button"
          className="absolute right-2 top-2 flex h-7 w-7 items-center justify-center rounded-full bg-black/40 text-white/90 hover:bg-black/60"
          onClick={onClose}
          aria-label="Close image preview"
          data-testid="expanded-image-close"
        >
          <X size={15} />
        </button>
        <img
          src={item.src}
          alt={item.name}
          className="max-h-[86vh] max-w-[92vw] select-none rounded-lg border border-border-strong bg-surface object-contain shadow-card"
          draggable={false}
        />
        <p className="mt-2 max-w-[92vw] truncate text-center text-xs text-white/80">
          {item.name}
          {count > 1 ? ` (${index + 1}/${count})` : ""}
        </p>
      </div>
      {count > 1 ? (
        <button
          type="button"
          className="absolute right-2 top-1/2 z-20 flex h-9 w-9 -translate-y-1/2 items-center justify-center rounded-full text-white/90 hover:bg-white/10 sm:right-6"
          aria-label="Next image"
          onClick={() => navigate(1)}
        >
          <ChevronRight size={20} />
        </button>
      ) : null}
    </div>
  );
}
