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

## Anatomy (accordion — D35)

The grid is an **accordion**: exactly one day-group cluster is open (its full photo grid) at a time;
every other cluster is a collapsed peek. "Done" is its own state (a green seal badge), set by a
**"Mark as done" button at the end of an open cluster** — it does NOT drive the collapse.

```
┌─────────────────────────────────────────────┐
│                              Clear   ⤴ Export │  ← nav trailing actions (nav TITLE blanked)
│  Best of 2025                                 │  ┐ pinned header (ReviewHeader):
│  1,847 photos · Jan 2025 – Dec 2025           │  │ BOLD album title + subtitle
│  147 / 200  ▓▓▓▓▓▓▓░░░░░░░░░░  73 left         │  ┘ + full-width tally
├─────────────────────────────────────────────┤
│ › Mar 16 – Mar 18   2 of 3 kept  ✓            │  ← collapsed cluster (chevron ›, done seal ✓)
│   ▣ ▣ ▣ ▣ ▣ ▣  (width-filled peek thumbs)      │     tap header/peek to open
│ ⌄ Sat, Jul 5            · 24      Select all   │  ← OPEN cluster (chevron ⌄)
│  ┌────┬────┬────┐                              │
│  │ ▣✓ │  ◯ │  ◯ │   square cells · ~3pt gap    │  ← gold check top-right
│  └────┴────┴────┘                              │
│              [ Mark as done ]                  │  ← end-of-cluster button → collapse + advance
│ › Jun 2 – Jun 9     0 of 18 kept               │  ← next collapsed cluster
└─────────────────────────────────────────────┘
```

## Grid

- **`LazyVGrid` in a `ScrollView`**, one continuous chronological flow split into **adaptive
  day-groups** (Curation `DayGrouping`) with **pinned section headers**. Busy days stand alone;
  quiet days merge into a run. Grouping is computed **once** in `CandidateStore` when the fetch
  settles — never in a view `body` (guard: `check-no-grouping-in-views.sh`).
- **Square cells** (resolved by the spike — square scans fastest), with a **~3pt gutter + ~6pt corner rounding** (Apple-Photos-style; revised from the initial gapless wall — styleguide §3/§4).
- **Pinch-to-adjust density**, default **3 columns** on iPhone, clamped to **2–5** (compact) so the
  44pt badge never swallows the cell; iPad goes denser. Density change animates `.snappy`, gated off
  under Reduce Motion.
- **Scroll-driven prefetch**: the visible range ± a row margin feeds the thumbnail seam's caching
  window (generation-guarded so out-of-order actor updates can't cache a stale slice).

## Header — the open/collapse control

`[chevron] <title> <count/kept>  [done ✓ badge]   [Select all]`

- Tapping the header (its left region) **opens** the cluster (auto-collapsing whoever was open) or,
  if it's already the open one, **collapses** it. A **disclosure chevron** (rotates down when open)
  is the affordance — it replaced the old busy-day dot.
- Title formatted from the group's `days` (`DayGroupHeader`): "Sat, Jul 5" / "Mar 16 – Mar 18" /
  "Undated".
- Count: **open** → `· <total>` (the cells show their own selection); **collapsed** → `<N> of <M>
  kept` (the pick result, since the cells aren't visible). Post-filter counts (no quota — D5).
- A **green seal badge** (`checkmark.seal.fill`, `brandGreen`) marks a done day at a glance, even
  collapsed — non-interactive; marking done is the footer button, not this badge.
- **Select all / Deselect all** shows only while the cluster is **open** (one debounced flush) — a
  *separate* button from the open-toggle, so a Select-all tap can't also collapse the cluster.

## Collapse & mark-as-done (accordion, D35)

- **One open at a time.** `expandedGroupID` (a single id) drives collapse — a cluster is collapsed
  iff it isn't the open one. Opening scrolls it to the top; initial open = the first **unreviewed**
  cluster (a soft resume). Only the open cluster loads full-res (400²) cells; collapsed clusters
  render a peek of small (56pt) thumbs — a real perf bound.
- **Peek** (collapsed footer): a width-filled strip of the day's photos (as many 56pt thumbs as
  fit — geometry-driven, no fixed cap). Done clusters lead with the kept photos and dim the rest;
  not-done clusters show a plain full-opacity chronological preview. No "Show all"/"+N" (the chevron
  + header count carry it).
- **"Mark as done"** (open footer, AFTER the photos — discoverable once you've reviewed the day): a
  centered brand-green button. It sets the day's done-state, collapses the cluster (seal badge), and
  **advances to the next unreviewed cluster** (success haptic). Done is DECOUPLED from collapse — a
  re-opened done cluster's button reads "Mark as not done".
- **Persistence**: day-granularity done-state (`DoneStore` → `CurationProject.doneDays`, D32(d));
  the `Completion.reopening` reconcile re-opens a done day that later gained a photo (D38).
- **Scroll**: iOS-18 `ScrollPosition`, one-shot `scrollTo` only — no maintained target, so a
  select-all / mark-done re-layout never snaps the grid (D36).

## Selection (D9)

- **Badge-select** (resolved): tap the **cell** opens it full-screen; tap the **≥44pt badge**
  (**top-right**, Paper design) selects. Light **selection haptic** on each flip.
- **Three-layer redundant encoding** so state survives color-blindness + bright thumbnails:
  1. a **gold circle with a dark check** (top-right) — *the affordance* (foreground on the gold
     accent is dark, not white, styleguide §1),
  2. a **dim** overlay,
  3. a **2px green inset border** (`brandGreen`) — structural. (Green is no longer *only* the
     selection hairline: it now also marks **done** — the header seal badge, the "Mark as done"
     button, and the at-target tally bar — the "green = kept / finished" vocabulary, styleguide §6.
     The border uses the same `brandGreen`, unified with those.)
- Source of truth is the in-memory `Set` in `SelectionStore` (D15); cells + headers observe it
  directly, so a toggle re-renders only visible cells, never the whole grid.

## Top chrome

At the **top**, not a floating bottom bar (which would fight the scroll/select gestures). The **nav
title is blanked** once the grid is up; the album name shows as a **bold title in the pinned
`ReviewHeader`** instead — a full large nav title fought the pinned header and drove the glass nav
backdrop into an observation feedback loop on device, so the identity title moved into the scroll-top
header. Beneath the title:

- **Subtitle**: `<count> photos · <period>` (e.g. "1,847 photos · Jan 2025 – Dec 2025"). The period
  is the album's range; the exclusive end is stepped back a day so a 2025 album reads "… – Dec 2025".
- **Tally**: `picked / target` in `monospacedDigit` + a **full-width** progress bar + "`N left`"
  (accent gold; **`brandGreen` at target**; fill floored to a visible sliver once there's any pick).
  The orientation device. **AX reflow**: at accessibility text sizes the bar drops, numerals only.
- The header is **pinned** (`.safeAreaInset(.top)`, **`.bar`** backing — a deliberate v1 interim; a
  full iOS-26 glassEffect scroll-edge is deferred as a device-iteration item) so the tally stays
  glanceable while scrolling. Day-group section headers pin too.
- **Export** (nav top-right): the primary action; disabled until ≥1 photo is picked. Routes to #39.
- **Clear** (nav top-right, destructive): shown only when there is a selection; **confirms before
  wiping** (a `confirmationDialog` — a stray tap used to clear every pick with no undo). *(Per the
  Paper design, bulk Clear/Select-all ultimately move to the separate Select mode; kept here
  transitionally until that screen is built.)*

## Accessibility

- Each cell: one element, label "Photo, <day>", a selected trait, a **default action** (open) + a
  named **Select/Deselect** action.
- Each header: an `.isHeader` container; its open-toggle is a **button** with a "<title>. N photos,
  M selected. [Done.]" label + an **Expanded/Collapsed value** + an open/collapse hint. Select-all is
  a separate child button. Marking a day done posts a "Marked done" announcement (the footer button
  is removed as it advances, so focus would otherwise be lost).
- **Dynamic Type**: the header reflows to a vertical stack at accessibility sizes (title wraps, never
  `minimumScaleFactor`); the tally drops its bar; the "Mark as done" button is a ≥44pt control.
- Reduce Motion (no collapse/density animation) and Reduce Transparency (the `.bar` headers adapt for
  free — no custom glass to make opaque) are built in.

## Deferred (tracked)

- **Drag-to-multi-select** across cells — the badge-select already gives fast single-tap
  multi-select; the drag gesture (and its conflict-handling with scroll/pinch) is a follow-up.
- **`performAccessibilityAudit()` per screen** — needs a UI-test target; rides the E2E tier (#43).
- **Glass scroll-edge chrome** — the header is `.bar` today; a real iOS-26 `glassEffect` scroll-edge
  is a device-iteration follow-up (no in-app precedent; can't verify the blur from a screenshot).
- **Windowed-by-index snapshot + D29 access-counting guard** (#47).

*(Resolved since first draft: the `.zoom` expand/return was tried and **dropped** for a plain push
after on-device jank, #84; the viewer + filmstrip shipped, #36.)*
