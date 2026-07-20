import { AppWindow, Braces, Folder, GitBranch, type LucideIcon } from "lucide-react";
import type { ProjectType } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import { PROJECT_TYPE_ICONS } from "../assets/projectIcons.ts";

/**
 * A project's framework icon, reusing the native app's own project-type SF
 * Symbols marks (see scripts/generate-provider-logos.mjs). Types the native
 * catalog draws with a system symbol rather than a custom asset
 * (xcode/node/git/staticSite/unknown) fall back to a matching lucide glyph, so
 * every project renders something. Monochrome, themes with the text.
 */
const FALLBACK_ICON: Partial<Record<ProjectType, LucideIcon>> = {
  xcode: AppWindow,
  node: Braces,
  git: GitBranch,
  unknown: Folder,
};

export function ProjectTypeIcon({
  type,
  size = 15,
  className,
}: {
  type?: ProjectType;
  size?: number;
  className?: string;
}): React.ReactElement {
  const svg = type ? PROJECT_TYPE_ICONS[type] : undefined;
  if (svg) {
    return (
      <span
        data-testid={`project-type-icon-${type}`}
        data-icon={type}
        aria-hidden
        className={cn("inline-flex [&_svg]:block [&_svg]:h-full [&_svg]:w-full", className)}
        style={{ width: size, height: size }}
        dangerouslySetInnerHTML={{ __html: svg }}
      />
    );
  }
  const Fallback = (type && FALLBACK_ICON[type]) ?? Folder;
  return (
    <Fallback
      size={size}
      className={className}
      data-testid={`project-type-icon-${type ?? "unknown"}`}
      data-icon="fallback"
      aria-hidden
    />
  );
}
