import type { Config } from "tailwindcss";

// Tailwind v3 wired to CSS variable tokens defined in src/design-system/tokens.css.
// Semantic names map onto var(--color-*) so theme swaps happen by changing variables.
const config: Config = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  darkMode: ["class", '[data-theme="dark"]'],
  theme: {
    extend: {
      colors: {
        surface: "var(--color-surface)",
        "surface-elevated": "var(--color-surface-elevated)",
        primary: "var(--color-primary)",
        "primary-hover": "var(--color-primary-hover)",
        "text-primary": "var(--color-text-primary)",
        "text-secondary": "var(--color-text-secondary)",
        "text-muted": "var(--color-text-muted)",
        "border-subtle": "var(--color-border-subtle)",
        "border-strong": "var(--color-border-strong)",
        accent: "var(--color-accent)",
      },
      fontFamily: {
        sans: ["var(--font-sans)"],
        mono: ["var(--font-mono)"],
        pixel: ["var(--font-pixel)"],
      },
      borderRadius: {
        xs: "var(--radius-xs)",
        sm: "var(--radius-sm)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
        xl: "var(--radius-xl)",
        capsule: "999px",
      },
      spacing: {
        gutter: "var(--space-gutter)",
        section: "var(--space-section)",
      },
      boxShadow: {
        card: "var(--shadow-card)",
        capsule: "var(--shadow-capsule)",
        elevated: "var(--shadow-elevated)",
      },
      transitionTimingFunction: {
        spring: "cubic-bezier(0.22, 1, 0.36, 1)",
      },
      animation: {
        // Sweep for `<AppIndeterminateBar />`. Matches macOS spec:
        // 1.15s easeInOut, infinite, non-reversing.
        "indeterminate-bar": "indeterminate-bar 1.15s ease-in-out infinite",
      },
    },
  },
  plugins: [],
};

export default config;
