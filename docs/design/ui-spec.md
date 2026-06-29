# UI spec — the review screen

The first concrete UI spec, written with the make-or-break screen (#35) as it lands
("spike-then-document", D27). It records *what was built and why* for the review grid + its
chrome, so the design and the code can be checked against each other. Tokens (color, type,
spacing, materials) live in [styleguide.md](styleguide.md); the interaction rationale and the
Phase-0 evidence live in [design-language.md](design-language.md) and
[../plans/spike-findings.md](../plans/spike-findings.md). This documents the *resolved* surface,
not new decisions.

> **The picking interaction is the make-or-break of the app** — a two-tier triage: the grid for
> obvious calls, the full-screen viewer (#36) for borderline ones. The grid must make *most* calls
> possible without opening anything.

## Anatomy

```
┌─────────────────────────────────────────────┐
│                              Clear   ⤴ Export │  ← nav trailing actions
│  Best of 2025                                 │  ← large nav title (album name)
│  1,847 photos · Jan 2025 – Dec 2025           │  ┐ scroll-top header
│  147 / 200  ▓▓▓▓▓▓▓░░░░░░░░░░  73 left         │  ┘ (subtitle + full-width tally)
├─────────────────────────────────────────────┤
│  • Sat, Jul 5            · 24      Select all │  ← pinned day-group header
│  ┌────┬────┬────┐                              │
│  │ ▣✓ │  ◯ │  ◯ │   gapless square cells       │  ← gold check top-right
│  └────┴────┴────┘                              │
│  Mar 16 – Mar 18         · 3      Select all   │  ← merged quiet run
│  …                                            │
└─────────────────────────────────────────────┘
```

## Grid

- **`LazyVGrid` in a `ScrollView`**, one continuous chronological flow split into **adaptive
  day-groups** (Curation `DayGrouping`) with **pinned section headers**. Busy days stand alone;
  quiet days merge into a run. Grouping is computed **once** in `CandidateStore` when the fetch
  settles — never in a view `body` (guard: `check-no-grouping-in-views.sh`).
- **Square cells** (resolved by the spike — square scans fastest), **gapless** (0-pt gutter — a photo wall, styleguide §3 / Paper design).
- **Pinch-to-adjust density**, default **3 columns** on iPhone, clamped to **2–5** (compact) so the
  44pt badge never swallows the cell; iPad goes denser. Density change animates `.snappy`, gated off
  under Reduce Motion.
- **Scroll-driven prefetch**: the visible range ± a row margin feeds the thumbnail seam's caching
  window (generation-guarded so out-of-order actor updates can't cache a stale slice).

## Header

`• <title> · <count>   [Select all / Deselect all]`

- Title formatted from the group's `days` (`DayGroupHeader`): single day → "Sat, Jul 5"; merged run
  → "Mar 16 – Mar 18"; the undated bucket → "Undated".
- The busy-day marker is a **neutral** dot (gold is reserved for the interactive accent).
- `· count` is the **post-filter** reviewable count (no quota — D5).
- **Select all / Deselect all** toggles the whole group (one debounced flush).

## Selection (D9)

- **Badge-select** (resolved): tap the **cell** opens it full-screen; tap the **≥44pt badge**
  (**top-right**, Paper design) selects. Light **selection haptic** on each flip.
- **Three-layer redundant encoding** so state survives color-blindness + bright thumbnails:
  1. a **gold filled checkmark** badge (top-right) — *the affordance*,
  2. a **dim** overlay,
  3. a **~2px green inset border** — structural only (the one sanctioned green in grid chrome).
- Source of truth is the in-memory `Set` in `SelectionStore` (D15); cells + headers observe it
  directly, so a toggle re-renders only visible cells, never the whole grid.

## Top chrome

At the **top**, not a floating bottom bar (which would fight the scroll/select gestures). A
**large nav title** (the album name) + a **scroll-top header** beneath it (`ReviewHeader`):

- **Subtitle**: `<count> photos · <period>` (e.g. "1,847 photos · Jan 2025 – Dec 2025"). The period
  is the album's range; the exclusive end is stepped back a day so a 2025 album reads "… – Dec 2025".
- **Tally**: `picked / target` in `monospacedDigit` + a **full-width** progress bar + "`N left`"
  (gold; green at target; fill floored to a visible sliver once there's any pick). The orientation
  device. **AX reflow**: at accessibility text sizes the bar drops, numerals only (the dense
  bar-on-chrome is the likeliest Dynamic-Type contrast failure).
- The header scrolls away as you dive in; the large title collapses to the inline album name and
  **Export** stays in the nav bar. Day-group section headers pin.
- **Export** (nav top-right): the primary action; disabled until ≥1 photo is picked. Routes to #39.
- **Clear** (nav top-right, destructive): shown only when there is a selection. *(Per the Paper
  design, bulk Clear/Select-all ultimately move to the separate Select mode; kept here transitionally
  until that screen is built so there's no interim capability gap.)*

## Accessibility

- Each cell: one element, label "Photo, <day>", a selected trait, a **default action** (open) + a
  named **Select/Deselect** action.
- Each header: an `.isHeader` element with a live "<title>. N photos, M selected." summary.
- Reduce Motion (no density animation) and Reduce Transparency (the standard bar + `.bar` headers
  adapt for free — no custom glass to make opaque) are built in.

## Deferred (tracked)

- **Drag-to-multi-select** across cells — the badge-select already gives fast single-tap
  multi-select; the drag gesture (and its conflict-handling with scroll/pinch) is a follow-up.
- **`performAccessibilityAudit()` per screen** — needs a UI-test target; rides the E2E tier (#43).
- **The `.zoom` expand/return** pairing — the grid sets `matchedTransitionSource`; the paired
  destination + swipe-and-select land with the viewer (#36).
- **Windowed-by-index snapshot + D29 access-counting guard** (#47).
