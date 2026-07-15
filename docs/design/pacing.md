# Pacing & over-target — design note (#120)

**Status:** resolved design, ready for a follow-up build issue. No code lands with this note.
**Paper:** `4C4-0` "Pacing · Overview projection", `4EA-0` "Pacing · states reference" (page 1).
**Depends on / extends:** the shipped grid top bar (`ReviewTopBar` + `ProgressRing`, #167), the
Overview tally (`ReviewTally`) + coverage chart (`CoverageChart`/`ChartBucketing`), the pure domain
(`TargetProgress`), and the review's ordered candidate list + `SelectionStore` (the pick-frontier
denominator — no `DoneStore` dependency, see the math).

## The gap

Progress is modelled today as a one-way climb toward the target that **clamps on the far side**
(`TargetProgress`): `remaining = max(0, target - picked)` reads **"0 left"** whether you're exactly at
target or 40 over; `fraction = min(1, …)` pins full; the ring/bar just flips green at
`picked >= target`. So **overshoot is invisible**, and nothing couples picks-so-far to *how much of the
timeline you've actually reviewed* — the failure mode the product cares about: **"spent the whole
budget in January, three months to go."**

## Decision

Two coupled signals, both **orientation, never enforcement** (D5 — the human picks every photo; nothing
is auto-selected, no quota is enforced):

1. **Over-target honesty — everywhere.** Stop clamping. Show the true count (`212 / 200` + **`+12
   over`**) and a distinct **amber** treatment once past the target, in both the grid ring/count and the
   Overview tally bar. This is pure honesty (it just stops lying), so it carries no enforcement risk.
2. **Pacing projection — on the Overview only.** Couple picks to how far they reach through the album
   (the *pick frontier*) and project the final count: *"At this pace: ~320 · picks reach 30% · picking
   ahead."* This is the signal that catches *on-pace-to-overshoot* while you're still under target. It
   lives on the **Overview** — the "step back and assess" screen, beside the coverage chart — so the
   **grid stays clean** (just the honest ring).

**Explicitly deferred:** the **per-cluster budget** hint ("6 picked · ~4 suggested", from the advisory
`Target.suggestedPerSection`) is **out of scope** for this iteration — it's the element most likely to
read as an enforced quota (D5), and the aggregate projection covers the same "picking heavy" insight
more safely. Revisit only if the Overview projection proves too coarse in use.

## Placement

| Surface | What it gains |
|---|---|
| **Grid top bar** (`ReviewTopBar`, #167) | The count + `ProgressRing` **unclamp**: over target → amber ring + `+N over` by the count. **No projection here** (keep picking uncluttered). |
| **Overview tally** (`ReviewTally`) | Unclamps the same way: full gold fill to a **target tick**, an **amber cap** for the overage past it, and `+N over` replacing the clamped "0 left". |
| **Overview projection card** (new) | A gauge icon + **"At this pace: ~N"**, a mini target-vs-projected bar (gold to the target tick, amber past = the overshoot), and a subline **"Picks reach X% of the album · picking ahead."** Gated (below). |
| **Overview coverage chart** (`CoverageChart`) | The span up to your **pick frontier** is drawn full-strength; the rest dims — a "Picks reach here" marker ties the projection's *X%* to the timeline. |

### Follow-up — the estimate follows you (persistent projection)

The original "grid stays clean, projection Overview-only" split above left the **estimated final count
visible only at the top of the Overview**, where it scrolls away — so a curator loses the "heading to
overshoot" read exactly while picking (the grid) and while scanning the cluster list (the Overview
lower down). On the product owner's steer we now surface a **compact** projection everywhere pacing
matters, without bringing the full card's weight:

- A shared **`AlbumPaceReadout`** (`ReviewChrome`) draws the tally `147 / 200` (+ amber `+N over`), a
  small **`~N est.`** projection line (amber when ahead), and the `ProgressRing`. It reuses the exact
  `pickFrontierFraction` → `Pacing` math, so its estimate always agrees with the Overview card, and it
  is gated by the same confidence floor (nothing shown until the frontier is trustworthy).
- **Grid top bar** now carries `AlbumPaceReadout` on its trailing lane — the `~N est.` appears under
  the count as you pick. (Supersedes "No projection here" above; kept deliberately compact so picking
  stays uncluttered — one small line, not the card.)
- **Overview** gains a **pinned recap bar** (`AlbumOverviewView.recapBar`) that fades in once the hero
  header scrolls off (a `onScrollGeometryChange` reveal with hysteresis), keeping the tally + estimate
  in view down the whole cluster index. The full **projection card** + coverage chart stay in the hero
  header as the detailed "step back and assess" read.

## Visual language

- **Gold** (`--color-accent`, tan `#E8B05A`) — climbing, under target (unchanged).
- **Green** (`--color-secondary`, `#7DA164`) — **reached exactly** (`picked == target`): a "bullseye"
  moment. (Distinct from the completion/export green, which means the *album* is finished.)
- **Amber — NEW token** (`--color-warning`, proposed `#FF9500` / dark `#FF9F0A`, iOS system orange) —
  **over target / ahead of pace**. A *heads-up*, never a red error, never blocking. Chosen so it's
  clearly distinguishable from the desaturated tan-gold accent (they co-appear on the Overview: gold
  chart bars + amber projection). **Add `--color-warning` to `Assets.xcassets` + styleguide.md.**

Ring color rule (deterministic): `picked < target` → gold arc · `picked == target` → green full ·
`picked > target` → amber full + `+N over`.

## The math — a pure `Curation` addition (D14/D21, unit-tested)

Keep `TargetProgress.remaining`/`fraction` clamped (the arc still wants `0…1`); **add** the unclamped
truth, and a separate projection type. The view maps these to color/copy — the domain stays string-free.

```swift
// TargetProgress (extend):
public var overage: Int { max(0, picked - target) }     // unclamped overshoot; 0 at/under
public var isOver: Bool { target > 0 && picked > target }

/// How far your picks reach through the album: (index of the chronologically-latest picked
/// candidate + 1) / total candidates — the "pick frontier". 0 when nothing is picked. `orderedIDs`
/// is the review's chronological candidate list (oldest → newest). Pure + testable.
public func pickFrontierFraction(orderedIDs: [String], selected: Set<String>) -> Double {
    guard !orderedIDs.isEmpty,
          let last = orderedIDs.lastIndex(where: selected.contains) else { return 0 }
    return Double(last + 1) / Double(orderedIDs.count)
}

// New — the projection. Orientation only; nil until the frontier is far enough to be honest.
public struct Pacing: Sendable, Equatable {
    public let picked: Int       // total picks (all are ≤ the frontier by definition)
    public let frontier: Double  // pickFrontierFraction, 0…1 (the denominator)
    public let target: Int

    public static let confidenceFloor = 0.15   // below this, the projection is noise → hide

    /// Final-count projection if the current pick density holds across the rest of the album.
    public var projectedTotal: Int? {
        guard target > 0, frontier >= Self.confidenceFloor else { return nil }
        return Int((Double(picked) / frontier).rounded())
    }
    /// Pace vs target with a ±10% dead-band, so small deviations read "on pace".
    public var pace: Pace? {
        guard let p = projectedTotal, target > 0 else { return nil }
        let r = Double(p) / Double(target)
        return r > 1.10 ? .ahead : (r < 0.90 ? .behind : .onPace)
    }
}
public enum Pace: Sendable { case onPace, ahead, behind }
```

**The denominator (decided): the pick frontier** = the chronological position of your
**latest-dated picked photo** in the ordered candidate list. Since curation runs oldest → newest, your
newest pick marks how far you've committed. It's **guaranteed to exist the moment you pick anything**
(nil only at zero picks — where a projection is meaningless anyway), so it needs **no mark-done**
dependency. The **numerator is simply total `picked`**: every pick is at or before the frontier by
definition, so there's no "picks among reviewed" bookkeeping — this is *simpler* than a done-based
denominator, not just more available.

- **Confidence gate:** no projection until `frontier >= 0.15`. Early on, "picked 8, frontier 4% → ~200"
  is noise; the card simply doesn't appear yet.
- **Jump-ahead degrades gracefully.** The paged model lets you swipe far ahead / drill into a late
  cluster; a lone far pick pushes the frontier high, so the projection collapses toward "≈ what you've
  picked" and the card goes **quiet**. It **under-warns, never false-alarms** — the safe failure for a
  non-enforcing cue (a missed nudge beats crying wolf, D5). A **future** conservative refinement: let
  done-coverage (`CompletionStats.markedDone / total`) pull the frontier *back* when it's smaller,
  catching the jump-ahead user who does mark done — deferred, not v1.
- **Copy by pace:** `ahead` → amber "picking ahead of pace"; `onPace` → neutral "on pace for ~N";
  `behind` → neutral "on pace for ~N — you have room". Amber tone **only** for `ahead`.

**Unit tests (the build issue must ship):** `pickFrontierFraction` (no picks → 0; lone last pick → 1;
mid-list latest pick → correct fraction; unknown ids ignored); overshoot (`overage`/`isOver`,
`210/200`); `target == 0` → `projectedTotal`/`pace` nil; frontier below floor → nil; the
`onPace`/`ahead`/`behind` bands incl. the 0.90 / 1.10 boundaries; the floor boundary (0.15 → shown).

## Tone & guardrails (D5 — non-negotiable)

- **Surface, never enforce.** No auto-deselect, no blocking, no modal nag. The projection is a line you
  can ignore; the count going amber changes nothing about what you can pick.
- **Amber = heads-up, not error.** Never the destructive red. "Ahead of pace" is information, not a scold.
- **Honest, not precise.** "~N" (rounded, tilde) + hidden below the confidence floor — never imply a
  false exactness from thin coverage.
- The target stays **soft** (D5): going over is a legitimate outcome the UI now *reflects*, not prevents.

## Open considerations (for the build issue / future)

- **Jump-ahead under-reads the frontier** (see the denominator section): picking in a far cluster before
  the earlier ones pushes the frontier high → the projection goes quiet. Graceful (never false-alarms).
  The deferred done-coverage floor is the robustness fix if this proves common in use.
- **`--color-warning` token** must land in `Assets.xcassets` + styleguide.md before the build, with a
  Reduce-Transparency-safe treatment on the glass surfaces (the grid ring/count sit on `ReviewTopBar`'s
  glass; the amber must keep contrast under RT's solid fallback).
- **a11y:** the over-target count reads "…, N over target"; the projection card is one combined element
  ("At this pace, about N photos, ahead of pace" / "on pace"), the mini-bar decorative + hidden.
- **iPad:** both surfaces already live in the same views; no separate layout — the projection card flows
  in the Overview header, which is shared across size classes.
