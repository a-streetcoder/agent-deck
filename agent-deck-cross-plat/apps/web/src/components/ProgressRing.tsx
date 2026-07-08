/**
 * An animated SVG progress ring (native PiAgentActivityPanelViews): a track +
 * an accent arc whose stroke-dashoffset animates as done/total changes. Used in
 * the deck/plan panel header. Honors prefers-reduced-motion (no transition).
 */
export function ProgressRing({
  done,
  total,
  size = 30,
  stroke = 3,
}: {
  done: number;
  total: number;
  size?: number;
  stroke?: number;
}) {
  const fraction = total > 0 ? Math.min(1, Math.max(0, done / total)) : 0;
  // floor, not round — so data-progress only reads 100 when actually complete.
  const pct = Math.floor(fraction * 100);
  const radius = Math.max(1, (size - stroke) / 2);
  const circumference = 2 * Math.PI * radius;
  const dashoffset = circumference * (1 - fraction);
  const center = size / 2;

  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      data-testid="progress-ring"
      data-progress={pct}
      role="img"
      aria-label={`${done} of ${total} done`}
    >
      <circle
        cx={center}
        cy={center}
        r={radius}
        fill="none"
        stroke="var(--color-border-strong)"
        strokeWidth={stroke}
      />
      <circle
        cx={center}
        cy={center}
        r={radius}
        fill="none"
        stroke="var(--color-accent)"
        strokeWidth={stroke}
        strokeLinecap="round"
        strokeDasharray={circumference}
        strokeDashoffset={dashoffset}
        transform={`rotate(-90 ${center} ${center})`}
        className="motion-reduce:transition-none"
        style={{ transition: "stroke-dashoffset 500ms cubic-bezier(0.3, 1, 0.4, 1)" }}
      />
      <text
        x={center}
        y={center}
        textAnchor="middle"
        dominantBaseline="central"
        className="fill-text-secondary tabular-nums"
        style={{ fontSize: size * 0.3 }}
      >
        {done}
      </text>
    </svg>
  );
}
