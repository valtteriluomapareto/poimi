# Paper design index

A map of the Poimi design file in **Paper** — every artboard, what it shows, and how it maps to
issues + the current build. This is the index for agents/humans to find a screen's design before
implementing it.

- **Index created:** 2026-06-29 · **updated:** 2026-06-30 (Overview #37 → 19P thumbnail rows, built).
  A snapshot — re-verify against Paper before relying on a specific detail; the file evolves.
- **File:** "Poimi" · page "Page 1" (`1-0`) · **33 artboards** (27 product screens + a 6-artboard
  v1.1 idea-backlog exploration cluster, below)
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

## The picking core — v1 (390×844)

| Screen | Node | Size | Content | Issue · build |
|---|---|---|---|---|
| **Review grid** ✓ | `129-0` | 390×844 | Large album title + metadata subtitle ("1,847 photos · Jan–Dec 2025") + **full-width tally** ("147/200 · 73 left") under it; **Export** top-right. **Gapless** square cells; selected = **gold check top-right + green border + dim**. Pinned day-group headers ("Sat 5 Jul · 53"). | #35 · **built + reconciled to this** |
| Review grid — notes ✓ | `Y4-0` | 460×422 | Annotated spec for the above (two-tier triage; day-groups; selection encoding; top chrome; select-mode is a sibling). | — |
| **Select mode** | `14C-0` | 390×844 | Active multi-select entered from the grid: a quick-select badge on **every** cell, **drag-to-multi-select**, per-day + whole-range Select-all, top toolbar (count + progress + Deselect-all). Same selection encoding. | #35 (deferred drag-select) · **not built** |
| Select mode — notes ✓ | `11J-0` | 460×443 | Annotated spec for Select mode. | — |
| **Photo viewer · swipe + select** | `WZ-0` | 390×844 | Full-bleed photo; top bar = back · "Sat 5 Jul / 12 of 53" · gold check toggle; bottom = live "148/200 picked" + a **filmstrip scrubber** (current enlarged, picked thumbs checked). Reached via the `.zoom` transition; returns to the same cell. | #36 · **built** (pt1 nav+zoom-in, pt2a pinch/pan/double-tap, pt2b day label + filmstrip; live drag-scrub + zoom-aware swipe-down deferred) |
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
| Overview · thumbnail rows | `19P-0` | Horizontal thumbnail rows per group. |
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
| Mark as done · sections | `26X-0` | Marking day-groups done + resume affordance. | #38 · not built |
| Completion · year is ready | `2DN-0` | The album-complete / export-success moment. | #39 · not built |
| Album settings | `2F1-0` | Per-album settings (958 tall). | #41 · not built |
| State · scanning (long fetch) | `2HZ-0` | The long-scan indicator state. | #34 · built (`ScanningView` scanning phase) |
| State · empty range | `2JE-0` | Empty/no-photos-in-range state. | #40 · built minimally (`.empty` in `ScanningView`) |

## Idea backlog (v1.1) — Paper explorations (390×844)

Visual explorations of the §15 idea backlog ([../plans/preprocessing-and-caching.md](../plans/preprocessing-and-caching.md) §15) — **v1.1, location-subsystem, additive over the date day-groups; not v1, not committed.** Built 2026-06-29 in a cluster below the product screens.

| Exploration | Node | Status | Notes |
|---|---|---|---|
| ① Trip tints · A solid + rail | `2KD-0` | exploration, **no winner** | Header-anchored solid tint + left rail over the date grid. |
| ① Trip tints · B gradient | `2MO-0` | exploration | Same, but the tint fades (gradient band + headers). |
| ① Trip tints · C liquid glass | `2OZ-0` | exploration | Frosted pill floating over the photos. |
| ① Trip tints · D vertical gradient | `2RA-0` | exploration | Ambient top-to-bottom gradient that morphs between clusters; no strips. (Tints the photos — the §15 trade-off.) |
| ② Verbal trip summary | `2TE-0` | **liked** | Deterministic caption ("Mostly at home, with stops in …") under the album identity — template voice, not LLM. |
| ③ Collapse done runs | `2VR-0` | **direction agreed** | Done clusters collapse to a dimmed ✓ row + per-cluster location summary + thumb peek + "Show all"; the open cluster keeps its full grid. **Mark-as-done** (the done-circle, matching `26X-0`) is the collapse trigger. Re-scoped per §15: only *done* runs collapse, never the unreviewed. |

Caveat: ① found no good-enough treatment (tinting a gapless photo grid recolors the photos being judged); ② and ③ are the keepers. None are v1 commitments — they inform the v1.1 location work.

## Reconciliation status

The **Review grid** (`129-0`) was reconciled in #35-part-4 (this branch): large title + subtitle +
full-width tally header, gold check top-right, gapless cells, green border. The **Photo viewer**
(`WZ-0`, #36) is built (nav + `.zoom`, pinch/pan/double-tap, day label + filmstrip scrubber). **Select
mode** (`14C-0`, with drag-to-multi-select) is the next build with a design ready. The **Overview**
direction (#37) is an open design choice among the six explorations.
