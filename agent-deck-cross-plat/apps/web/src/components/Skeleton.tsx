/**
 * Loading skeletons: pulse placeholders shown while a list's FIRST fetch is in
 * flight, so the screen doesn't flash its empty state before data arrives. Used
 * on the resource-list screens in place of a bare spinner / "Loading…" text.
 */
export function SkeletonRows({ count = 4, className }: { count?: number; className?: string }) {
  return (
    <div className={`space-y-1.5 ${className ?? ""}`} data-testid="skeleton">
      {Array.from({ length: count }).map((_, index) => (
        <div
          key={index}
          className="h-12 animate-pulse rounded-[14px] border border-border-subtle bg-surface"
          style={{ opacity: 1 - index * 0.15 }}
          aria-hidden="true"
        />
      ))}
      <span className="sr-only">Loading…</span>
    </div>
  );
}
