# Pilot — Brand Identity & Marketing Brief

---

## The Name: **Pilot**

> A native macOS command center for Pi AI agents.

---

### Rationale

**Pilot** distills everything this app is into a single, punchy, five-letter word.

| Element | How Pilot delivers it |
|---------|----------------------|
| **Pi connection** | The name literally starts with **"Pi"** — a subtle but unmistakable nod that Pi powers the experience. Users of Pi will feel the connection instantly. |
| **Orchestration** | A pilot doesn't just watch — they **command, steer, and orchestrate**. Every agent, skill, and session falls under your direction. |
| **Agent + skill management** | Managing a fleet of agents with diverse skills is *piloting*. You assign, monitor, adjust, and supervise. |
| **Native macOS vs TUI** | Pilots fly from a cockpit, not a terminal. Pilot is the native macOS cockpit for AI agent work — visual, calm, in command. |
| **Authoritative tone** | "Pilot" is confident without being aggressive. It sits you in the captain's chair. |

---

### Strapline / Tagline Options

**Primary:**
> Command your AI agent fleet.

**Alternatives:**
> Pilot your AI agents. Not a terminal.
> The native macOS command center for Pi.
> Orchestrate. Supervise. Command.

---

### Brand Voice & Personality

| Attribute | Description |
|-----------|-------------|
| **Authoritative** | Speaks with quiet confidence. No hype, no buzzwords — just command. |
| **Professional** | Developer-first, macOS-native quality. Every pixel earned. |
| **Calm** | Like a well-designed cockpit: everything where you need it, nothing where you don't. |
| **Precise** | Words are chosen with care. Clear over clever. |

**Tone examples:**

| Context | Voice |
|---------|-------|
| Website hero | "Your AI agents. Under your command. From your Mac." |
| App Store description | "Pilot is the native macOS command center for Pi AI agents. Orchestrate agents, manage skills, and supervise every interaction — without touching a terminal." |
| Error/empty state | "No agents running. Ready when you are." |
| Onboarding | "Welcome to the cockpit. Here's what you can command." |

---

### Visual Identity Direction

#### App Icon

**Primary concept: Compass Rose**
- A minimalist compass rose in **Liquid Glass** style (macOS 26 Tahoe aesthetic)
- Connects to: navigation, direction, circles (Pi), command
- Brand colors: teal/cyan accent (`#8DDEFF`) on a dark or clear background
- 4-pointed star (simple, bold, recognizable at 16×16px)

**Alternative concept: Aviator Sunglasses**
- A stylized, minimalist aviator silhouette
- Instantly readable as "pilot" — cool, confident, iconic
- The reflection in the lenses could subtly show agent activity or a terminal prompt

**Alternative concept: Yoke / Control Wheel**
- A minimalist aircraft yoke
- The most literal "pilot" symbol
- Conveys hands-on control

#### Color Palette

Continue using the existing brand accent colors — they work perfectly with the Pilot identity:

| Token | Color | Usage |
|-------|-------|-------|
| `brandAccentBright` | `#8DDEFF` (cyan) | Primary accent, icon highlights |
| `brandAccentDeep` | `#008080` (teal) | Secondary accent, depth |
| Existing macOS vibrancy | System materials | Native macOS feel |

#### Typography

- **Brand typography:** SF Pro (system font) — clean, native, professional
- **In-app flair:** Keep the Kemco Pixel Bold font for the sidebar title as a nod to the developer/terminal roots
- **Marketing materials:** SF Pro Display for headlines, SF Pro Text for body

---

### Marketing Copy

#### One-liner
> *Pilot is the native macOS command center for Pi AI agents.*

#### Short description (App Store tagline)
> *Orchestrate agents, manage skills, and supervise every interaction — without touching a terminal.*

#### App Store description (draft)
> **Pilot is the native macOS command center for Pi AI agents.**
>
> If you use Pi CLI, you know how powerful AI-driven coding can be. But the terminal wasn't built for oversight. Pilot gives you a calm, visual cockpit for everything Pi can do — and more.
>
> **Command your AI fleet.**
> - Chat with agents in a rich, native transcript UI with real-time activity, tool calls, diffs, and thinking traces
> - Manage multiple sessions: create, stop, resume, delete — all from one window
>
> **Orchestrate agents and skills.**
> - Browse, edit, create, and enable/disable agents across all scopes (builtin, global, library, project)
> - Import, assign, and manage skills per project
> - Create and manage prompt templates with invocation names
>
> **Supervise with clarity.**
> - See git status, stage changes, view diffs, and commit — all without leaving the app
> - Connect to GitHub issues, manage workflows, push with confidence
> - Run supervised parallel child sessions with worktree safety
>
> **Configure without the CLI.**
> - Manage environment variables across global and project `.env` files
> - Discover and configure models, disable unwanted ones
> - Run Doctor to check CLI health, model availability, and configuration
>
> Pilot turns your terminal workflow into a native macOS experience. Your AI agents, under your command. From your Mac.

#### Website hero section
> **Pilot**
> *A native macOS command center for Pi AI agents.*
>
> [CTA: Download for macOS]
> [CTA: Learn more]

#### Social / Tagline variants
> **Twitter/X bio:** Native macOS command center for Pi AI agents. Orchestrate, supervise, command.
> **GitHub description:** A native macOS command center for Pi AI agents.

---

### Brand Territory

Pilot occupies a unique space at the intersection of:

```
Terminal (Pi CLI)        ←  →  Native macOS app
      ↓                        ↑
   Raw power              Calm oversight
      ↓                        ↑
   Flexible but chaotic   Structured but controlled
```

Pilot doesn't replace Pi — it gives Pi a cockpit. It's the bridge between the raw power of the terminal and the calm clarity of a well-designed native app.

---

### Naming Considerations

| Check | Status |
|-------|--------|
| Trademark conflict (AI agent management, macOS) | Unlikely — "Pilot" is a common word; no direct competitor in this space |
| Domain availability | `pilotai.app`, `pilotforpi.com`, `getpilot.app` likely available |
| Package manager / SwiftPM | `Pilot` — clean, no conflicts |
| CLI tool name | `pilot` — short, typable, memorable |
| App Store searchability | "Pilot" is searchable; "Pilot AI" narrows well |
| Internationalization | Common English word, easy to pronounce across languages |

---

### Brand Architecture

```
Pilot
  └── Pilot for Pi (marketing context, web)
  └── Pilot.app (on disk, in /Applications)
  └── pilot (future CLI companion, if any)
```

The brand stands alone. "For Pi" is used only in contexts that need to explain the underlying technology (website, docs). In the app itself, it's just **Pilot**.

---

### Tagline Hierarchy

| Level | Text |
|-------|------|
| **Primary tagline** | Command your AI agent fleet. |
| **Hero / website** | A native macOS command center for Pi AI agents. |
| **Subtitle / explainer** | Pilot your AI agents. Not a terminal. |
| **One-liner (elevator)** | The native macOS cockpit for Pi. |

---

### Icon / Glyph Sketch Description

**Compass Rose (recommended icon direction):**

```
        ▲
        │
    ┌── ┼ ──┐
    │   │   │
  ◄──┼───┼──►
    │   │   │
    └── ┼ ──┘
        │
        ▼
```

A 4-pointed star executed in Liquid Glass — layered with depth, light, and the teal/cyan accent gradient. The four points represent the four core domains: **agents, skills, sessions, projects**. Rounded, not sharp. Glowing, not harsh. macOS-native through and through.

At 16×16px it reads as a clean star. At 1024×1024px it reveals Liquid Glass depth and subtle reflections. Versatile, iconic, unmistakable.
