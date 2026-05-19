# Agent Deck — Brand Identity & Marketing Brief

---

## The Name: **Agent Deck**

> A native macOS command center for Pi AI agents.

---

### Rationale

**Agent Deck** captures the metaphor of a deck of cards — each agent is a card you play, each skill a tool you deal, and every session a hand you manage from one organized surface.

| Element | How Agent Deck delivers it |
|---------|---------------------------|
| **Deck metaphor** | A deck holds many cards, each with a purpose. Agent Deck holds your agents, skills, prompts, and sessions — organized, shuffled, ready to play. |
| **Agent + skill management** | You deal agents into projects, stack skills onto them, and play the right combination for the task at hand. |
| **Orchestration** | A card table gives the dealer full oversight. Agent Deck gives you that same clarity — every agent visible, every skill accounted for. |
| **Native macOS vs TUI** | You don't manage a deck from a terminal. Agent Deck is the native macOS surface where you lay out, inspect, and command your AI resources. |
| **Collectible / extensible** | Decks grow. You add new agents, import new skills, discover new prompts. Agent Deck is your growing collection. |

---

### Strapline / Tagline Options

**Primary:**
> Command your AI agent fleet.

**Alternatives:**
> Deal your agents. Command your code.
> The native macOS command center for Pi.
> Orchestrate. Supervise. Command.
> Every agent. One deck.

---

### Brand Voice & Personality

| Attribute | Description |
|-----------|-------------|
| **Authoritative** | Speaks with quiet confidence. No hype, no buzzwords — just command. |
| **Professional** | Developer-first, macOS-native quality. Every pixel earned. |
| **Calm** | Like a well-organized card table: everything where you need it, nothing where you don't. |
| **Precise** | Words are chosen with care. Clear over clever. |

**Tone examples:**

| Context | Voice |
|---------|-------|
| Website hero | "Your AI agents. Under your command. From your Mac." |
| App Store description | "Agent Deck is the native macOS command center for Pi AI agents. Orchestrate agents, manage skills, and supervise every interaction — without touching a terminal." |
| Error/empty state | "No agents running. Ready when you are." |
| Onboarding | "Welcome to Agent Deck. Here's what you can command." |

---

### Visual Identity Direction

#### App Icon

**Current icon: Deck of Cards (Icon Composer)**
- Built with Apple's **Icon Composer** (`.icon` format) for native macOS 26 Tahoe Liquid Glass rendering
- Depicts a stylized **deck of cards** — stacked, offset rectangles forming the silhouette of a card deck
- Gradient fill: muted steel-gray tones (`display-p3` gray gradient) with translucency and neutral shadow
- The stacked-card motif directly echoes the "Deck" in the name — instantly recognizable at any size
- Liquid Glass treatment gives depth, light refraction, and platform-native feel
- At 16×16px it reads as a clean, layered shape. At 1024×1024px it reveals glass depth and subtle reflections

#### Color Palette

Continue using the existing brand accent colors — they complement the Agent Deck identity:

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
> *Agent Deck is the native macOS command center for Pi AI agents.*

#### Short description (App Store tagline)
> *Orchestrate agents, manage skills, and supervise every interaction — without touching a terminal.*

#### App Store description (draft)
> **Agent Deck is the native macOS command center for Pi AI agents.**
>
> If you use Pi CLI, you know how powerful AI-driven coding can be. But the terminal wasn't built for oversight. Agent Deck gives you a calm, visual surface for everything Pi can do — and more.
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
> Agent Deck turns your terminal workflow into a native macOS experience. Your AI agents, under your command. From your Mac.

#### Website hero section
> **Agent Deck**
> *A native macOS command center for Pi AI agents.*
>
> [CTA: Download for macOS]
> [CTA: Learn more]

#### Social / Tagline variants
> **Twitter/X bio:** Native macOS command center for Pi AI agents. Orchestrate, supervise, command.
> **GitHub description:** A native macOS command center for Pi AI agents.

---

### Brand Territory

Agent Deck occupies a unique space at the intersection of:

```
Terminal (Pi CLI)        ←  →  Native macOS app
      ↓                        ↑
   Raw power              Calm oversight
      ↓                        ↑
   Flexible but chaotic   Structured but controlled
```

Agent Deck doesn't replace Pi — it gives Pi a surface. It's the bridge between the raw power of the terminal and the calm clarity of a well-designed native app.

---

### Naming Considerations

| Check | Status |
|-------|--------|
| Trademark conflict (AI agent management, macOS) | Unlikely — "Agent Deck" is a descriptive compound; no direct competitor in this space |
| Domain availability | `agentdeck.app`, `agentdeck.io`, `getagentdeck.com` likely available |
| Package manager / SwiftPM | `AgentDeck` — clean, no conflicts |
| Bundle identifier | `streetcoding.agent-deck` — already in use |
| App Store searchability | "Agent Deck" is specific and searchable; "Agent Deck AI" narrows well |
| Internationalization | Common English compound, easy to understand across languages |

---

### Brand Architecture

```
Agent Deck
  └── Agent Deck for Pi (marketing context, web)
  └── Agent Deck.app (on disk, in /Applications)
  └── streetcoding.agent-deck (bundle identifier)
```

The brand stands alone. "For Pi" is used only in contexts that need to explain the underlying technology (website, docs). In the app itself, it's just **Agent Deck**.

---

### Tagline Hierarchy

| Level | Text |
|-------|------|
| **Primary tagline** | Command your AI agent fleet. |
| **Hero / website** | A native macOS command center for Pi AI agents. |
| **Subtitle / explainer** | Every agent. One deck. |
| **One-liner (elevator)** | The native macOS command center for Pi. |

---

### Icon / Glyph Description

**Deck of Cards (current icon — built with Icon Composer):**

The app icon depicts a stylized deck of playing cards — a stack of offset rectangles rendered in steel-gray tones with Liquid Glass translucency. Built with Apple's Icon Composer tool using the `.icon` format for native macOS 26 Tahoe rendering.

- **Shape:** Layered, stacked rectangles suggesting a deck of cards viewed from above
- **Style:** Liquid Glass with translucency (`0.5` value), neutral shadow, and a vertical gray gradient
- **Scale:** The glyph is rendered at `1.57×` scale within the icon grid for visual prominence
- **Platform:** Supports square icon (macOS, iOS, iPadOS) and circle variant (watchOS)

The stacked-card motif is a direct visual representation of the "Deck" in Agent Deck — a collection of organized, ready-to-use resources. At small sizes it reads as a bold layered shape; at large sizes the Liquid Glass depth and translucency give it the premium, native macOS feel.
