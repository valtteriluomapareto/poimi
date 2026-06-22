# Poimi — Product Plan

*Working brief. A power tool for hand-curating a year of photos into a printable album.*

> Revised after the four-perspective plan review — see [plan-review-decisions.md](./plan-review-decisions.md) for the decisions referenced below as (D#).

---

## Concept

An iOS helper app that lets you go through a whole year (or any date range) of your photo library and **hand-pick** the best shots into a single album — efficiently, toward a target count. The output is a native Apple Photos album you can feed into any photo-book tool.

The key idea is that **the human picks every photo**. No algorithm chooses for you. The app's job is to make manual curation at scale fast and pleasant, and to keep you oriented (count, coverage, comparisons) while you decide.

## Target user

A parent making **one photo yearbook per year**, occasionally a second for a special trip.

## Positioning

- **Don't compete on grouping.** Apple Photos already auto-groups by People, Trips/Places, and Memories (including text-prompt collections). Rebuilding that adds nothing.
- **The market splits into two camps, and neither fits this user:** cleanup/declutter apps (swipe to *delete* junk) and photographer culling tools (pick keepers to push into Lightroom).
- **The wedge is additive curation toward a finished artifact** — assembling "the best 200 of 2025" for a printed book. The closest competitor, *Dewp*, leans on AI auto-selection; the opposite of this app.
- **One-line differentiator:** *you choose every photo, not an algorithm.*

---

## Access (read first — it gates everything)

The app needs **full photo-library access** and is built around it. Apple's PHPicker can't serve this product (no persistent identifiers, no date-range fetch, no album writes), so we request full access and justify it clearly. Two states are first-class, not edge cases (D6):

- **Limited Library access** silently hides most of the year and blocks album writes — so we detect `.limited`, explain why full access is needed, and deep-link to Settings (we hard-gate on full access rather than ship a crippled limited mode).
- **Denied** gets a clear recovery screen, never a blank grid.

A rationale screen precedes the system prompt, usage strings are specific, and the privacy stance — photos never leave the device, we store only `localIdentifier`s — is stated loudly (D8). Location uses the GPS already in each photo's EXIF, so **no separate location permission is requested** (D7).

## Core workflow

1. **Pick a source range.** Limit candidate photos by date interval (e.g. 1 Jan – 31 Dec 2025). A second book for a trip is just a shorter interval — same control.
2. **Work month by month**, with a *soft* per-month target shown in the month's section header ("March: 4 / 15"). The authoritative constraint is the running **total**; per-month is light scaffolding so no month gets forgotten (D5). Allow overshoot and borrowing from thin months.
3. **Fast review — selection must be fast at scale.** The grid carries a per-thumbnail **quick-select badge** and supports **drag-to-multi-select** (Photos-style); the full-screen view is for *inspection*, not the only way to pick (D9). Tap a thumbnail to expand it (a navigation destination using the zoom transition, D10), dismiss, and land back on the same scroll position with that photo still selected/highlighted. Show the thumbnail instantly, sharpen to full-res as it loads (lazy/progressive, since a year of photos won't all be local). Selected state uses redundant encoding (checkmark + dim, never colour alone).
4. **Long scans are a designed surface.** Fetching and any heavy scoring over a year — with iCloud-only originals pulled over the network — shows a determinate, cancelable progress count, and the cheap-filtered set is curatable *while* the heavy pass runs (D12).
5. **Common locations *(v1.1, deferred).*** Let the user drop a pin with a radius and name it ("Summer house", "Home"), then bucket by it. Optionally auto-detect frequent clusters and *suggest* a name. Always keep a "no location" bucket (screenshots and some saved images carry no GPS). Deferred from v1 — the month + total loop stands on its own (D4).

## Output

- **Just a native Apple Photos album** (e.g. "2025 Yearbook"). Every major photo-book tool can import from one, so this gives every print path for free with zero print-service integration.
- **Two books = two albums.** The album name is the only metadata that travels, so name it well.
- **Sorted by date (capture date, oldest first).** Date is the one ordering that's stable everywhere and survives handoff; book tools default to it anyway.
- **Don't build sequencing as a deliverable.** Manual album order is fragile and doesn't reliably carry to other tools — let the book tool own layout and order. Album *membership* (which photos) is rock-solid.
- **Re-run behaviour:** if the selection is refined and run again, update the existing album rather than creating "2025 Yearbook 2"; guard against duplicate adds.

---

## Optional source filters

All filters are opt-in.

1. **Exclude screenshots** — *exact.* iOS tags screenshots at the system level (the screenshot media subtype / Screenshots smart album), so this is a clean predicate. Easy win.

2. **Exclude images that belong to selected album(s)** — *exact.* A general primitive: let the user pick any album(s) to drop from the source pool. The **WhatsApp** album is the main use (WhatsApp's saved media lands there), but it also handles Downloads, memes, shared albums, etc. Implemented as a set difference on asset local identifiers — cheap, no false positives, and no hard-coding the string "WhatsApp."
   - *Caveat:* the WhatsApp album only exists/fills when WhatsApp's "Save to Camera Roll" auto-save is on. Manually-saved WhatsApp photos land in Recents, so this catches the auto-saved flood but can miss one-off manual saves.

3. **Exclude low-quality / non-camera images** — *heuristic, best-effort, **deferred past v1** (D3).* Flag images with a suspiciously small file size for their resolution — i.e. low **bytes per megapixel** (e.g. a 12 MP photo at 300 KB ≈ 25 KB/MP). This catches recompressed re-saves from anywhere, including the manual-save WhatsApp stragglers the album filter misses.
   - **Not on the v1 path.** Validate with a quick spike on real assets first; ship only if it actually discriminates. When it does ship, it is **off by default, labelled in plain language** ("Hide non-camera images: screenshots, saved memes, low-res copies"), and the excluded set is **inspectable** ("Hidden: 312 — review") — it must never silently lose a photo the user wanted (D11).
   - Pixel dimensions are free off the asset. Read the **original** recorded file size via the photo resource (the lightweight route is an undocumented `fileSize` key; the fully public route reads the resource data, which is heavier and may hit iCloud).
   - Reading the *recorded original* size sidesteps the "Optimize iPhone Storage" trap (otherwise good photos whose originals sit in iCloud would look tiny and get wrongly flagged).
   - HEIC is far more efficient than JPEG, so keep the threshold low or make it format-aware, to avoid flagging clean HEIC originals.
   - Cleaner framing of this whole filter: a single **"camera originals only"** toggle, which also keeps AirDropped full-res photos (they retain camera EXIF).

---

## Technical notes (PhotoKit)

- **No people-grouping in v1.** Apple gives third-party apps no access to its face/people recognition; matching it would mean running your own on-device face clustering (Vision framework). The plan is designed so this isn't needed.
- **What PhotoKit gives you cleanly:** creation/capture dates, GPS location, favorites, media subtypes, pixel dimensions, album creation and membership, and change tracking — all enough for the date/location/quality logic above.
- **iCloud / Optimize Storage:** read recorded original sizes (not the local cache) for the quality filter, and lazy-load images for previews, since not everything is on-device.

---

## Name

- **Poimi** — Finnish for "Pick!" The App Store name appears clear, with no photo-app collision and no obvious Finnish brand using it.
  - *Watch-outs:* it sits near the cluster of "POI" (points-of-interest) apps, so design around search/autocorrect noise (distinctive icon, strong subtitle). It's descriptive in Finnish, which can weaken trademark protection at home while staying strong/arbitrary abroad. A formal trademark-register check (PRH for Finland, EUIPO for the EU) is still required — App-Store-clear isn't register-clear. (This brief is not legal advice.)
- **Subtitle:** *"Hand-pick photos into an album"* — carries the search keywords (*photo*, *album*) plus the differentiator (*by hand*, not by algorithm), and quietly echoes the meaning of *Poimi*.

---

## v1 scope (post-review)

**On the critical path (D2):** date-range fetch → review grid with in-grid selection → running total toward target → export to a native album (create-or-find + dupe guard) → two exact filters: **exclude screenshots** and **exclude selected album(s)**.

**Deferred:** quality / camera-originals filter (spike then maybe, D3), location bucketing + named pins (v1.1, D4).

**Sequencing — spike first (D1):** before building anything durable, a throwaway slice run against a real year of photos answers the only questions that matter early — does hand-curating a year feel good, does scroll-position restore work, does the grid stay smooth over thousands of thumbnails. Build the machinery only after the loop proves itself.

## Open items / next steps

- Run the spike (D1) and decide whether the quality heuristic is worth building (D3).
- Run the formal trademark-register check (PRH, EUIPO).
- Settle the few items still open in the decisions log (limited-mode support, App Store keywords, within-overlay swipe).
- Define the review-screen interaction in detail post-spike, then capture it as a `docs/design/` UI spec (D27).
- Build.
