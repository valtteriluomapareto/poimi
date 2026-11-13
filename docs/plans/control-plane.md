# Control plane — plan

**Status:** accepted (2026-11-12), reviewed by Architect, Tester and Pragmatism (§10); built in
slices A–E (#296–#300, epic #295). Recorded as decision **D39**. How to use it: the
`poimi-control` skill (`.claude/skills/poimi-control/SKILL.md`) and `Scripts/poimi.sh schema`.

**Goal.** Let an agent (or a script, or you) **put Poimi into any state, read that state as
data, drive it, and look at it** from the command line, with or without its UI. Everything is
DEBUG-only, simulator-only, and runs on the fake library.

---

## 1. Prior art and lessons

The "control plane" is a known pattern for making mobile apps verifiable by agents. Full
implementations run to 15k lines or more, mostly "break on purpose" machinery: fake clocks, gates
on every network stage, run generations with kill fences, crash-point sweeps, provenance digests.
The pieces that pay off **first** are cheap: actions that share the UI's handlers, a redacted
snapshot, `wait`, named fixtures, and a device run for screenshots. Navigation is the usual weak
spot; Poimi's `AppCoordinator` already holds it as data. On real-time devices, clock control and
"unreachable" waits can't be made honest.

## 2. The idea, distilled

> **Give the agent the app's state as data and the same actions as the user, make every
> claim checkable from the command line, and keep it out of the store build.**

1. **Named fixtures**: deterministic starting states, seeded through the app's own APIs.
2. **State as data**: a versioned, redacted snapshot. Aliases instead of ids, counts instead
   of text, plus the current route and sheet.
3. **The same handlers**: a control action calls the method a button calls. The control layer
   decodes, dispatches and projects, and never holds feature logic.
4. **`wait`, not sleep**: block on predicates over the snapshot. On failure, name every unmet
   path with expected and observed values.
5. **One core, several hosts**: in-process tests, the app on a simulator with its UI, and the
   app with no UI.
6. **Development-only, provably**: kept out of Release by `#if DEBUG` plus a guard.

## 3. What reviewing it against Poimi changed

The first draft assumed the stores already were the app's behaviour. They weren't: the album
session (activate → scan → reconcile → publish) and the export ran inside view `.task`s, in two
diverging copies; open/create/delete/reset were sequenced in views with two different orderings;
pending debounces weren't observable; and the hosts diverged (time zone, debounce, shared
`UserDefaults`). A control action with no view mounted would have scanned nothing and reported
`accepted`. So the order became: **reach and look first** (no actions), **then lift the album
session out of the views** (a product refactor), **then live actions**.

## 4. Slices

Each slice was useful on its own; the rule was to stop after any slice that isn't earning its keep.

- **A — Reach and look (#296).** Named fixtures (`ControlFixture`), the `-PoimiControl` launch with
  a fixture, a route and a viewer photo, the redacted `state.json` / `state-detail.json`, and
  `Scripts/poimi.sh launch | state | wait | shot | logs`.
- **B — The album session out of the views (#297).** `AlbumSession` (scan, review context, export),
  the `AlbumActions` façade (open / create / delete / reset / edit, one ordering each), observable
  pending flushes, and one `AppGraph.make` wiring for the app, the control launch and the tests.
- **C — Live actions and headless (#298).** `ControlHost` (actions = the user's controls, refusals,
  `seq`/`settledSeq`/`idle`), the strict decoder and `schema`, the in-app `wait`, the file mailbox,
  `-PoimiHeadless`, fixture ops (test levers), and in-process journeys.
- **D — UI state routes can't express (#299).** The Overview filter, the grid's current cluster, the
  viewer (`ViewerStore`) and the modals, each an action plus a snapshot path.
- **E — Break on purpose (#300).** The fake library's export gate (hold / release / fail),
  `relaunch` over the same data, new photos mid-session (#191 drift), and their journeys.

Not built ("later and optional"): converging the `DebugScreen` hosts on fixture + route; a binary
sentinel check (it would have to scan every Mach-O in the `.app`, including `Poimi.debug.dylib`); an
MCP wrapper around `poimi.sh`; XCUITest for real-tap wiring.

## 5. As built — decisions and deviations

What a reader can't get from the code or the skill:

- **Directories.** `Documents/control/` is per run: `state.json`, `state-detail.json` and the mailbox
  (`req-<n>.json` → `res-<n>.json`), cleared by every launch, relaunch included.
  `Application Support/control/` is what a relaunch continues: the control file store, the fake
  library's state (added photos, exported albums, created-album count), the run record (fixture +
  album aliases) and the timeline cache. A fixture launch wipes both, and so does a normal launch, which
  ends the run. A `-PoimiRelaunch` never wipes, even when refused; a run this build can't read (a
  versioned file it doesn't know, a store it can't open) is refused with `app.launchError`, never
  replaced by a fresh one.
- **An action is only what a user can do from what's on screen**, through that control's own handler.
  Elsewhere it's `refused(notShown)`; a name that matches nothing is `unknownAlias`; an unhydrated store
  is `invalidState` (never a silent `accepted`); a running export is `busy`; the UI's own idempotence
  guards are `noop`. What no control does is a fixture op (a lever), never an action.
- **Under a sheet or dialog, everything else is `notShown`** (on iPad too), except that sheet's own
  controls. A confirmation remembers its origin (album list or album settings), which decides which view
  shows it.
- **The export screen has no way out until it settles**: no back button (`nav.back` is `notShown`), and
  Back to albums (`nav.root`) only once it's `done` or `failed`. On iPad the sidebar stays live, and
  re-opening the album mid-export and saving again **joins** the run in flight, then catches the album up
  to the live picks.
- **`accepted` ≠ finished.** After every action, the host runs what the album screens on the path run when
  they appear (`AlbumSession.appear`, the views' own call), so a run without a UI does the same work.
  `idle` = every action settled, and no scan, naming, export (any album's) or fake thumbnail load. It
  does **not** wait for debounced flushes: under control the debounce is a day long, and the in-memory
  picks are the truth (D15).
- **D15 flush points:** leaving `.active`, a project switch, and an export (it records the picks it
  exported at once, so it flushes them first). **The loss window:** `simctl terminate` delivers no scene
  phase, so every pick since the last flush is lost on `relaunch` (measured in-process and on the
  simulator). In the shipping app it's the 2 s debounce before a kill that skips the scene phase.
- **Aliases.** Photos `a-NNNN` by capture date (D32) over the fixture's library; photos added mid-run get
  the next numbers. Albums `album-N`, monotonic, never reused in a run, kept by a relaunch. Days by
  `yyyy-mm-dd`. Never an id, a title or a place name in a state file.
- **Hosts.** UTC is pinned (`NSTimeZone.default` and `SIMCTL_CHILD_TZ`), the debounce is a day long,
  and What's New and the review prompt are pre-marked in a separate `UserDefaults` suite.
  `ControlEnvironment.makeRuntime` is the one wiring of a control run: the launch and the in-process
  harness both build through it (the tests choose an in-memory store, or a library wrapper of their own).
- **Bugs found on the way** (each fixed with a regression test): a one-day album held the next morning's
  photos (periods built on noon anchors, #299); deleting an album mid-scan trapped, and so did rows
  re-rendering a deleted album (#298); on iPad a second Save mid-export created a second Photos album,
  and an export left its picks to the debounce while recording them as exported (#300).

## 6. Snapshot (`state.json`)

The declared paths and their types are `poimi.sh schema` (`statePaths`). The rules:

- **Redaction**: no `localIdentifier`, no titles (length only), no place names, no coordinates.
- **Detail on demand**: per-day `{photos:[alias], picked, done}` only for the active album, in
  `state-detail.json`, so `state.json` stays small at `scale`.
- **Main-actor `@Observable` state only.** Actor state is reached through explicit main-actor counters
  (fake thumbnail loads, the export gate).
- **Explicit `null`**, never a missing key; `rev` bumps only when content changes; every reply is
  written after `state.json` caught up with it.

## 7. Invariants

- **Curation stays pure (D14/D21):** nothing goes in `Curation`.
- **D15:** selection goes through `SelectionStore`; `flush` is the existing `flushNow()`.
- **D30:** control code sits in `Control/`, every file whole-file `#if DEBUG`, enforced by
  `check-fake-release-isolation.sh`; a Release build carries none of its strings.
- **D31 / photos sacrosanct:** control mode is fake-only.
- **No heavy work in `body`:** the snapshot is built by a control-side observer, never from a view.
- **Localizable by default:** the plane has no user-facing strings.

## 8. Risks

- **State without looks.** Semantic checks miss layout bugs (#283, #274, #279, #232 would pass every
  predicate). Screenshots someone looks at, and device review, stay mandatory for screen changes.
- **A second copy of logic in the control layer.** If a view does something that isn't a store or
  façade call, move it into a store; don't re-implement it in `ControlHost`.
- **Maintenance tax.** Journeys are required only for changes touching two or more of: async
  scan/export, debounced persistence, relaunch, revoked access, multi-store coordination.
- **Flaky waits.** No fixed sleeps: `wait` is observation-driven with a real deadline.

## 9. Size

The first estimate was ~2.5–3.5k LOC through slice C. Measured over the whole stack (A–E, against
`main`, added/removed lines):

| Part | + | − |
|---|---:|---:|
| Control source (`App/PoimiApp/Control/`) | 4.2k | 0 |
| Control tests | 2.6k | 0 |
| Product refactors (session, façade, viewer store, views, fakes, project file) | 2.3k | 0.9k |
| Product tests | 1.4k | 0.1k |
| Scripts (`poimi.sh`, sim helpers, guards) | 0.6k | 0 |
| Docs (plan, skill, decisions) | 0.4k | 0 |

That's about twice the estimate. The overrun is mostly in two places: the strict decoding and schema
layer, and the machinery tests.

A slimming pass (2026-11-13) kept both, because removing either would weaken the tool:

- **The schema layer stays.** `wait` uses the declared paths to fail a typo at once instead of after
  the timeout. `poimi.sh schema` is how an agent discovers actions without the skill copying tables
  that would rot. The decoder and `schema` read the same declarations, so there's one list, not two.
- **Most machinery tests are distinct journeys or already table-driven.** The pass removed dead code,
  turned the predicate-operator checks into one table, moved the scattered review-fix tests into the
  suites they belong to, and shared the mailbox test helpers. No check was dropped. The saving is small,
  well short of the 400–500 lines first guessed.

Deliberately skipped: a fake clock (an explicit `flush` and a long debounce instead), network-stage
gates (there's no backend), run generations and kill fences (a `run` id is enough), a crash-point sweep
(only the D15 window is at risk, and it's accepted), provenance digests, and a call-coverage scanner.

## 10. Review record (2026-11-12)

Three independent reviewers (Architect, Tester, Pragmatism) reviewed the first draft and every slice.

- **On the draft.** The blocker was that the lifecycle and export were view-owned, so actions and
  headless runs couldn't be honest. That became slice B. Also adopted: isolation (defaults, time zone,
  review prompt), observable pending flushes, the alias rules, `wait` defined by observation (vacuous-wait
  detection was deferred), a file mailbox over a socket, and a shell script over a Swift CLI.
  Pragmatism's cuts were applied: no event ring, no JSON scenarios, no sentinel, no pager lift.
- **On the slices.** Each slice's review findings were fixed before merge. The bugs those reviews found
  are the ones listed in §5.
