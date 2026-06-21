# Poimi — Product Plan

*Working brief. A power tool for hand-curating a year of photos into a printable album.*

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

## Core workflow

1. **Pick a source range.** Limit candidate photos by date interval (e.g. 1 Jan – 31 Dec 2025). A second book for a trip is just a shorter interval — same control.
2. **Work month by month**, with a *soft* per-month target shown as a guide ("March: 4 / 15") and a running tally. The real constraint is the book's total; per-month is scaffolding so no month gets forgotten. Allow overshoot and borrowing from thin months.
3. **Fast review.** Tap a thumbnail to expand it full-screen as an overlay, dismiss, and land back on the same scroll position with that photo still highlighted. Show the thumbnail instantly, sharpen to full-res as it loads (lazy/progressive, since a year of photos won't all be local).
4. **Common locations.** Let the user drop a pin with a radius and name it ("Summer house", "Home"), then bucket by it. Optionally auto-detect frequent clusters and *suggest* a name. Always keep a "no location" bucket (screenshots and some saved images carry no GPS).

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

3. **Exclude low-quality / non-camera images** — *heuristic, best-effort (label it as such).* Flag images with a suspiciously small file size for their resolution — i.e. low **bytes per megapixel** (e.g. a 12 MP photo at 300 KB ≈ 25 KB/MP). This catches recompressed re-saves from anywhere, including the manual-save WhatsApp stragglers the album filter misses.
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

## Open items / next steps

- Run the formal trademark-register check (PRH, EUIPO).
- Decide which filters ship in v1.
- Tune the quality-filter threshold (and decide flat vs format-aware).
- Define the review-screen interaction in detail (the make-or-break UX).
- Build.
