# Poimi — Design Language

*The visual and interaction north star. Guides the Paper design work and the `docs/design/` UI specs that transcribe each screen from the [design inventory](../plans/project-phases.md#design-inventory-views-interactions-to-design). Companion to the [product plan](../plans/product-plan.md), [architecture](../plans/architecture.md), and [decisions log](../plans/plan-review-decisions.md).*

---

## One line

**The photos are the product; everything else is quiet, fast, and gets out of the way.** Poimi should feel like a focused, intelligent extension of Apple Photos — not a new visual world to learn.

## Principles (the feel)

| Feel | What it means here |
|---|---|
| **Simple** | Ruthless reduction. One clear primary action per screen, system components, no novel chrome. If Photos/Notes wouldn't add it, we don't. |
| **Usable** | Thumb-reachable controls, generous hit targets (≥44pt), forgiving (undo, no destructive surprises), every state designed (empty, error, resume). |
| **Intuitive** | Borrow muscle memory — standard gestures, the Photos grid/viewer pattern, no tutorial needed. The interaction is *recognized*, not learned. |
| **Fast** | Instant feedback on every tap (optimistic selection), progressive image loading, no blocking spinners, fluid scrolling (target 120fps on ProMotion). Perceived speed is a design requirement, not an optimization. |
| **Intelligent** | Surface orientation — counts, coverage, gentle suggestions — *without deciding for the user*. The human picks every photo; the app is the calm, smart instrument. Quiet smart defaults, never automation. |

*These are perceptual goals — "calm," "fast," "feels like Photos." They are validated by **human design sign-off and the Phase 0 spike on a real library**, not by automated tests (D22). The mechanizable parts (≥44pt targets, no color-only state, Reduce-Motion/Transparency fallbacks, no blocking spinner in the hierarchy) are asserted in tests; the feel is not.*

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

**Build custom only where the product genuinely needs it:** the grid cell + its selection affordance, the zoom detail view, the tally chrome. Never reimplement a system control. No UIKit *views/controllers*; Observation, not Combine. *(Narrow exception: UIKit constants with no SwiftUI equivalent — e.g. `UIApplication.openSettingsURLString` for the recovery deep-link, D6 — are fine; opening still goes through the SwiftUI `openURL` environment.)*

## Liquid Glass (the "liquid design")

Apple's Liquid Glass is the design language for iOS/iPadOS 26: a translucent, dynamic, light-refracting material that layers *above* content. Our adoption:

- **Chrome is glass, photos are content.** Toolbars, the tally bar, and floating controls use the glass material and recede; the photo grid is opaque and dominant beneath them. Glass never competes with the imagery.
- **Legibility over the photo grid is the hard case — solve it explicitly.** Glass is *adaptive* (it samples the content beneath), but a tally floating over a grid that is simultaneously a bright snow shot and a dark night shot has no single backdrop to adapt to, and small numerals can drop below contrast minimums. We adopt Apple's Photos pattern: the **scroll-edge effect** (a progressive blur/dim where scrolling content meets floating chrome) guarantees separation. Standard toolbars get it for free; the custom tally rides inside a `safeAreaInset`/toolbar region that gets the same treatment, never raw `glassEffect()` over arbitrary photos for must-read text. **Acceptance criterion:** the tally is legible over the brightest seeded thumbnail (checked in the accessibility audit). **v1 status:** the pinned `ReviewHeader` ships with a **`.bar` material** (a valid translucent bar, Reduce-Transparency-safe) as a deliberate interim — the full iOS-26 `glassEffect` scroll-edge is a deferred device-iteration task (no in-app precedent, the blur can't be verified from a screenshot, and it's adjacent to a prior glass-nav glitch). Tracked separately; `.bar` satisfies the legibility criterion in the meantime.
- **One glass layer — never glass-on-glass.** Liquid Glass is a single floating layer above content; nesting glass (a glass control inside a glass bar, a glass card on a glass background) muddies legibility. Group co-located glass into one `GlassEffectContainer`; match corner radii to the container (concentricity). On the review screen the **tally + export form a single grouped glass region**, not separate floating elements.
- **Restraint.** Glass is for floating, functional chrome — not slathered everywhere. Large content surfaces stay solid for legibility over busy photos.
- **Custom surfaces use the SwiftUI glass APIs** (`glassEffect(...)`, `GlassEffectContainer`, `.buttonStyle(.glass)`) so they match the system; standard navigation/toolbars/controls render Liquid Glass on 26 with no work (lean on them).

### Minimum target: iOS 26 *(decided)*

We target **iOS 26 / iPadOS 26** — so Liquid Glass is the native, pure design language with **no SDK-version availability gates and no `.regularMaterial` version fallbacks**. As a new app with no install base to protect, the wider reach of an older floor buys us nothing, while the latest SDK gives the cleanest SwiftUI and the simplest code path (a real win for an AI author). The glass APIs above are used directly, not conditionally.

*Two things this does **not** mean: (1) the bet is conscious — if a young glass API regresses, the fallback is to drop that one custom surface to a plain material; the system chrome is unaffected because it carries no glass-API calls. (2) "No version fallback" is a different axis from accessibility fallbacks — every custom glass surface still defines its Reduce-Transparency appearance (below).*

## Apple HIG

The HIG is the baseline, not a suggestion. Specifically: standard navigation patterns, no fighting the system; semantic colors + materials (works in light/dark, high-contrast); SF Symbols with proper rendering modes; ≥44pt targets; **state never encoded in color alone** (checkmark + dim for selection); request permission in context with a clear rationale; respect Reduce Motion, Increase Contrast, and Dynamic Type at accessibility sizes.

**Reduce Transparency** is the legibility-critical accessibility setting for a glass-heavy app, and gets first-class treatment alongside Reduce Motion: standard components handle it automatically, and **every custom glass surface (tally bar, export button) defines an opaque/high-contrast solid appearance** for when it's on — designed in, not bolted on. (iOS 26.1 also adds a system Liquid-Glass tinted/clear toggle that standard chrome inherits.) **Dynamic Type pressure point:** dense numerals on glass at the largest accessibility sizes is the most likely failure — the tally must have a designed reflow at AX sizes (e.g. drop to total-only, or move onto a solid backing).

---

## iOS **and** iPadOS — one adaptive app

Target both; design adaptively rather than porting. **v1 scope (decided):** the adaptive *layout* — including iPad split-view — ships in v1; the iPad *input polish* is deferred to v1.1 (so the navigation architecture is settled now, but the input-mode test surface stays small).

- **Layout by size class — v1.** Compact width (iPhone, slide-over): `NavigationStack`, single-column grid flow, bottom-reachable chrome. Regular width (iPad, large iPhone landscape): a **2-column `NavigationSplitView`** (#42) — sidebar (album library) + a detail column hosting its own `NavigationStack` (overview → review grid → export). The photo viewer stays a Now-Playing sheet over the detail (#36), so there's no third photo-detail column. The grid's `LazyVGrid` column count is derived from the detail width — dense on iPad, reflowing on Split View / Stage Manager resize.
- **Sidebar — v1.** Holds the album library; location buckets join it in v1.1. (Until buckets land it's lightweight — the albums list + setup entry.)
- **Pointer, hover, keyboard & drag-and-drop — v1.1.** Hover states on cells, keyboard shortcuts for the power workflow (select/deselect, next/previous, expand, export) with a discoverability overlay, trackpad-friendly drag-select, and drag-and-drop. This is where the iPad becomes a *power tool*; it's deferred so v1 doesn't carry the extra input-mode test matrix.
- **Multitasking — v1.** Split View / Stage Manager / window resizing must reflow cleanly; no fixed layouts.
- **One codebase, adaptive views** — not separate iPhone/iPad screens.

## Foundations

- **Color** — semantic system colors + a single restrained accent. The *photos* provide the color; branding stays minimal so content sings (Music's lesson). Works in light/dark automatically.
- **Typography** — the system font, system text styles, full Dynamic Type. Large bold titles (Music-style) used sparingly for moments that matter; body and labels stay standard and legible.
- **Spacing** — system metrics with generous breathing room (Notes' calm); let content and whitespace carry the layout, not borders and boxes.
- **Iconography** — SF Symbols throughout for consistency and weight-matching. A distinctive **app icon** does heavy lifting given the opaque name (per the product plan); on iOS 26 it's a layered deliverable (Icon Composer) with light/dark/clear/tinted variants — scheduled before submission.
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
- **No glass-on-glass**, and no glass over must-always-be-legible content without a contrast guarantee (scroll-edge effect / solid backing).

## Decided non-features (v1)

- **No widgets / Share Extension / App Intents in v1** — a focused utility, not a suite. Noted as intentional, not an oversight; the Oura-glanceable tally is an obvious **v1.1 widget** candidate, and a Share Extension (send photos *into* a session) is a natural later add.

## Open decisions

- **Mac Catalyst / "Designed for iPad on Mac"** — out of scope for now; the adaptive layout keeps the door open.
