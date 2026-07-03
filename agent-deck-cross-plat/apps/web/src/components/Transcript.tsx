import { useEffect, useRef } from "react";
import { useAppStore } from "../state/store.ts";
import { CellView } from "./cells.tsx";

export function Transcript() {
  const cells = useAppStore((state) => state.transcript.cells);
  const bottomRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const pinnedToBottom = useRef(true);

  useEffect(() => {
    if (pinnedToBottom.current) {
      bottomRef.current?.scrollIntoView({ block: "end" });
    }
  }, [cells]);

  return (
    <div
      ref={containerRef}
      data-testid="transcript"
      className="flex-1 space-y-4 overflow-y-auto px-6 py-4"
      onScroll={() => {
        const el = containerRef.current;
        if (!el) return;
        pinnedToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      }}
    >
      {cells.length === 0 ? (
        <div className="mt-16 text-center text-text-muted">Start a conversation with pi.</div>
      ) : (
        cells.map((cell) => <CellView key={cell.id} cell={cell} />)
      )}
      <div ref={bottomRef} />
    </div>
  );
}
