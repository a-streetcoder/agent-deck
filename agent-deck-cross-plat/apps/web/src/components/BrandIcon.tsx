import { cn } from "@/lib/cn";
import { BRAND_ICONS, type BrandIconName } from "../assets/brandIcons.ts";

/**
 * A brand/misc mark from the native macOS app's own SF Symbols assets (the pi
 * logo, paperplane, git symbols — see scripts/generate-provider-logos.mjs).
 * Monochrome, themes with the surrounding text (fill=currentColor). Sized via
 * CSS; the inlined SVG is a static committed build asset (never user data).
 */
export function BrandIcon({
  name,
  size = 16,
  className,
}: {
  name: BrandIconName;
  size?: number;
  className?: string;
}): React.ReactElement {
  return (
    <span
      data-testid={`brand-icon-${name}`}
      aria-hidden
      className={cn("inline-flex [&_svg]:block [&_svg]:h-full [&_svg]:w-full", className)}
      style={{ width: size, height: size }}
      dangerouslySetInnerHTML={{ __html: BRAND_ICONS[name] }}
    />
  );
}
