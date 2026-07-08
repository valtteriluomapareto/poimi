# Paper design index

A map of the Poimi design file in **Paper** — every artboard, what it shows, and how it maps to
issues + the current build. This is the index for agents/humans to find a screen's design before
implementing it.

- **Index created:** 2026-06-29 · **updated:** 2026-07-08 (**photo-viewer metadata (#127)** — `4FE-0` "Photo viewer · info panel": capture **time** joins the date line (`Sat 5 Jul · 14.32`, always-on), an **ⓘ at the photo's bottom-right** reveals an **in-card glass panel** (device · resolution+MP · file size) with **two-tier loading** (date/resolution instant; device/size stream in then cache, D18); the **Picked pill stays reachable** so metadata informs the pick. Photos-first default chrome unchanged. Also **pacing & over-target (#120)** — two design artboards resolving how to visualize picked-vs-target pacing without enforcement (D5): `4C4-0` "Pacing · Overview projection" (the primary surface — an Overview with an unclamped tally, a **projection card** "At this pace ~320" showing target-budget gold vs projected-overshoot amber, and a coverage chart whose *pick-frontier* span is tied to the projection's denominator) + `4EA-0` "Pacing · states reference" (the exact grid ring/count + Overview tally treatments across under=gold / reached=green / over=amber, plus the proposed `--color-warning` amber token). Backs a follow-up build issue; full spec in [pacing.md](pacing.md). Also earlier same day: **review-grid top redesign** — two sign-off variants sharing the same slimmed **progress line** top ("10 / 300" gold + thin gold bar + "290 left", replacing the heavy album title/metadata the shipped grid had drifted into): `464-0` "Review grid · slim top (solid)" puts a clean pinned **solid cluster header** below the progress line (gold pin + cluster name + "47 photos · 5 / 152" meta on the leading lane; done seal + a compact **select-all icon** — was a wide "Valitse kaikki" text pill — trailing); `48B-0` "Review grid · glass pills" instead floats **aligned Liquid-Glass pills** over the first photo row (a "5 / 152" position pill + a cluster-name pill [gold pin + name + green done ✓] on the leading lane, a select-all glass icon trailing — all one height, vertically centred, even gaps, fixing the shipped grid's *misaligned* floating pills); `4AB-0` "Review grid · header + ring" (**current direction**) splits it differently on the user's steer — **cluster identity moves into a solid top bar** (back chevron + gold pin + cluster name + "47 kuvaa" count on the leading lane; a **compact circular progress ring** with "147 / 300" picked/total on the trailing lane, replacing the linear bar) and **only the per-page controls float as glass pills over the grid** (a "3 / 12" page-number pill leading + a select-all glass icon trailing). Open question: `4AB-0` has **no Export/Vie affordance** in the grid top (export would move to the Overview) — pending user confirmation. Awaiting final sign-off → then rebuild the grid top. Earlier 2026-07-06 (**location layer** — two signed-off concepts in the picking core: `3ZP-0` "Overview · trips & places" + `43P-0` "Cluster page · trip header" — trip/visit clusters gain a duration-driven **location sentence** (pin + "Week in X" / "Weekend in Y" / "Visit to Z"), interleaved with the existing date clusters; the grid header carries the same sentence + "Mark trip done". Backs #129/#130. Also **app icon** — new **Icon design** page `2-0`: v1 mark (gold square on green field) shipped as the app icon + a v2 "chosen from many" exploration; see the App icon section. Earlier 2026-07-03: **paged-clusters v2 exploration** — new
  `3T6-0` "Overview · cluster strips (v2)" + `3VM-0` "Cluster page · paged (v2)": revisiting the paged
  model (`36R`/`39D`) to replace the accordion's collapse/open jumpiness — the Overview keeps the shipped
  borderless style but previews each cluster with a scrollable evenly-sampled thumbnail strip; the grid
  becomes one cluster with sideways paging. Open Q on the single cover thumb. Earlier 2026-07-03: **#42 iPad split-view** — new `3QT-0` "iPad ·
  split view": the 2-column layout (sidebar album-library + detail review-grid, 6-wide) signed off +
  built. Earlier 2026-07-02: **#40 empty/error hardening** — `2JE-0`
  built as the actionable empty state (`ReviewEmptyView`); the scan's empty/failure states now
  distinguish reasons + are always recoverable. **app-level settings** — new `3N9-0` "App
  settings" (Photos access + About: version / license / source), built as `AppSettingsView`, reached
  from the albums-home **cog** (the per-album Overview uses a **sliders** icon). **#41 album settings**
  — `2F1-0` built as `AlbumSettingsView`, per-album only; its **"App"** section (Photos access /
  About) moved to `3N9-0`. **#39 export + completion** — reworked
  `2DN-0` (system background, no emblem, dropped "Open in Photos" — no public deep-link API) + new
  export states **working** `3KG-0`, **error** `3LO-0`, **re-export** `3J8-0`; the **cluster-index
  Overview** `3BL-0` shipped as the built Overview (#103). Earlier 2026-07-01: added the **Now-Playing viewer** `2ZC-0`
  and **Liquid Glass** polish mocks **Overview** `30R-0` + **Review grid** `34O-0` — the glass work
  shipped in PRs #98/#99; plus a **paged-clusters concept** exploration — **Clusters index** `36R-0`
  + **Cluster grid page** `39D-0` — and the review-grid **code-led accordion**, #89 merged. A
  snapshot — re-verify against Paper before relying on a specific detail; the file evolves.
  > **Code-led screens:** the review grid evolved past its Paper design during device testing (the
  > accordion, below). Where a shipped screen diverges from its artboard, this index — not Paper — is
  > the source of truth for *what shipped*; the artboard records the original design intent.
- **File:** "Poimi" · page "Page 1" (`1-0`) · **46 artboards** (37 product screens + 2 pacing design
  artboards + a 6-artboard v1.1 idea-backlog exploration cluster, below)
- **URL:** https://app.paper.design/file/01KVSFMATJM712ABNQ5D0YDR1T/1-0
- **File ID:** `01KVSFMATJM712ABNQ5D0YDR1T`
- **How to open a screen:** the **node ID** below is the canonical handle — `open_file` (Paper MCP)
  accepts a node ID or URL; or browse the file at the URL above. A per-artboard deep link follows the
  page-URL pattern — `https://app.paper.design/file/01KVSFMATJM712ABNQ5D0YDR1T/<nodeID>` (e.g.
  `…/129-0` for the Review grid). Always `get_guide` → `get_basic_info` first in a fresh session (the
  Paper MCP can disconnect; reconnect via `/mcp`).
- ✓ = artboard whose content I inspected directly; others are summarized from the artboard name +
  the project's screen inventory and should be eyeballed before building.

> **Copy caveat (load-bearing):** several artboards use the word **"Yearbook"/"yearbook"** ("2025
> Yearbook", "Project list · Yearbooks", "New yearbook"). The product **banned that term** — the
> output is an **"album"** (see CLAUDE.md / the no-yearbook decision). Implement the design's
> *layout + interaction*, but use **"album"** copy. The design predates the terminology decision.

## Design tokens (from the file) ✓

Inter type; iOS-semantic color set. Accent **Cloudberry gold** `--color-accent #D08A2A` (dark
`#E8B05A`, on-accent `#1C1C1E`); secondary **green** `--color-secondary #3F5E37`; destructive
`#FF3B30`. Type scale caption 12 → large-title 34; spacing hair 2 → 2xl 48, touch 44; radii sm 8 →
full 999. The repo's Asset Catalog + styleguide.md mirror these.

## Foundations (wide canvases, not phone screens)

| Screen | Node | Size | Content |
|---|---|---|---|
| Styleguide ✓ | `2-0` | 1200×4561 | The token + component reference: color roles, type ramp, spacing, selection encoding, materials. Source of `docs/design/styleguide.md`. |
| Accent exploration | `D8-0` | 1000×670 | Early accent direction studies (warm clay family). |
| Accent — beyond Clay | `FG-0` | 1210×674 | Accent alternatives beyond the clay instinct. |
| Accent — berries (poimi!) | `I9-0` | 1210×661 | The berry set (lingonberry…cloudberry) — where the chosen Cloudberry gold came from ("poimi" = pick berries). |
| Brand palette | `KZ-0` | 1100×949 | The committed palette + roles. |

## App icon — the mark (page `2-0` "Icon design", 1024×1024)

> A **separate page** (`2-0`) from the screens above. Concept (#122): **gold = the one chosen, green = the field** — the app's core "pick one from many" gesture. The mark is a single shape, so it survives the tinted/monochrome appearance.

| Design | Node | Content | Status |
|---|---|---|---|
| **App icon · v1 (default)** ✓ | `3Z7-0` | Deep-green field (`--color-secondary`) + gold square (`--color-accent`), tilted 15° CCW, lifted with a soft shadow. | **chosen + shipped** (asset-catalog appearances) |
| **App icon · v1 (dark)** ✓ | `3Z9-0` | **Transparent** — just the brighter gold (`--color-accent-dark`) square; iOS supplies the **system dark ground** (like Music/Photos). | shipped (dark appearance) |
| **App icon · v1 (tinted / mono)** ✓ | `3ZB-0` | **Transparent** grayscale square only; iOS applies the user's tint over its ground. Single-shape mark holds when hue is stripped. | shipped (tinted appearance) |
| **App icon · v2 (chosen from many)** ✓ | `3ZD-0` | Iteration: a quiet 3×3 grid of green cells (the "many") with the gold square lifted proud + tilted over the centre (the "one"). Degrades to v1 when small/mono. | exploration |

**Shipped:** v1 as light / dark / tinted **asset-catalog** icons (flat). The full iOS 26 **layered `.icon`** (Icon Composer, per-layer material + depth) remains the upgrade tracked in **#122**.

## The picking core — v1 (390×844)

| Screen | Node | Size | Content | Issue · build |
|---|---|---|---|---|
| **Review grid · slim top (solid)** ✓ | `464-0` | 390×844 | **Redesign variant A (awaiting sign-off, 2026-07-08).** De-clutters the shipped grid's top: drops the album title + "N kuvaa · period" subtitle + the *misaligned* floating over-photo pills. **Two zones:** (1) fixed **progress line** — "10 / 300" gold + thin gold bar + "290 left" — replacing album title/metadata (`Vie` + a `•••` overflow for Clear top-right); (2) a clean pinned **solid cluster header** — gold pin + cluster name ("Käynti kohteessa Nokia") + "47 kuvaa · 5 / 152" meta on the leading lane, done seal + **select-all icon** trailing. Photos unchanged (gapless 3-up, gold-check selection). | #35 (grid-top) · **design proposed (variant A)** |
| **Review grid · glass pills** ✓ | `48B-0` | 390×844 | **Redesign variant B (awaiting sign-off, 2026-07-08).** Same slimmed **progress line** top as `464-0`, but the cluster chrome becomes **aligned Liquid-Glass pills floating over the first photo row** (frosted translucent dark fill + hairline border): a small **"5 / 152" position pill** + a **cluster-name pill** (gold pin + "Käynti kohteessa Nokia" + green done ✓) on the leading lane, a **select-all glass icon** trailing — all one height, vertically centred, even gaps (fixes the shipped grid's weird pill alignment). More immersive (photos run edge-to-edge under the pills). Superseded by variant C after the user re-split the layout. | #35 (grid-top) · **design proposed (variant B)** |
| **Review grid · header + ring** ✓ | `4AB-0` | 390×844 | **Variant C — SHIPPED (#167).** Cluster identity in a solid top bar — back + gold pin + cluster name + "N photos" count + green done seal on the leading lane; a **compact circular progress ring** (gold arc; green at target) with "picked / target" trailing, *replacing the linear bar*. **Only per-page controls float as glass pills over the grid**: a "3 / 12" **page-number pill** (stacked-page glyph) leading + a **select-all glass icon** trailing. Export moved to the Overview; Clear → Settings "Reset picks". | #35/#167 · **built + merged** |
| **Pacing · Overview projection** ✓ | `4C4-0` | 390×844 | **Design for #120 (pacing/over-target).** The Overview gains an **unclamped tally** + a **projection card** — a gauge icon, "At this pace: ~320", a mini bar splitting target-budget (gold) from projected-overshoot (amber) at a target tick, and "Picks reach 30% of the album · picking ahead of pace"; the coverage chart draws the span up to the **pick frontier** full-strength (dim past it) with a "Picks so far" marker tying the *X%* to the timeline. The denominator is the **pick frontier** (chronological position of the latest-dated picked photo — always available, no mark-done needed), not done-coverage. Orientation, never enforcement (D5). Shown state: under target now, **projected to overshoot** (the January-overspend case). | #120 · **design proposed** (build issue to follow) |
| **Pacing · states reference** ✓ | `4EA-0` | 430×620 | **Spec sheet for #120.** The exact treatments the build needs: grid ring + count across **under=gold / reached=green / over=amber (+N over, unclamped)**, and the Overview tally's over-target bar (full gold to a target tick + amber overage cap, replacing "0 left"). Notes the proposed **`--color-warning`** amber token (`#FF9500`/`#FF9F0A`) — a heads-up tone distinct from tan-gold + green, never the destructive red. | #120 · **design proposed** |
| **Review grid** ✓ | `129-0` | 390×844 | Large album title + metadata subtitle ("1,847 photos · Jan–Dec 2025") + **full-width tally** ("147/200 · 73 left") under it; **Export** top-right. **Gapless** square cells; selected = **gold check top-right + green border + dim**. Pinned day-group headers ("Sat 5 Jul · 53"). | #35 · **built, then evolved (code-led)** → shipped as an **accordion** (one cluster open at a time; done decoupled → seal badge + end-of-cluster "Mark as done"; bold pinned-header title with the nav title blanked). See D35 + Reconciliation status. |
| **Review grid · Liquid Glass** ✓ | `34O-0` | 390×844 | **Polish mock (in review):** the grid carried toward the viewer's Liquid Glass language — frosted-glass pinned header + day-group headers (translucent + hairline, so photos refract through when pinned over a scroll; the real effect is the on-device `glassEffect` upgrade — subtle in a static mock), "album" copy ("Best of 2025", the "Yearbook" term dropped), and **Apple-Photos-style cells: a small (~3px) gap + small (~6px) corner rounding**, edge-to-edge 3-up — **revising** the spike's gapless/square decision (styleguide §3/§4/§6; update on sign-off). Gold-check/green-border selection retained. | #35 · **design proposed** |
| Review grid — notes ✓ | `Y4-0` | 460×422 | Annotated spec for the above (two-tier triage; day-groups; selection encoding; top chrome; select-mode is a sibling). | — |
| **iPad · split view** ✓ | `3QT-0` | 1194×834 | The regular-width **2-column** layout: sidebar (album library, selected album highlighted) + detail (the review grid at ~6 columns, tally + toolbar, day-group header, gold-check selection). Photo viewer stays a sheet (no 3rd column). | #42 · **built** (`AppRootView.splitView`; adaptive columns via `ReviewGridColumns`) |
| **Clusters · index (paged concept)** ✓ | `36R-0` | 390×844 | **Concept exploration (in review):** an alternative to the single-scroll accordion — a **two-level** model. This is Level 1: a scrollable list of *collapsed* cluster cards (day · count · done seal · N-kept · photo peek), the "map" of the whole album. Tapping a cluster drills into its grid page (`39D-0`). Solves "how do I see all clusters" when the grid becomes a paged view. | #35 · **concept** |
| **Cluster grid · page (paged concept)** ✓ | `39D-0` | 390×844 | **Concept exploration (in review):** Level 2 of the paged model — one cluster's photos fill a full page; **swipe sideways** to the adjacent cluster (page dots + a next-cluster edge peek signal it). Glass nav = ‹ back-to-index · day · "N / total" cluster position; "Mark day done" advances to the next page. Reuses the shipped gap+rounded cells + gold-check selection. | #35 · **concept** |
| **Overview · cluster strips (v2)** ✓ | `3T6-0` | 390×844 | **Concept (in review, 2026-07-03) — the paged direction, refreshed to the *shipped* app style.** The current cluster-index Overview (black, borderless, month headers, tally — **no gray cards**) with each cluster row previewed by a **scrollable, evenly-sampled thumbnail strip** (Apple-Music shelf: ~5 shown, edge-fade → "more") — "get the idea of the whole cluster" without opening it. Pairs with `3VM-0`. **Open Q:** keep the single cover thumb *alongside* the strip, or let the strip replace it (current mock). | #35 · **concept** |
| **Cluster page · paged (v2)** ✓ | `3VM-0` | 390×844 | **Concept (in review, 2026-07-03).** Refined `39D-0`: one cluster fills the page, **swipe sideways** between clusters (page dots + next-cluster edge peek), "1 / 12" position, "Mark day done" advances. The pitch: replace the shipped **accordion**'s collapse/open jumpiness with stable single-cluster paging, now that the Overview is a full cluster index. | #35 · **concept** |
| **Overview · trips & places** ✓ | `3ZP-0` | 390×844 | **Concept (signed off, 2026-07-06) — the v1.1 location layer.** The cluster-strips Overview (`3T6-0` style) where **trip/visit clusters** carry a **location sentence** instead of a bare date: a gold **pin** + "Week in Äkäslompolo" / "Weekend in Åland" / "Visit to Pori", with the date-range · photo-count as a subline; **date clusters** ("Sat 15 Feb · 24") stay unchanged for everything not a trip. Trips are the additive overlay (D33); labels are duration-driven (visit/weekend/week), home excluded. Backed by the `TripOverlay` + a name cache. | #129/#130 · **concept** |
| **Cluster page · trip header** ✓ | `43P-0` | 390×844 | **Concept (signed off, 2026-07-06).** The paged grid (`3VM-0`) with the same **location sentence in the top header** (gold pin + "Weekend in Åland" / "8–9 Nov · 208 photos · 172 kept" + "N / M" position); the done button becomes **"Mark trip done"** (a trip spans days). Date clusters keep "Mark day done". | #129/#130 · **concept** |
| **Select mode** | `14C-0` | 390×844 | Active multi-select entered from the grid: a quick-select badge on **every** cell, **drag-to-multi-select**, per-day + whole-range Select-all, top toolbar (count + progress + Deselect-all). Same selection encoding. | #35 (deferred drag-select) · **not built** |
| Select mode — notes ✓ | `11J-0` | 460×443 | Annotated spec for Select mode. | — |
| **Photo viewer · swipe + select** | `WZ-0` | 390×844 | *(Original v1 design.)* Full-bleed photo; top bar = back · "Sat 5 Jul / 12 of 53" · gold check toggle; bottom = live "148/200 picked" + a **filmstrip scrubber** (current enlarged, picked thumbs checked). Reached via the `.zoom` transition; returns to the same cell. | #36 · **built, then redesigned** → superseded by the Now-Playing card `2ZC-0` (below) |
| **Photo viewer · Now Playing** ✓ | `2ZC-0` | 390×844 | **Redesign (in review):** the viewer as an Apple-Music-"single-song" **modal card** — pull-down to dismiss (grabber). **Ambient wash** = a heavy blur of the current photo tinting the whole card; the **photo is the centred "art"** (large rounded, shadowed, in a black frame) with the controls in a band **beneath** it (never overlapping). Band = day + "N of M" (left) · gold tally (right); a big centred **Pick hero** capsule (glass "Pick" → prominent gold "Picked"); the **filmstrip** scrubber. | #36 · **built + shipped** (PR #98) |
| **Photo viewer · info panel** ✓ | `4FE-0` | 390×844 | **Design for #127 (per-photo metadata).** Adds capture time to the date line (`Sat 5 Jul · 14.32`, always-on) + an **ⓘ button at the photo's bottom-right** that reveals an **in-card glass panel** (not a nested sheet) with **device · resolution+MP · file size**. **Two-tier loading:** date/time + resolution are free (from `AssetRef`) and instant; device + size stream in async (row shows `— loading…`) then cache (D18). The **Picked pill stays reachable** above the panel (metadata helps you decide); close via ⓘ toggle / swipe. Photos-first default chrome unchanged. | #127 · **design proposed** |
| Photo viewer — notes ✓ | `YU-0` | 460×422 | Annotated spec for the viewer (open-to-decide is itself a multi-select path). | — |

## Overview explorations — choose one (#37, 390×844)

Six alternative treatments of the zoom-out overview level. **Chosen: `19P-0` (thumbnail rows)** — built
for #37 as the v1 Overview (month rows: name · "N picked · total" · a thumbnail strip, + a coverage
histogram). The four location-grouped treatments (`1DE`/`1H3`/`1LA`/`1PV`) need the v1.1 location
subsystem; the plan is to evolve `19P`'s strip into `1PV` (location-segmented thumbnail bar) when that
lands. (Names describe each treatment.)

| Screen | Node | Treatment |
|---|---|---|
| Overview · by month | `16A-0` | Month-grouped summary rows. |
| Overview · thumbnail rows | `19P-0` | Horizontal thumbnail rows per group. **Chosen + built (#37).** |
| **Overview · cluster index** ✓ | `3BL-0` | **Concept (in review) — 5-persona-panel recommendation.** Reframes the Overview from "months → drill in" to a complete, scannable **index of ALL day-clusters**: header (title · gold tally · bar) → a **per-cluster bar chart** (one bar per day-group, height ∝ photos, colour = state: green done / gold in-progress / grey untouched — the current Overview's histogram kept, but at cluster granularity, doing density + coverage at once) → a **dense vertical cluster list** with sticky month headers (thumb · day · "N picked · total" · green done-seal · chevron). Answers "see all clusters + what's left" without horizontal shelves; taps drill into the cluster grid. |
| **Overview · calendar heatmap** ✓ | `3ED-0` | **Concept (in review) — variant.** A year "skyline" heatmap: one cell per day-group, columns = months (height ∝ cluster count), tinted by state (green done / gold in-progress / grey untouched). Superb whole-year shape + coverage at a glance, but abstract — no per-cluster label/thumb and not directly actionable; best as a *companion* to the index, not the sole Overview. (Panel noted it mis-models adaptive clusters if done per-day.) |
| Cluster index — notes ✓ | `3IF-0` | Annotated spec for the cluster-index concept: **(1) cluster state** — the 3-state rule (done = marked done · in-progress = not-done + ≥1 pick · untouched = not-done + 0 picks), a pure derivation from picks + done (no view-tracking); **(2) defining a cluster** — the open decision to replace the static busy-day threshold (10) with a **dynamic** one, `clamp(photosPerActiveDay, 9, 100)`, incl. mean-vs-percentile, active-days-only, clamps, and "spike on the real library" (D27). |
| **Overview · Liquid Glass** ✓ | `30R-0` | **Polish mock (in review)** of `19P-0` toward the viewer's language: month rows become **elevated rounded cards** (dividers dropped), thumbnails grow into **larger rounded art cards**, each row gains a **`>` chevron** (tappable affordance), histogram label softened to sentence-case. Same dark palette + gold tally + histogram. |
| Overview · location bars | `1DE-0` | Location-grouped bars (ties to the v1.1 location subsystem). |
| Overview · sideways bars | `1H3-0` | Sideways/horizontal progress bars per group. |
| Overview · hybrid | `1LA-0` | A hybrid of the above. |
| Overview · photo bars | `1PV-0` | Photo-backed bars. |

## Onboarding & setup (390×844)

| Screen | Node | Content | Issue · build |
|---|---|---|---|
| Welcome · photo access | `1ZZ-0` | First-run intro + photo-access rationale/prompt. | #31 · built (`OnboardingView`) |
| Limited access · fallback | `29U-0` | The `.limited`/denied recovery path → Settings deep-link. | #31 · built (`AccessRecoveryView`) |
| Project list · Yearbooks | `21T-0` | The album library (status per album, +). **Copy says "Yearbooks" → use "albums".** | #32 · built (`AlbumsView`) |
| Project setup · New yearbook | `243-0` | New-album setup form (name/period/target/exclude/destination). **"yearbook" → "album".** | #33 · built (`NewAlbumSetupView`) |
| Album picker · excluded | `2B9-0` | The exclude-album multi-picker. | #33 · built (`AlbumPickerView`) |

## Lifecycle & states (390×844)

| Screen | Node | Content | Issue · build |
|---|---|---|---|
| Mark as done · sections | `26X-0` | Marking day-groups done + resume affordance. | #38 · **partial** — the done-state + *inline* mark-as-done shipped in the accordion grid (end-of-cluster button + seal badge + advance-to-next); the separate **sections-list / resume screen** here is not built (tracked by the new resume issue). |
| **Completion · year is ready** ✓ | `2DN-0` | The export-success moment: album name (gold caps) · "Your album is ready" · Picked/Reviewed/Kept stat card · **Back to albums**. On the system background (no emblem); "Open in Photos" dropped (no public deep-link to a specific album). | #39 · **built** |
| **Export · working** ✓ | `3KG-0` | The transient "Creating your album…" state — gold spinner + "Adding your N photos to <album>." No actions. | #39 · **built** |
| **Export · re-export** ✓ | `3J8-0` | The idempotent re-run: "Album updated · added N, now M" + the stat card + Back to albums. | #39 · **built** |
| **Export · error** ✓ | `3LO-0` | Recoverable failure (neutral dark, amber warning): "Couldn't create the album" + **Try again** · **Create a new album instead** (when a re-export's album was deleted) · Back to albums. | #39 · **built** |
| Album settings | `2F1-0` | Per-album settings (958 tall), titled **"Album settings"**: name / period / saves-to / reset+delete. | #41 · built (`AlbumSettingsView`); design's "App" section (Photos access, About) **omitted** — app-level, moved to `3N9-0` |
| App settings | `3N9-0` | App-level settings: **Access** (Photos access → Full/Limited/Off + Settings deep-link) + **About** (Version / License AGPL-3.0 / Source code → GitHub). Reached from the albums-home cog. | built (`AppSettingsView`); the "App" section relocated out of `2F1-0` |
| State · scanning (long fetch) | `2HZ-0` | The long-scan indicator state. | #34 · built (`ScanningView` scanning phase) |
| State · empty range | `2JE-0` | The actionable empty state: "Nothing to pick here" + range-aware message + **Change range** / **Review excluded albums** (both → album settings). | #40 · **built** (`ReviewEmptyView`, shared by `ScanningView` + Overview); reasons `.noPhotosInRange` / `.allExcluded` |

## Idea backlog (v1.1) — Paper explorations (390×844)

Visual explorations of the §15 idea backlog ([../plans/preprocessing-and-caching.md](../plans/preprocessing-and-caching.md) §15) — **v1.1, location-subsystem, additive over the date day-groups; not v1, not committed.** Built 2026-06-29 in a cluster below the product screens.

| Exploration | Node | Status | Notes |
|---|---|---|---|
| ① Trip tints · A solid + rail | `2KD-0` | exploration, **no winner** | Header-anchored solid tint + left rail over the date grid. |
| ① Trip tints · B gradient | `2MO-0` | exploration | Same, but the tint fades (gradient band + headers). |
| ① Trip tints · C liquid glass | `2OZ-0` | exploration | Frosted pill floating over the photos. |
| ① Trip tints · D vertical gradient | `2RA-0` | exploration | Ambient top-to-bottom gradient that morphs between clusters; no strips. (Tints the photos — the §15 trade-off.) |
| ② Verbal trip summary | `2TE-0` | **liked** | Deterministic caption ("Mostly at home, with stops in …") under the album identity — template voice, not LLM. |
| ③ Collapse done runs | `2VR-0` | **explored → superseded by the accordion (D35)** | Explored done-driven collapse: a done-circle trigger, dimmed ✓ header + "Show all"/"+N" peeks, location clusters. The shipped v1 grid **pivoted to an accordion** (D35, device-validated): one cluster open at a time, done **decoupled** from collapse (a seal badge + an end-of-cluster "Mark as done" button that advances to the next unreviewed), no "Show all", width-filled peeks, date day-groups. `DoneStore`/`Completion` still back it. The done-circle-drives-collapse trigger here is **superseded**; a Paper refresh is pending (grid is code-led for now). |

Caveat: ① found no good-enough treatment (tinting a gapless photo grid recolors the photos being judged); ② and ③ are the keepers. None are v1 commitments — they inform the v1.1 location work.

## Reconciliation status

The **picking core is built.** The **Review grid** (`129-0`, #35) shipped and then evolved: device
testing replaced `2VR-0`'s done-driven collapse with a **code-led accordion** (D35) — one cluster
open at a time, collapsed peeks, disclosure-chevron headers, an end-of-cluster "Mark as done" button
that advances to the next unreviewed cluster, done-state decoupled (green seal badge), a bold
pinned-header title with the nav title blanked. The **Photo viewer** (`WZ-0`, #36) is built (nav +
zoom, pinch/pan/double-tap, day label + filmstrip; the `.zoom` transition was dropped for a plain
push after on-device jank, #84). The **Overview** (#37) is built to **`19P-0`** (thumbnail rows +
coverage histogram). The one picking-core design still unbuilt is **Select mode / drag-to-multi-select**
(`14C-0`, deferred from #35) — flagged the top UX win by the HIG + UX expert reviews.
