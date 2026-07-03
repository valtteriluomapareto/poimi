# UI spec — review screen + v1 surface

The concrete UI spec, written **spike-then-document** (D27): the make-or-break review screen (#35) in
full depth, then the rest of the resolved v1 surface (overview, viewer, export, settings, empty/error,
iPad) transcribed concisely under [Other resolved screens](#other-resolved-screens-v1). It records
*what was built and why* so the design and the code can be checked against each other. Tokens (color,
type, spacing, materials) live in [styleguide.md](styleguide.md); the interaction rationale and the
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

## Other resolved screens (v1)

The review grid is the make-or-break, so it gets the depth above. The rest of the v1 surface —
resolved + built this phase — is transcribed here concisely (anatomy · key interaction · a11y). Copy
is **"album", never "yearbook"**; there is no print/export-to-print anywhere.

- **Album overview (#37, cluster index — `3BL`).** The album's landing screen: a **coverage chart**
  (adaptive day/week/month buckets shaded gold by density) over a **month-sectioned list of day-cluster
  rows** (each: cover swatch · date · picked/total · done seal). Tapping a row **drills into the review
  grid** at that day. Nav trailing: a **sliders "adjustments" icon** (→ album settings) + **Export**.
  Chart/index built once in the store (never in `body`). a11y: rows are buttons labelled with the
  date + progress; the chart is decorative (`.accessibilityHidden`), the list carries the data.
- **Photo viewer (#36, Now-Playing card — `2ZC`).** A **`.sheet`**, not a path push — rises from the
  bottom, pull-down to dismiss (the grid stays mounted beneath, D10). A paged `TabView` over the
  review's ordered ids; per-photo day label; an in-place **select** control (gold check) + the running
  tally; a filmstrip. Reduce Motion → cross-fade.
- **Export + completion (#39 — `2DN`/`3KG`/`3LO`).** A terminal state machine: **working**
  ("Creating/Updating your album…", grace-gated spinner) → **completion** ("Your album is ready" /
  "Album updated" + a Picked/Reviewed/Kept stat card + "Find it in Photos, in the album …") or a
  **recoverable error** (per-error copy; notAuthorized→Open Settings; albumMissing→Create a new album;
  writeFailed→Try again). One-way copy into a native Photos album (create-or-find + dupe-guard, D31);
  a partial first export notes "N couldn't be added". No nav chrome mid-write (no half state).
- **Album settings (#41 — `2F1`).** Per-album grouped `Form`: **Name**, **Period** (from/to, re-scans
  next review; picks outside the new range are kept), **Saves to** (Photos album destination + Aim-for
  stepper), **Exclude from source** (screenshots toggle + excluded albums), and a destructive **Reset
  picks / Delete album** card. Edits apply immediately; durable save + live-tally re-sync on leave.
  Reset/Delete reconcile the live stores; delete never touches the Photos album/originals (D31).
- **App settings (#42-adjacent — `3N9`).** App-**wide**, distinct from album settings (reached by a
  **cog** on the albums home; album settings uses the sliders icon so the two never look alike):
  **Access** (Photos access status + Settings deep-link) + **About** (Version / License AGPL-3.0 /
  Source → GitHub). Thin (no stores).
- **Empty + error states (#40 — `2JE`).** Never a dead-end. The scan's **empty** state is actionable
  and reason-specific — *no photos in range* → **Change range**; *everything excluded* → **Review
  exclusions** + Change range (→ album settings). The **failure** state distinguishes a transient load
  error (**Try again**) from **access revoked mid-session** (re-reads auth → routes to the recovery
  screen, §10). Shared views used by both the grid + overview.
- **iPad split-view (#42 — `3QT`).** Regular width = a **2-column `NavigationSplitView`**: sidebar
  (album library, open album highlighted) + a detail column hosting the album's own stack (overview →
  grid → export). The photo viewer stays a sheet over the detail (no 3rd column). The grid's column
  count derives from the detail width (dense on iPad, reflows on Split View / Stage Manager). Compact
  (iPhone) stays the single-column `NavigationStack`.

## Deferred (tracked)

- **Drag-to-multi-select** across cells — the badge-select already gives fast single-tap
  multi-select; the drag gesture (and its conflict-handling with scroll/pinch) is a follow-up
  (with **select-mode**, deferred from #35).
- **iPad input polish** — pointer/hover, keyboard shortcuts, trackpad drag-select, drag-and-drop (v1.1;
  the adaptive *layout* shipped in #42, the input-mode matrix is deferred).
- **`performAccessibilityAudit()` per screen** — the UI-test target exists after #43; wiring an audit
  call per screen into it is the next step (the E2E smoke lands first as the tripwire).
- **Glass scroll-edge chrome** — the header is `.bar` today; a real iOS-26 `glassEffect` scroll-edge
  is a device-iteration follow-up (no in-app precedent; can't verify the blur from a screenshot).
- **Windowed-by-index snapshot + D29 access-counting guard** (#47).

*(Resolved since first draft: the `.zoom` expand/return was tried and **dropped** for a plain push
after on-device jank, #84; the viewer + filmstrip shipped, #36.)*
