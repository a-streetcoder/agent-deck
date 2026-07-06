import { useEffect, useRef } from "react";
import { useAppStore } from "../state/store.ts";
import { CellView } from "./cells.tsx";
import { SessionPlanPanel } from "./SessionPlanPanel.tsx";
import { SessionStartupCard } from "./SessionStartupCard.tsx";

export function Transcript() {
  const cells = useAppStore((state) => state.transcript.cells);
  const session = useAppStore((state) => state.session);
  // Only a genuinely new session shows the startup card. An existing session
  // already has a piSessionFile (set on switch, before its history streams in),
  // so it never flashes the card during the brief empty-transcript load gap.
  const isNewSession = cells.length === 0 && !session?.piSessionFile;
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
      <SessionPlanPanel />
      {cells.length === 0 ? (
        isNewSession ? (
          <SessionStartupCard />
        ) : null
      ) : (
        cells.map((cell) => <CellView key={cell.id} cell={cell} />)
      )}
      <div ref={bottomRef} />
    </div>
  );
}
