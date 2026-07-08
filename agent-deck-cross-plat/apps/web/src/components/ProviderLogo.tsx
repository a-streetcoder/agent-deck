import { cn } from "@/lib/cn";
import { PROVIDER_LOGO_KEY, PROVIDER_LOGOS } from "../assets/providerLogos.ts";

/**
 * A provider's brand logo, reusing the native macOS app's own SF Symbols
 * provider marks (extracted to monochrome SVGs — see
 * scripts/generate-provider-logos.mjs). Themes with the surrounding text
 * (fill=currentColor). Falls back to a monogram tile when a provider has no
 * bundled logo, so every provider still renders something recognizable.
 */
export function ProviderLogo({
  providerId,
  size = 18,
  className,
}: {
  providerId: string;
  size?: number;
  className?: string;
}): React.ReactElement {
  const key = PROVIDER_LOGO_KEY[providerId] ?? PROVIDER_LOGO_KEY[providerId.toLowerCase()];
  const svg = key ? PROVIDER_LOGOS[key] : undefined;

  if (!svg) {
    return (
      <span
        data-testid={`provider-logo-${providerId}`}
        data-logo="fallback"
        aria-hidden
        className={cn(
          "inline-flex items-center justify-center rounded-[5px] bg-surface-hover font-semibold text-text-secondary",
          className,
        )}
        style={{ width: size, height: size, fontSize: size * 0.55 }}
      >
        {(providerId[0] ?? "?").toUpperCase()}
      </span>
    );
  }

  // The generated SVG carries only a viewBox (no width/height), so it scales to
  // fill this sized wrapper — no markup rewriting needed. Inlining is safe: the
  // SVG is a static, committed build asset, never user or network data.
  return (
    <span
      data-testid={`provider-logo-${providerId}`}
      data-logo={key}
      aria-hidden
      className={cn("inline-flex [&_svg]:block [&_svg]:h-full [&_svg]:w-full", className)}
      style={{ width: size, height: size }}
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}
