# Poimi — Styleguide (v0)

*The concrete token layer beneath the [design language](./design-language.md). Where `design-language.md` sets the **feel** ("calm, fast, feels like Photos"), this pins the **values** — colors, type, spacing, radii, materials, motion, symbols — so the Paper styleguide artboard and the SwiftUI code share one source of truth. Companion to [project-phases.md](../plans/project-phases.md) (design inventory) and [architecture.md](../plans/architecture.md).*

> **Status: v0, for review.** A first concrete pass to react to and refine, then build visually in Paper. Open decisions are flagged inline and collected at the bottom. Nothing here is frozen — per D27 we validate by *using* a rough build, then settle the spec.

> **iOS 26 / iPadOS 26, SwiftUI-only.** Tokens are expressed as **semantic system values first** (so light/dark, high-contrast, and Liquid Glass come for free), with explicit custom values only where the product genuinely needs them. The photos bring the color; the system brings the rest.

> **Visual companion:** these tokens are built as a live styleguide artboard in the [Paper file](https://app.paper.design/file/01KVSFMATJM712ABNQ5D0YDR1T/1-0) (54 design tokens + the component atoms). **Inter stands in for SF Pro** in Paper (the system font isn't installable there); production uses the real system font. This doc and the Paper tokens are kept in sync.

---

## 0. North star in one line

**Photos are the product; chrome is quiet glass that recedes.** Every token below either maximizes photo area, keeps must-read chrome legible, or gets out of the way.

---

## 1. Color

**Strategy:** semantic system colors + a **two-colour brand** with strict role separation — **Cloudberry gold = primary** (the one *interactive* accent) and **Leaf green = secondary** (a *brand/identity* colour, scoped to identity surfaces and kept out of the review-grid chrome). Branding stays minimal so the imagery sings (Apple Music's lesson); the two brand colours never compete over the photos. Everything adapts to light/dark and Increase-Contrast automatically because it's semantic.

| Role | Token | Notes |
|---|---|---|
| Screen background (setup/list) | `Color(.systemBackground)` / grouped variants in `Form`/`List` | Notes-calm; let whitespace carry layout. |
| Grid backdrop (gutters behind cells) | `Color(.systemBackground)` | ~3pt gutters between rounded cells (Apple-Photos-style, §3). |
| Thumbnail placeholder | `Color(.systemGray6)` | Neutral, before progressive load resolves. |
| Primary text | `.primary` | Titles, counts. |
| Secondary text | `.secondary` | Group counts, captions, supporting copy. |
| Tertiary / hints | `.tertiary` | De-emphasized metadata. |
| Separators | `Color(.separator)` | Only where structure truly needs a line (prefer space). |
| **Primary** accent — **Cloudberry (lakka)** | Asset Catalog `AccentColor`, light+dark | Selection check, tally progress, export/primary actions. **Decided: warm golden berry — see below.** |
| **Secondary** — **Leaf green** | `--color-secondary` (`#3F5E37` / `#7DA164`, asset `BrandGreen`) | **Brand/identity + "kept / finished":** app icon, onboarding, empty/complete states; and in the review grid the **selection border**, the **done seal badge**, the **"Mark as done" button**, and the **at-target tally bar** — the "green marks what you kept/finished" role (D35). Gold stays the *interactive* accent; green marks *state*. See below. |
| Destructive / clear | `.red` (system) | "Clear selection" and the like, sparingly. |

**Accent — decided: Cloudberry / *lakka* (warm golden berry).** A photo grid is already maximally colorful, so the accent stays *quiet* and earns its few appearances (the selection check, the running-tally progress, the export button). We chose a warm golden berry tone because it is doubly on-concept: **Poimi means "pick!"** and in Finland that means **berries** — *lakka* (cloudberry) is "Finnish gold." It carries the warm, characterful identity (the original warm-clay instinct) while tying the colour straight to the name. *(Explored across three boards in Paper: a warm-clay family, cool/neutral directions — system blue, teal, indigo, graphite — and a berry set — lingonberry, raspberry, bilberry, blackcurrant, cloudberry.)*

| Appearance | Hex | sRGB |
|---|---|---|
| Light | `#D08A2A` | 208, 138, 42 |
| Dark | `#E8B05A` | 232, 176, 90 |
| On-accent (foreground) | `#1C1C1E` | dark — the gold is light in both modes |

Rationale & guardrails:
- **Quiet, not neon** — a mid-tone gold, reads as "warm system" rather than brand-shout. Warm-gold-on-dark (the review grid) is where it sings.
- **Foreground on accent is dark** (`#1C1C1E`), not white — the gold is light in both modes, so the check glyph and Export label are dark for contrast.
- **Light-mode caveat:** because gold is light, it has low contrast as *small text on white*. Use it for **graphical** marks (check, progress fill, toggle, glass-tinted button) — **never small body text on a light ground**. Section ordinals etc. that use it are decorative only. The accent must still clear contrast over the brightest seeded thumbnail (the tally legibility criterion) — validated in the accessibility audit.
- **Selection never relies on the accent alone** (redundant encoding — §6); accent is the *secondary* cue, check + dim is primary.
- Locked into the `AccentColor` asset (light/dark).

**Secondary — green (brand/identity, colour only).** The two hues were *derived* from the cloudberry and its setting (a warm gold, a deep green) — that's the colour origin, nothing more. **Poimi is not a berry or nature app:** there are no berries, leaves, or nature motifs in the UI. Green appears purely as a **subtle colour hint**, never as imagery, and never as a second interactive accent.

| Appearance | Hex | sRGB |
|---|---|---|
| Light (deep) | `#3F5E37` | 63, 94, 55 |
| Dark | `#7DA164` | 125, 161, 100 |
| On-secondary (foreground) | `#FFFFFF` | white on the deep-green fill |

Where green appears (colour only — no motifs):
- **Onboarding / first-run** — a quiet green colour accent (e.g. a kicker rule) warming the calm light screens.
- **Sidebar / albums** — a subtle green status dot for the active album.
- **Empty & complete states** — the optional "target reached / album ready" affirmation (gold counts *up*; green marks the *finish*).
- **App icon** — **deferred (iterate later).** The icon may draw on the gold/green palette, but the mark itself is an open question — and it is **not** berry/nature.
- **Green in the grid — "kept / finished" (updated D35):** a **2px `brandGreen` inset border** outlines a selected cell (§6); the **gold check remains the affordance** and the tally/Export stay gold. Beyond the border, green now also marks *state* in the grid — the **done seal badge**, the **"Mark as done" button**, and the **at-target tally bar**. Rule of thumb: **gold = interaction, green = state (selected / kept / done)**. Everything green uses the one `brandGreen` token (no system `Color.green`) so the greens don't compete.
- **No nature imagery anywhere** — colour as a hint, nothing literal.

---

## 2. Typography

**System font (SF Pro), system text styles, full Dynamic Type — including accessibility sizes.** Large bold titles used *sparingly* (Music) for moments that matter; body and labels stay standard and legible (Notes).

| UI element | Text style | Weight / treatment |
|---|---|---|
| Setup screen title | `.largeTitle` | `.bold` — used at the few entry moments, not everywhere. |
| Section / sheet titles | `.title2` | `.semibold`. |
| Day-group header — date | `.headline` | e.g. "Sat 5 Jul" / "16–18 Mar". |
| Day-group header — count | `.subheadline` `.secondary` | e.g. "53" — a label, never a quota (D5). |
| **Running tally numerals** | `.title2` **`.monospacedDigit()`** | "147 / 200" must not jitter as it counts (Stocks-glanceable). Friendly-rounded numerals (`design: .rounded`) are an **option to try in Paper** for the Oura tone. |
| Body / form labels | `.body` | Standard. |
| Captions / metadata | `.caption` / `.footnote` `.secondary` | |
| Buttons | `.body` `.semibold` (system button styles supply this) | Lean on system styles. |

**AX-size rule:** the dense tally on glass is the most likely Dynamic-Type failure — it must have a *designed* reflow at accessibility sizes (drop to total-only, or move onto a solid backing). Designed in §5 / §8, not bolted on.

---

## 3. Spacing & layout

**8pt base rhythm; system metrics with generous breathing room.** Let content and whitespace carry the layout, not borders and boxes.

| Token | Value | Use |
|---|---|---|
| Base unit | **8pt** | Multiples for padding/stacks (4 for fine, 8/16/24 for layout). |
| Grid gutter (inter-item + line) | **~3pt** | Small inter-cell gap, Apple-Photos-style (**revised** from the initial gapless wall — the owner's on-device call). The gutter carries cell separation, so the green selection border reads purely as a selection cue. |
| Default columns — iPhone | **3 (~128pt cell)** | Large enough to make obvious calls; **pinch-adjustable 2–5** (more on iPad). *(3 confirmed in the spike, #6 — [spike-findings](../plans/spike-findings.md).)* |
| Columns — iPad / regular width | adaptive `LazyVGrid` | Scales with available width; more columns. |
| Setup/list padding | system `Form`/`List` insets + generous section spacing | Notes-calm. |
| Min hit target | **≥44pt** | Every interactive element (HIG). |
| Quick-select badge | small glyph (~22pt) inside a **≥44pt** hit area | "Effectively the whole corner" — fast, doesn't mis-fire while scrolling. |
| Floating chrome | hosted in `safeAreaInset` / toolbar region | Never raw `glassEffect()` over arbitrary photos for must-read text. |

---

## 4. Shape & corner radius

- **Concentricity.** Nested rounded shapes share a center: inner radius = outer radius − inset. Match custom glass surfaces to their container's radius.
- **Continuous corners** (`RoundedRectangle(cornerRadius:style: .continuous)`) everywhere we round — the Apple superellipse, not a circular arc.
- **Grid cells: square, with a small ~6pt corner rounding + a ~3pt gutter** (Apple-Photos-style; **revised** from the initial edge-to-edge/no-rounding wall). The 1:1 square aspect is unchanged (spike-resolved); the rounding + gutter are the owner's on-device refinement. The gold check remains the affordance. *(Square vs aspect-ratio **resolved by the spike → square**; aspect dropped.)*
- **Glass tally + export region:** one continuous rounded-rect / capsule; radius set on the `GlassEffectContainer` shape, content radii derived concentrically.
- **Detail cards / sheets:** system default continuous radii.

---

## 5. Materials & Liquid Glass

**Chrome is glass, photos are content. One glass layer — never glass-on-glass.** (Full rationale in design-language §"Liquid Glass".)

- **Standard nav bars / toolbars / sheets:** adopt Liquid Glass for free on iOS 26 — lean on them, add no glass-API calls.
- **Review-grid chrome lives at the TOP, not a floating bottom bar** *(decided in Paper — validate in spike)*. The running tally is a **glanceable progress strip** under the large title; **Export is the nav's top-right action**; Select-mode count + Deselect sit in the same top region. **Why:** the bottom is the thumb/scroll/select zone — a floating bottom bar is in the way and invites accidental Export/Deselect taps. Keeping the constant gestures (scroll, select, drag) unobstructed and the occasional/deliberate actions (Export, Deselect) up top is the safer split. This also simplifies the glass story: the top region is a **standard nav bar**, so it gets Liquid Glass + the scroll-edge effect *for free* — no hand-rolled floating `GlassEffectContainer` needed for the tally.
- **Legibility over photos = the scroll-edge effect.** The standard top nav/toolbar gets it free (progressive blur/dim where content meets chrome). **Acceptance: the tally is legible over the brightest seeded thumbnail** (accessibility audit). *(If a custom glass surface is ever hand-rolled, group co-located elements into one `GlassEffectContainer` — never glass-on-glass.)*
- **Solid surfaces for dense text/legibility** — setup forms, recovery screens, empty/error states stay solid (`Color(.systemBackground)` / grouped), not glass.
- **Two enforced invariants:**
  - **No SDK-version availability gates / `.regularMaterial` version fallbacks** ("pure glass" — CI-checked, Phase 1).
  - **Every custom glass surface defines a Reduce-Transparency opaque appearance** (e.g. solid `Color(.secondarySystemBackground)` + `Color(.separator)` hairline). This is an *accessibility* axis — distinct from the version-fallback rule.

---

## 6. Selection & state encoding

**Redundant encoding — never color alone** (HIG; accessible in grayscale).

- **Selected cell** *(resolved in Paper, provisional — fine-tune later)* = three layers: a **gold (Cloudberry) `checkmark.circle.fill`** badge (top-trailing) as the primary affordance · a **2px green (`--color-secondary-dark`) inset border** hugging the cell's rounded edge (marks the selected cell; with the ~3pt gutter now separating cells, this reads purely as selection) · a **subtle dim (~18% scrim)**. The *check + dim* satisfy the never-color-alone rule; the green border is a quiet structural accent, the **gold check carries the contrast** on any photo (incl. green/foliage, where a green check alone would vanish).
- **Why gold check, green border:** a green *check* blends on green photos; warm gold pops universally. The green *border* is narrow enough to read as structure, not chrome, and brings the brand colour into selection subtly. *(This is the deliberate exception to "green stays out of review-grid chrome" — see §1.)*
- **Unselected cell** = empty **`circle`** badge (low-emphasis, appears in select contexts) — the affordance is discoverable but quiet.
- **Hit area** for the badge = the whole corner, ≥44pt, independent of the glyph size.
- **Tap mapping — RESOLVED by the Phase 0 spike (#5): badge-select + cell-opens.** Tap the badge to select, tap the rest of the cell to open full-screen (the author's on-device verdict: "feels better"). This is the canonical mapping.
- **VoiceOver:** each cell exposes a label + a **custom "Select/Deselect" action**; sections expose a summary ("March, 31 photos, 4 selected").

---

## 7. Iconography (SF Symbols)

SF Symbols throughout, weight-matched to adjacent text, hierarchical/monochrome rendering. Starting set (refine as screens land):

| Purpose | Symbol |
|---|---|
| Selected / unselected badge | `checkmark.circle.fill` / `circle` |
| Add to album / export | `rectangle.stack.badge.plus` (or `photo.badge.plus`) |
| Date range | `calendar` |
| Filters | `line.3.horizontal.decrease.circle` |
| Source / library | `photo.on.rectangle.angled` |
| Target reached | `checkmark.seal.fill` (tally completion accent moment) |
| Clear selection | `xmark.circle` |
| Empty state | `photo.on.rectangle` |
| Error / permission | `exclamationmark.triangle` / `lock` |

**App icon** is a separate layered iOS 26 deliverable (Icon Composer; light/dark/clear/tinted) scheduled for Phase 3 — out of scope for the styleguide artboard, noted here for completeness.

---

## 8. Motion

- **Signature motion = the zoom transition.** `.navigationTransition(.zoom)` + `.matchedTransitionSource` keyed by `localIdentifier`: thumbnail expands to full-screen and animates back to its source cell. Physical, quick, never showy. Lean on the system duration.
- **Selection feedback = instant** (no animation) **+ light haptic** (`.sensoryFeedback(.selection, ...)`). Tap latency is decoupled from durability (selection is an in-memory `Set`).
- **Progressive imagery, not spinners:** instant placeholder/thumbnail → sharpen to full-res. No blocking full-screen spinner anywhere in the hierarchy.
- **Reduce Motion:** the zoom substitutes a **cross-fade**; incidental animation is removed. Designed in, verified — not patched.
- **AX tally reflow** (from §2): at accessibility Dynamic-Type sizes the tally drops to total-only or moves onto a solid backing so dense numerals on glass never fall below contrast.

---

## 9. Accessibility (cross-cutting, designed-in)

The mechanizable floor — asserted in tests; the *feel* is human-validated (D22).

- **≥44pt** targets; **no color-only** state; **continuous-corner focus ring** legible over photos.
- **Dynamic Type** through AX sizes, with the tally reflow above.
- **VoiceOver:** cell labels + custom select action + **section grouping/summary** so a thousands-cell grid is navigable.
- **Reduce Motion** (cross-fade) and **Reduce Transparency** (opaque glass) fallbacks on every relevant surface.
- **Scroll-edge / contrast** guarantee for chrome over bright thumbnails (the tally-over-brightest-photo assertion).
- `performAccessibilityAudit()` per screen.

---

## 10. Component inventory → Paper styleguide artboard

The atoms/molecules to build first in Paper, each with its states (this is what we transcribe from the tokens above):

1. **Color swatches** — semantic roles + the chosen accent (light & dark).
2. **Type ramp** — every row from §2, at default and one AX size (showing the tally reflow).
3. **Spacing & grid** — the 8pt rhythm, ~3pt gutter, 3-column iPhone grid block.
4. **Grid cell** — default / selected (check + dim) / loading (placeholder→sharpen).
5. **Quick-select badge** — selected / unselected, with the ≥44pt hit area shown.
6. **Day-group header** — single-day and date-range variants with count.
7. **Tally + export glass region** — default / AX-reflow / Reduce-Transparency opaque, with scroll-edge over a bright photo.
8. **Select-mode contextual toolbar** — select-all-group / deselect / clear + live count.
9. **Full-screen viewer chrome** — in-place select affordance + swipe hint.
10. **Setup form rows** — date range, target count, filter toggles (Notes-calm).
11. **States** — empty / error / permission-recovery (solid surfaces).

---

## Open decisions (resolve in review / Paper)

- ~~**A — Accent color**~~ **Decided: Cloudberry / *lakka* (warm golden berry), `#D08A2A` / `#E8B05A`** (§1) — chosen after a three-board exploration in Paper (clay family · cool/neutral · berries). On-concept with the name (*poimi* = pick = berries).
- **Tally numerals** (§2): plain SF + `monospacedDigit` vs `design: .rounded` for the Oura-friendly tone — try both in Paper.
- **Selection treatment** (§6): exact "dim" recipe — scrim % vs inset border vs slight scale — pick what reads most unmistakably without color.
- **Light vs dark first** for the Paper exploration (the review grid arguably shines in **dark**, where photos pop; setup screens read calmer in light). Suggest building the grid in dark, setup in light.
- *(Spike-owned items — now **resolved** and reflected above: cell shape → **square** (§4/§6), tap mapping → **badge-select** (§6), default columns → **3 on iPhone** (§3). See [spike-findings.md](../plans/spike-findings.md).)*
