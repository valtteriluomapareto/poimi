---
name: poimi-control
description: Launch, inspect, drive, screenshot or run headless the Poimi iOS app on a simulator through its DEBUG control plane (Scripts/poimi.sh) — put it into a named fixture + route, send it the same actions as the user, read its state as JSON, wait on predicates, and capture a screenshot. Use whenever you need to run Poimi, see a screen, check what the app holds after a change, drive a flow (open → pick → done → export), or verify a UI change works in the real app.
---

# Poimi control plane

`Scripts/poimi.sh` runs the **real** app on an iOS 26 simulator, already in a known state, on an
isolated in-memory store and the deterministic fake library — never real photos. You drive it with
**actions** (the same calls the buttons make) through a file mailbox, and read its state as JSON. It
runs with its UI (`AppRootView`) or **headless** (no UI; the stores and album session only). It is
DEBUG-only (`App/PoimiApp/Control/`, decision D39, plan `docs/plans/control-plane.md`).

## Rules

- **Launch into the state, don't tap your way there.** Pick a fixture + route.
- **Read state, not pixels, for what the app holds** (counts, statuses, route, scan phase).
- **`accepted` ≠ finished. Follow every `send` with a `wait`.** An accepted action has only been
  admitted; its scan / export / naming runs after the reply. Wait on the state you expect, on
  `idle == true`, or on `settledSeq >= <the reply's seq>`.
- **`wait`, never `sleep`.** Block on predicates.
- **Taps prove wiring; a screenshot that someone looks at proves the look.** Actions call the same
  methods the buttons do, but not the buttons — semantic checks miss layout bugs.
- **Never add actions, state fields or fixture knobs just to make a check pass.** If a check needs
  something the app can't express, that's a finding: say so.
- **The vocabulary is `Scripts/poimi.sh schema`** — every action and its arguments, the fixture ops,
  refusal reasons, the declared state paths and their types, fixtures and routes, printed by the
  running app from the same declarations it decodes with. Don't trust a copy of it (including this file)
  over `schema`.

## Commands

```sh
Scripts/poimi.sh launch --fixture one-album [--route overview:album-1] [--headless] [--ipad]
Scripts/poimi.sh send '{"type":"nav.openAlbum","album":"album-1"}'   # → {"outcome":"accepted","seq":1}
Scripts/poimi.sh wait 'active.scan.phase == ready' 'idle == true' --timeout 20
Scripts/poimi.sh fixture flush                     # test levers: flush, lifecycle.resume, library.*
Scripts/poimi.sh state '.albums'                   # state.json (or a jq expression over it)
Scripts/poimi.sh detail '.days | keys'             # state-detail.json: the active album's days → photos
Scripts/poimi.sh snapshot                          # the state right now, asked of the app
Scripts/poimi.sh schema | jq '.actions[].type'     # the vocabulary
Scripts/poimi.sh shot /tmp/poimi.png               # waits idle; then ALWAYS open the PNG and look
Scripts/poimi.sh reset mid-review                  # a reset is a relaunch (same device/host, no build)
Scripts/poimi.sh logs --last 2m                    # the app's OSLog (subsystem com.valtteriluoma.poimi)
```

A whole flow, the same with or without `--headless`:

```sh
P=Scripts/poimi.sh
$P launch --fixture one-album
$P send '{"type":"nav.openAlbum","album":"album-1"}' && $P wait 'active.scan.phase == ready' 'idle == true'
$P send '{"type":"nav.openReview","album":"album-1"}' && $P wait 'idle == true'
$P send '{"type":"selection.select","day":"2025-01-06"}'
$P send '{"type":"done.toggle","day":"2025-01-06"}'
$P fixture flush                                   # persist before checking what was SAVED
$P send '{"type":"nav.openExport"}' && $P wait 'active.export.phase == done' 'idle == true'
$P state '.albums["album-1"].status'               # "exported"
```

- **`launch`** builds (incremental), installs only if the build differs from what's on the simulator,
  and returns once the route (and viewer) are applied. It exits 1 with the reason on a bad
  fixture/route/viewer, or a route that can't apply (any route on `fresh`/`denied`). `--no-build`
  relaunches the last build; `--ipad` uses `iPad Pro 13-inch (M5)` (the split view); `--headless`
  shows a static host view instead of the UI. Override the devices with `SIM_NAME` / `IPAD_SIM_NAME`.
- **`send ACTION`** prints the outcome and exits 1 on `refused` (unless `--allow-refused`) or a bad
  request:
  - `accepted` + `seq` — admitted, not finished (see the rules);
  - `refused` + `reason` — `notShown` (not on screen / not reachable from here: a photo outside the
    open review, a back button under the viewer), `unknownAlias`, `invalidState` (e.g. selection with
    no album open — never a silent success), `busy` (the album is exporting), `unavailable`;
  - `noop` — already so (the UI's own guards: a second `nav.openAppSettings`, `nav.openExport` with
    export on top).
  An action is only what a user could do from where the app is: `nav.openReview` needs the album's
  overview on top, `viewer.open` the grid, `auth.request` onboarding. After a navigation the app runs
  what that screen runs when it appears (the Overview's / grid's scan, the export screen's export) —
  with or without UI.
- **`wait PREDICATE…`** blocks **in the app** (Observation-driven, real deadline, 0–30 s) until every
  predicate holds. Predicates are `PATH OP VALUE` with `OP` one of `== != >= <=`, or `PATH exists` /
  `PATH !exists` (present and not null). Values are typed: `10` is a number, `"10"` a string, `ready`
  a bare string, `true`/`null` JSON — `count == "10"` never matches a number. A leading `.` is fine.
  Paths are the declared ones (`schema`'s `statePaths`); an undeclared path fails at once. On timeout
  it prints each unmet predicate with what was observed (or `missing`). Full `jq` expressions are not
  predicates — use `state 'jq…'` to inspect.
- **`fixture OP [ARGS]`** pulls test levers, not user actions: `flush` (persist picks + day marks
  now), `lifecycle.resume` (re-read photo access), `library.failFetch '{"kind":"fetchFailed"}'` /
  `'{"kind":null}'`, `library.authorization '{"status":"denied"}'` (then `lifecycle.resume`; or, on
  `fresh`, `authorized` then `send auth.request`).
- **`state` / `detail` / `wait` / `shot` / `send`** answer only for the current launch: they fail if
  the app quit, the simulator shut down, or the state is from another run (`staleRun`) — relaunch.
- **`shot`** waits for `idle == true`, settles briefly, captures. **Always look at the PNG.** If a
  system alert covers the app, relaunch with `--fresh`. Headless runs have nothing to look at.
- To tap/swipe the real buttons, use the **iOS Simulator MCP** on the booted device, then re-read state.

## Fixtures and routes

`Scripts/poimi.sh schema | jq '.fixtures, .routes'`. In short: `fresh` (onboarding), `denied`
(recovery), `empty-library`, `one-album` (the 2025 library, 368 photos over 26 days, `album-1`
untouched, target 80), `four-statuses`, `mid-review` (34/80 picked, first 4 days done), `exported`,
`scale` (10k photos), `located` (trips + fake place names), `legacy-baseline` (pre-per-lens done
baseline + a video on a done day, the #289 shape). Routes: `overview:<album>`,
`review:<album>[:<yyyy-mm-dd>]`, `export:<album>` (runs the export), `settings:<album>`, `appsettings`;
`--viewer <photo>` opens the viewer on a review route.

## Reading state

Aliases, never ids: albums `album-N` (monotonic, never reused in a run), photos `a-NNNN` (by capture
date), days `yyyy-mm-dd`. Titles only as `titleLength`. Every path and type: `schema`'s `statePaths`.

- **`idle`** is `false` until the launch finished, while an accepted action hasn't settled
  (`settledSeq < lastSeq`), while a scan / trip naming / export runs or is pending for the screen on
  top, and while a fake thumbnail load is in flight (`pending.thumbnails`); `true` otherwise.
- **`idle` does not wait for debounced persistence.** Under control the debounce is a day long, so a
  pick leaves `pending.selectionFlush == true` until a flush; the in-memory picks are already what the
  UI shows. Call `fixture flush` before checking what was *persisted* (`albums.*` of a closed album,
  a relaunch).
- `rev` bumps when either state file changes; `run` is per launch.

## Isolation

A control launch never touches the real store, `UserDefaults` (its own suite), What's New or the App
Store review prompt, and runs in UTC. Each launch wipes and re-seeds, so a fixture is always its exact
start state; a normal launch deletes the control state files.
