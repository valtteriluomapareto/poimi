# Poimi — Design Language

*The visual and interaction north star. Guides the Paper design work and the `docs/design/` UI specs that transcribe each screen from the [design inventory](../plans/project-phases.md#design-inventory--views--interactions-to-design). Companion to the [product plan](../plans/product-plan.md), [architecture](../plans/architecture.md), and [decisions log](../plans/plan-review-decisions.md).*

---

## One line

**The photos are the product; everything else is quiet, fast, and gets out of the way.** Poimi should feel like a focused, intelligent extension of Apple Photos — not a new visual world to learn.

## Principles (the feel)

| Feel | What it means here |
|---|---|
| **Simple** | Ruthless reduction. One clear primary action per screen, system components, no novel chrome. If Photos/Notes wouldn't add it, we don't. |
| **Usable** | Thumb-reachable controls, generous hit targets (≥44pt), forgiving (undo, no destructive surprises), every state designed (empty, error, resume). |
| **Intuitive** | Borrow muscle memory — standard gestures, the Photos grid/viewer pattern, no tutorial needed. The interaction is *recognized*, not learned. |
| **Fast** | Instant feedback on every tap (optimistic selection), progressive image loading, no blocking spinners, 120fps scrolling. Perceived speed is a design requirement, not an optimization. |
| **Intelligent** | Surface orientation — counts, coverage, gentle suggestions — *without deciding for the user*. The human picks every photo; the app is the calm, smart instrument. Quiet smart defaults, never automation. |

## What we borrow from the inspiration apps

- **Apple Photos** — the spine. Edge-to-edge month-sectioned grid, full-screen viewer, Select mode, translucent chrome floating over imagery, restraint. Our core review loop *is* this pattern; matching it is the intuitiveness win.
- **Apple Notes** — clarity and calm. Minimal hierarchy, content-first, gentle. Take its uncluttered confidence for setup/list screens.
- **Oura** — *intelligent yet calm.* How it presents a score/progress toward a goal in a friendly, legible, non-nagging way — directly informs the running tally / target progress, and the "intelligent" tone overall.
- **Apple Music** — expressive imagery and fluid navigation. Bold large titles used sparingly, rich edge-to-edge artwork, dynamic color drawn from content. Our content *is* photos — let them bring the color.
- **Apple Stocks** — glanceable density done cleanly. Compact, system-standard presentation of numbers (the tally, per-month targets) that reads at a glance without feeling busy.

---

## SwiftUI to the max

**Use standard SwiftUI components first, everywhere they fit.** `NavigationStack` / `NavigationSplitView`, `List`, `Form`, `LazyVGrid`, system `Button`/`Toggle`/`Picker` styles, SF Symbols, semantic colors, system materials. Reasons:

1. We inherit platform behavior, accessibility, Dynamic Type, and pointer/keyboard support for free.
2. **Standard components adopt Liquid Glass automatically** when built against the current SDK — the look comes for free and stays current.
3. Less custom code is less to test and less to maintain (aligns with the AI-author guidelines).

**Build custom only where the product genuinely needs it:** the grid cell + its selection affordance, the zoom detail view, the tally chrome. Never reimplement a system control. No UIKit; Observation, not Combine.

## Liquid Glass (the "liquid design")

Apple's Liquid Glass is the design language for iOS/iPadOS 26: a translucent, dynamic, light-refracting material that layers *above* content. Our adoption:

- **Chrome is glass, photos are content.** Toolbars, the tally bar, and floating controls use the glass material and recede; the photo grid is opaque and dominant beneath them. Glass never competes with the imagery.
- **Lean on the system.** Standard navigation/toolbars/controls render Liquid Glass on 26 with no work. For the few custom surfaces (tally bar, floating export button), use the SwiftUI glass APIs (`glassEffect(...)`, `GlassEffectContainer`, `.buttonStyle(.glass)`) so they match — grouped in a container so concentric/adjacent glass blends correctly.
- **Restraint.** Glass is for floating, functional chrome — not slathered everywhere. Large content surfaces stay solid for legibility over busy photos.

### Minimum target: iOS 26 *(decided)*

We target **iOS 26 / iPadOS 26** — so Liquid Glass is the native, pure design language with **no availability gates and no `.regularMaterial` fallbacks**. As a new app with no install base to protect, the wider reach of an older floor buys us nothing, while the latest SDK gives the cleanest SwiftUI and the simplest code path (a real win for an AI author). The glass APIs above are used directly, not conditionally.

## Apple HIG

The HIG is the baseline, not a suggestion. Specifically: standard navigation patterns, no fighting the system; semantic colors + materials (works in light/dark, high-contrast); SF Symbols with proper rendering modes; ≥44pt targets; **state never encoded in color alone** (checkmark + dim for selection); request permission in context with a clear rationale; respect Reduce Motion, Increase Contrast, and Dynamic Type at accessibility sizes.

---

## iOS **and** iPadOS — one adaptive app

Target both from day one; design adaptively rather than porting.

- **Layout by size class.** Compact width (iPhone, slide-over): `NavigationStack`, single-column grid flow, bottom-reachable chrome. Regular width (iPad, large iPhone landscape): `NavigationSplitView` — sidebar (sessions / later, location buckets) · the review grid · the photo detail. The grid uses adaptive `LazyVGrid` columns that scale with available width.
- **Pointer, hover & keyboard (iPad).** Hover states on cells, keyboard shortcuts for the power workflow (select/deselect, next/previous, expand, export), trackpad-friendly drag-select. This is a *power tool* — iPad with a keyboard should feel first-class.
- **Multitasking.** Split View / Stage Manager / window resizing must reflow cleanly; no fixed layouts. Drag-and-drop of photos is a natural iPad affordance to consider.
- **One codebase, adaptive views** — not separate iPhone/iPad screens.

## Foundations

- **Color** — semantic system colors + a single restrained accent. The *photos* provide the color; branding stays minimal so content sings (Music's lesson). Works in light/dark automatically.
- **Typography** — the system font, system text styles, full Dynamic Type. Large bold titles (Music-style) used sparingly for moments that matter; body and labels stay standard and legible.
- **Spacing** — system metrics with generous breathing room (Notes' calm); let content and whitespace carry the layout, not borders and boxes.
- **Iconography** — SF Symbols throughout for consistency and weight-matching. A distinctive **app icon** does heavy lifting given the opaque name (per the product plan).
- **Materials** — system materials / Liquid Glass for chrome over imagery; solid surfaces for dense text/legibility.

## Motion

- **The zoom transition is the signature motion** — thumbnail expands to full-screen and animates back to its source cell (D10). Physical, quick, never showy.
- Selection feedback is **instant** with light haptics. Avoid gratuitous animation; motion should clarify spatial relationships, not decorate.
- **Reduce Motion** substitutes a cross-fade for the zoom and removes incidental animation — designed in, not patched.

## Imagery

Photos are the hero. Maximize photo area, minimize chrome, edge-to-edge grid. Thumbnails sharpen progressively (instant placeholder → full-res). Chrome floats translucently and recedes so the eye stays on the photos — the thing the user is actually deciding about.

## Anti-patterns (what Poimi is *not*)

- No custom nav bars or controls that fight the system look.
- No skeuomorphism, heavy gradients, or decorative chrome.
- No color-only state, no sub-44pt targets.
- No blocking full-screen spinners — progressive/optimistic instead.
- No modal mazes or deep settings; a focused utility, not a suite.
- No automation that picks photos for the user — intelligence orients, the human decides.

## Open decisions

- **Mac Catalyst / "Designed for iPad on Mac"** — out of scope for now; the adaptive layout keeps the door open.
