# Control plane — plan

**Status:** accepted (2026-11-12), reviewed by Architect, Tester and Pragmatism (§10). Being
built in slices A–E. Recorded as decision **D39**.

**Goal.** Let an agent (or a script, or you) **put Poimi into any state, read that state as
data, drive it, and look at it** from the command line, with or without its UI. Everything is
DEBUG-only, simulator-only, and runs on the fake library by default.

---

## 1. Prior art and lessons

The "control plane" is a known pattern for making mobile apps verifiable by agents. Full
implementations of it run to 15k lines or more, and in some apps reach half the size of the
app itself. Most of that weight is "break on purpose" machinery: fake clocks, gates on every
network stage, run generations with kill fences, crash-point sweeps, provenance digests. The
pieces that pay off **first** are cheap: actions that share the UI's handlers, a redacted
snapshot, `wait`, named fixtures, and a device run for screenshots. Navigation is the usual
weak spot, often missing or read-only. Poimi's `AppCoordinator` already holds navigation as
data. On real-time devices, clock control and "unreachable" waits can't be made honest.

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

The first draft assumed the stores were already the app's behaviour and the plane was "a
projection plus a dispatcher". **That's only half true.** All three reviewers' findings were
checked against the code:

- **The album session lives in views.** `selection.activate` and `doneStore.activate`, building
  the `CandidateStore`, `load`, `doneStore.reconcile` and publishing the review context to the
  coordinator all run inside view `.task`s. There are two copies, in
  `AlbumOverviewView.swift:112-129` and `ScanningView.swift:57-92`, and they already differ:
  `ScanningView` builds its store **without** `timelineCache`. `ExportStore` is view `@State`,
  run from `ExportView.task` (`ExportView.swift:132-141`). So `nav.openAlbum` with no view
  mounted scans nothing, and `selection.toggle` silently returns `false` (inactive store),
  which a control plane would report as `accepted`.
- **Several user flows are sequenced in views.** `AlbumsView` does open (`store.open` +
  `openProject`). Create validates and then navigates. Delete and reset each have two
  different deactivate → mutate → reactivate orderings (`AlbumsView` vs `AlbumSettingsView`).
  Settings edits write model fields directly.
- **Debounce state is unobservable.** `flushTask` is cleared only by `flushNow()`; after the
  debounce fires it stays non-nil (`SelectionStore.swift:146-155`). So "pending flush" can't be
  read today.
- **Hosts diverge.** `CandidateStore` defaults to `Calendar.current` while the tests pin UTC, so
  cluster shapes depend on the Mac's time zone. The debounce is 60 s in tests and 2 s in the
  app. What's New and the App Store review prompt read shared `UserDefaults` and would cover
  control runs.

So the plan is reordered. **First, get value with no action layer at all** (launch into a
state, dump the state, screenshot, and tap through the iOS Simulator MCP). **Then lift the
album session out of the views.** That is a product refactor, and it's what makes live actions
and "headless" honest. **Then add live actions.**

## 4. Slices

Each slice is useful on its own. **Stop after any slice that isn't earning its keep**: agents
should be using it in real tasks, and it should catch things existing tests miss.

### Slice A — Reach and look (no wire, no actions) · ~0.8–1.2k LOC + script

The aim: an agent gets to any reachable screen, in a known state, in one command, can read
that state as JSON, and can screenshot it.

- **`ControlFixture`** (`App/PoimiApp/Control/`, `#if DEBUG`), one enum of named starting
  states shared by three callers: launch, the `DebugScreen` hosts, and the integration tests.
  Each seeds a `FakePhotoLibrary` and the SwiftData store through the public store APIs.
  `DebugShellView.seedSampleAlbums` moves here. Starting set: `fresh` (`.notDetermined`),
  `denied`, `empty-library`, `one-album`, `four-statuses`, `mid-review` (picks + some done
  days), `exported`, `scale`.
- **Control launch mode** `-PoimiControl -PoimiFixture <name>`:
  - implies the fake library and fake thumbnails;
  - uses an isolated store under `Application Support/control/` (in-memory unless a relaunch
    needs persistence);
  - uses a separate `UserDefaults` suite;
  - suppresses What's New and `requestReview()`;
  - points `TimelineCache` at `control/`;
  - pins the calendar and time zone to UTC (injected, plus `SIMCTL_CHILD_TZ=UTC`);
  - uses a long debounce, so flushes are explicit;
  - **refuses `-PoimiScreen`** in the same launch.

  All flag parsing lives in `Control/ControlLaunch.swift`, gated as a whole file, so the
  release guard checks the file and not just "a `#if DEBUG` somewhere".
- **Launch-time route** `-PoimiRoute review:album-1:2025-06-14` (also `overview:album-1`,
  `export:album-1`, `settings:album-1`, `appsettings`), plus optional `-PoimiViewer a-0012`.
  These are applied through the coordinator's existing methods (`openProject` / `openReview` /
  `openPhoto` …). `openReview(id, day:)` already picks the grid's entry page, so this reaches
  almost every screen of the real `AppRootView` today.
- **State dump**: `Documents/control/state.json`, written atomically (temp file + rename),
  coalesced to about 100 ms after any change in the observed stores. The shape is in §5. An
  agent reads it with `simctl get_app_container … data`.
- **`Scripts/poimi.sh`**, grown out of `screenshots.sh`, which already resolves, boots, builds,
  installs and grants privacy:

  ```
  Scripts/poimi.sh launch --fixture mid-review [--route review:album-1:2025-06-14] [--ipad] [--build]
  Scripts/poimi.sh state [jq-path]                       # cat/jq state.json
  Scripts/poimi.sh wait '.active.scan.phase == "ready"' '.idle == true' [--timeout 10]
  Scripts/poimi.sh shot out.png                          # wait idle, short visual settle, simctl io screenshot
  Scripts/poimi.sh logs [--last 2m]                      # the documented `log show` predicate
  ```

  `wait` polls the file and evaluates `jq` predicates, so the values are typed. On timeout it
  prints each unmet predicate with its observed value, plus the last state.
- **Interaction**: the **iOS Simulator MCP** is already available to agents (tap, swipe, type,
  screenshot). Launching into a state and then tapping exercises the *real* buttons. That
  proves the wiring, which a control action can't.
- **Agent onboarding**: a project skill at `.claude/skills/poimi-control/SKILL.md` and a short
  "Control plane" section in `CLAUDE.md`. Rules:
  - "Launch into the state, don't tap your way there."
  - "Read `state.json`, not pixels, for what the app holds."
  - "Taps prove wiring; a screenshot that someone looks at proves the look."
  - "Never add state fields or fixture knobs just to make a check pass."
- **Release isolation**: extend `check-fake-release-isolation.sh` to require whole-file
  `#if DEBUG` on every file under `Control/`. The flags `-PoimiControl`, `-PoimiFixture` and
  `-PoimiRoute` are already covered by its `-Poimi*` pattern.
- **Tests**: the fixture seeds (shape and determinism), alias stability across launches, a
  redaction test (serialize every fixture's state and assert no `localIdentifier`, title or
  place name appears), and route parsing.

This slice alone covers "set UI state" for everything a route can express, plus reading state
as data, for most agent tasks.

**As built (#296).** Where slice A landed differently from the text above:

- The pbxproj group for `Control/` is the **`10`** id block: `F0` was already taken by `WhatsNew`.
- `PoimiApp` now builds from a small **`AppGraph`** value (`production()` is the old wiring,
  unchanged), so the control launch can hand in its isolated graph through one DEBUG hook. Slice B
  grows it into `AppGraph.make(…)` shared with the tests.
- The store is **in-memory**; `Application Support/control/` holds the album-alias table and the
  timeline cache, and both control directories are wiped at every control launch.
- UTC is pinned with `NSTimeZone.default` plus `SIMCTL_CHILD_TZ=UTC`, because the review views still
  build `CandidateStore` with `Calendar.current`. Explicit calendar injection comes with slice B.
- `state.json` reports what can't be observed yet as explicit `null` (`pending.selectionFlush`,
  `doneFlush`, `naming`, `export`, `thumbnails`; `active.export.phase`) and has no `settledSeq`
  (slice C). `idle` covers the launch bootstrap and the review/overview scan only.
- `albums` rows carry `toAdd` (for `editedSinceExport`) instead of `lastExportAlbum`, which would
  need an alias scheme for Photos albums. `state-detail.json` lists each day's `photos` and `picked`
  as alias arrays.

### Slice B — Lift the album session out of the views · ~0.5–0.8k net, a product refactor

This is the prerequisite for honest live actions and a headless run. It also removes real
duplication.

- **`AlbumSession`** (`State/`, `@MainActor @Observable`), built by the composition root with
  every dependency (library, naming, name cache, timeline cache, calendar). It owns:
  - `open(project)`: activate selection and done → get or create the `CandidateStore` →
    `load` → `reconcile` → publish the review context.
  - The review context the coordinator holds today (`reviewOrderedIDs`, `reviewDayByID`,
    `reviewAssetsByID`, `reviewClusters`, `reviewIsReExport`) moves here, not into a third home.
  - The `ExportStore`, which gains an initial `.idle` phase, so nothing reads "exporting"
    before anything runs and export can't run twice.

  `AlbumOverviewView`, `ScanningView` and `ExportView` call it. **This removes the two
  diverging scan copies** (and the missing `timelineCache` on the grid-first path). It keeps the
  intentional difference that the Overview activates *without* reconciling (#289) as an
  explicit, tested parameter.
- **`AlbumActions` façade** (or `ProjectStore` methods): `open`, `create(validated:)`,
  `delete`, `reset`, `applyEdits`. These carry the deactivate/mutate/reactivate ordering once,
  and `AlbumsView` and `AlbumSettingsView` both call them.
- **Observable pending state**: `SelectionStore` and `DoneStore` get `hasPendingFlush`, cleared
  in `write`. `CandidateStore` gets `isNaming` (`nameTask` in flight). Each comes with a
  regression test.
- **`AppGraph.make(container:library:…)`**: the one place that wires the graph (stores,
  coordinator, session, the shared `TimelineCache`). Used by `PoimiApp`, by the control launch
  and by the tests, so the hosts can't wire things differently. `AppModelContainer.make` gains
  a `url:` parameter.
- **Device-verified, one screen at a time.** The Overview, grid and export are
  smoothness-sensitive (Finding 1, #232/#283). No pager or `@State` scroll logic moves in this
  slice.

This slice is worth doing even without a control plane: it fixes the duplication and the
timeline-cache gap.

### Slice C — Live actions and headless · ~1–1.5k LOC incl. tests

- **`ControlHost.handle(_:) async -> ControlResponse`** (`@MainActor`), one handler for every
  host. Actions are a strict `Decodable` enum, and each case is a one-line call into a store,
  the session, the façade or the coordinator:
  - **nav**: `openAlbum` → `AlbumActions.open`, `openReview{album, day?}`, `openExport`,
    `openSettings`, `openAppSettings`, `back`, `root`. Pick **one** export entry point:
    `openExport` and `finishToExport` have different guards.
  - **viewer**: `open{photo}`, which is refused as `notShown` unless the photo is in the open
    review, and `dismiss`.
  - **albums**: `create`, `delete`, `reset`, `duplicate`, `update` (through `applyEdits`, never
    model fields).
  - **selection**: `toggle`, `select{photos|day}`, `deselect`, `clear`. Refused as
    `invalidState` when the store is inactive, never a silent `accepted`.
  - **done**: `toggle{day}`.
  - **export**: `run`.
  - **auth**: `request`.

  Outcomes are `accepted` (which means admitted, not finished), `refused(reason)` and `noop`.
  The coordinator's existing idempotence guards become `noop`s.
- **Fixture ops**, test levers rather than user actions:
  - `flush` calls both stores' `flushNow()`.
  - `lifecycle.resume` calls `refreshAuthorization`.
  - `library.failFetch{kind}`: the fake's `fetchError` becomes mutable.
  - `library.authorization{status}` revokes access mid-session (#40).
  - **`reset{name}` is a relaunch, not an in-place wipe.** The container and library are
    built once per launch.
- **Transport: a file mailbox**, not a socket. The script writes `control/req-<n>.json`; the
  app watches the directory with `DispatchSource`, handles the request, and writes
  `res-<n>.json` with temp-file + rename. That avoids the Local Network-prompt risk, ports, a
  token and pre-auth limits. The simulator container is already only reachable by the Mac's
  user. `state.json` carries a per-launch `run` id, so a reply from a previous launch is
  detectable.
- **`wait`, properly defined**:
  - Every accepted reply carries a `seq`. The snapshot exposes `settledSeq`.
  - `idle` means `settledSeq >= lastSeq`, and no scan, naming, export or pending flush is
    running, and no fake thumbnail load is in flight (a counter in `FakeThumbnailProvider`).
  - Evaluation is Observation-driven: re-register `withObservationTracking` on every change and
    evaluate on the next main-actor turn, since `onChange` fires *before* the change. A 20 ms
    poll is the fallback.
  - **Vacuous-wait detection is deferred.** Done naively it rejects the true→false→true
    barriers (`idle`, re-scan `ready`). If it's added later, the baseline is the snapshot
    before the first `send` since the last wait, and a predicate counts as vacuous only if it
    held then *and* its path never changed in between.
  - A `wait` on a path the snapshot doesn't declare fails at once.
- **Headless**: `-PoimiHeadless` runs `AppGraph` and the session but renders a static
  `ControlHeadlessView` (`Text(verbatim:)`) instead of `AppRootView`. `refreshAuthorization`
  moves into the graph's start. This is honest only now that the session doesn't depend on
  mounted views.
- **In-process journeys** are Swift tests through `ControlHost.handle` in `PoimiAppTests`.
  There's no JSON scenario format; a script of `poimi.sh` commands is the simulator equivalent.
  - **Starter tripwires** are regressions the history shows:
    - #59: a stale debounce after delete.
    - #258: `openAppSettings` idempotence becomes a `noop`.
    - #285: `markAllUnreviewed`.
    - #289: done-state survives a lens switch, using a legacy-blob fixture.
  - Re-porting `HappyPathSmokeTests` isn't needed; it already exists.
- **Machinery tests**:
  - strict decoding of unknown keys, actions, types and `v`;
  - every refusal reason;
  - value typing (`10` vs `"10"` vs `null`; `exists` on `null` vs a missing key);
  - `timeoutMs` bounds;
  - schema↔snapshot path parity;
  - the redaction test;
  - every action case exercised at least once.
- **CI**: in-process journeys run in the existing integration tier. Optionally, one
  `poimi.sh` smoke runs on the simulator CI already boots.

### Slice D — UI state that routes can't express (on demand, one at a time)

Lift a piece of state only when a real task needs it, verifying each on device:

- the Overview `filter`, onto the session or coordinator;
- a modal enum on the coordinator for new album, the delete/reset confirmations and What's New;
- the viewer's `currentID` and auto-done (#128);
- the grid's current cluster beyond the route's entry `day`.

**Out of scope:** vertical scroll offset, column pinch, split-view column visibility, form
drafts and focus. Size class comes only from the launch device (`--ipad`).

### Slice E — Break on purpose (only when tied to a specific bug)

- An export gate in `FakePhotoLibrary` (hold, release, fail): re-export dupe-guard and
  double-tap races.
- Persist the fake's `exportedAlbums` under `control/`, so re-export survives a `relaunch`.
  Today it's in memory, so a relaunched re-export would hit `.albumMissing`.
- A kill-mid-debounce relaunch that documents the accepted D15 loss window. `simctl terminate`
  delivers no scenePhase change, so it doesn't flush.
- Library-change drift for #191.

### Later and optional

- **Converge the `DebugScreen` hosts** on fixture + route as each host gets touched. The App
  Store pipeline stays on `DebugScreen` until the migrated path is proven equivalent.
- **Binary sentinel check with a positive control.** If it's added, scan **every Mach-O in the
  `.app`**: with `ENABLE_PREVIEWS` the Debug code lives in `Poimi.debug.dylib`. Use a sentinel
  longer than 15 bytes (Swift stores shorter strings inline), referenced from a live path so it
  isn't dead-stripped.
- An MCP wrapper around `poimi.sh`, and XCUITest for a real-tap wiring check (the happy-path
  controls already carry identifiers).

## 5. Snapshot (`state.json`)

```jsonc
{
  "snapshotVersion": 1, "run": "r-3f2a", "rev": 41, "settledSeq": 7,
  "app":   { "rootPhase": "albums", "authorization": "authorized", "library": "fake",
             "fixture": "mid-review", "idiom": "phone", "timeZone": "UTC" },
  "nav":   { "screen": "review", "path": [{"route":"albumOverview","album":"album-1"},
                                          {"route":"review","album":"album-1","day":"2025-06-14"}],
             "sheet": null, "viewerPhoto": null },
  "albums": { "album-1": { "status": "inProgress", "target": 80, "picked": 34,
                           "titleLength": 11, "exported": false, "lastExportAlbum": null } },
  "active": {
    "album": "album-1",
    "scan":      { "phase": "ready", "candidates": 412, "clusters": 57, "trips": 3 },
    "selection": { "count": 34, "target": 80, "active": true },
    "done":      { "clusters": 12, "of": 57 },
    "export":    { "phase": "idle", "wasReExport": false }
  },
  "pending": { "selectionFlush": false, "doneFlush": false, "scan": false,
               "naming": false, "export": false, "thumbnails": 0 },
  "idle": true
}
```

- **Aliases**:
  - **Assets** are aliased once per fixture over the *whole seeded library*, ordered by
    capture date (D32), then seed index, with undated assets last. They stay stable across
    lens, exclusion and range edits.
  - **Clusters** are keyed by day (`2025-07-05`), not by ordinal.
  - **Albums** get monotonic aliases that are never reused, persisted next to the isolated
    store. `albums` is keyed by alias; its sort order changes on open.
- **Redaction**: no `localIdentifier`, no titles (length only), no place names, no coordinates.
- **Detail on demand**: per-day `{photos:[alias], picked, done}` is written to a sibling
  `state-detail.json` only for the active album, so `state.json` stays small at `scale`. The
  alias table is cached per scan.
- **The snapshot reads main-actor `@Observable` state only.** Actor state is reached through
  explicit counters.

## 6. Invariants

- **Curation stays pure (D14/D21):** nothing goes in `Curation`.
- **D15:** selection goes through `SelectionStore`, so the in-memory set stays the truth and
  persistence stays debounced. `flush` is the existing `flushNow()`.
- **D30:** control code sits in `Control/`, every file whole-file `#if DEBUG`, enforced by the
  guard.
- **D31 / photos sacrosanct:** control mode is fake-only. A real-library mode, if ever wanted,
  would be read-only and simulator-only.
- **D32:** aliases are ordered by `captureDate`.
- **No heavy work in `body`:** the snapshot is built by a control-side observer, never from a
  view. Slice B moves logic *out* of views.
- **Localizable by default:** the plane has no user-facing strings.

## 7. Decisions on the open questions (2026-11-12)

1. **Headless**: both. The in-process journey tier and the interactive `-PoimiHeadless` app
   ship in slice C.
2. **Slice B timing**: now, as its own product refactor in sequence after slice A.
3. **iPad**: `--ipad` launches are in slice A, since the split view reaches the grid through
   `ScanningView` directly. Scenario assertions stay iPhone-first.
4. **Scope**: slices A–E are all built. "Later and optional" stays a follow-up.

## 8. Risks

- **State without looks.** Semantic checks miss layout bugs: the pager ghosting (#283), #274,
  #279 and #232 would pass every predicate. Screenshots, taps and device review stay mandatory
  for screen changes.
- **Slice B regressions** in smoothness-sensitive screens. It's behaviour-preserving, done one
  screen at a time, and device-checked.
- **A second copy of logic in the control layer.** Keep the rule: if a view does something
  that isn't a store or façade call, move it into a store; don't re-implement it in
  `ControlHost`.
- **Maintenance tax.** Scenarios are required only for changes touching two or more of: async
  scan/export, debounced persistence, relaunch, revoked access, multi-store coordination.
- **Flaky waits.** No fixed sleeps. `wait` is driven by observation or polling with a real
  deadline, and `idle` is the only screenshot barrier besides a short visual settle.

## 9. Size

Through live actions (slices A–C): **~2.5–3.5k LOC** including tests, plus a shell script.
That is a fraction of a full implementation of the pattern.

What we skip and why: fake clock (we have explicit `flush` and long debounce instead),
network-stage gates (no backend), run generations and kill fences (a `run` id is enough),
crash-point sweep (only the D15 debounce window is at risk, and it's accepted), provenance and
contract fingerprints (one platform, one codebase), and a call-coverage scanner (a review rule
instead).

## 10. Review record (2026-11-12)

Three independent reviewers looked at the first draft (AGENTS.md).

- **Architect.**
  - Blockers: the scan/activate/reconcile/publish lifecycle and export are view-owned, so the
    in-process actions and scenarios couldn't work, and export would run twice under the UI.
  - Majors:
    - flows sequenced in views (open/create/delete/reset/edit);
    - fixture reset needs a fresh graph;
    - isolation gaps (UserDefaults, review prompt, TimelineCache, `-PoimiScreen`);
    - the fake's export state isn't persisted;
    - the sentinel would miss `Poimi.debug.dylib`;
    - `withObservationTracking` fires before the change;
    - alias ties and ordering.
  - **Resolved:** slice B (session, façade, `AppGraph`); control isolation in slice A;
    reset = relaunch; the export-persistence note in slice E; sentinel notes moved to optional;
    Observation semantics and aliases in §4 C and §5.
- **Tester.**
  - Blockers: the same lifecycle blocker; vacuous detection rejects the true→false→true
    barriers.
  - Majors:
    - `flushTask` is never cleared after it fires;
    - `idle` misses naming and thumbnails;
    - host divergence (time zone, debounce, defaults, iPad path);
    - alias instability;
    - too little testing of the machinery;
    - the zero-case parameterized test risk.
  - **Resolved:** `hasPendingFlush` / `isNaming` / thumbnail counter in slice B and C; vacuous
    detection deferred with a correct definition; UTC pinning, long debounce, defaults suite;
    alias rules; a machinery test list; JSON scenarios dropped, so there's no
    zero-case-directory risk; tripwires chosen from history (#59/#258/#285/#289).
- **Pragmatism.**
  - Recommendations:
    - launch-args reach + a state dump first, with no socket;
    - shared fixtures as the core;
    - use the existing iOS Simulator MCP for taps;
    - a file mailbox over a token-gated socket;
    - a shell script over a Swift CLI;
    - cut the events ring, schema command, evidence dirs, JSON scenarios on two hosts, the
      sentinel check and vacuous detection;
    - don't lift the pager state;
    - headless is mostly CI speed;
    - the LOC estimates were optimistic.
  - **Adopted** nearly wholesale: slice A is its proposal; the cuts are applied or moved to
    "later". Pragmatism suggested deferring the session lift as well. Architect and Tester
    showed that live actions and headless can't be honest without it, so it's kept as slice B
    but runs **after** slice A proves the value and **before** any action layer.
