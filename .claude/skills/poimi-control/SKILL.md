---
name: poimi-control
description: Launch, inspect, drive, screenshot or run headless the Poimi iOS app on a simulator through its DEBUG control plane (Scripts/poimi.sh) — put it into a named fixture + route, send it the same actions as the user, read its state as JSON, wait on predicates, and capture a screenshot. Use whenever you need to run Poimi, see a screen, check what the app holds after a change, drive a flow (open → pick → done → export), or verify a UI change works in the real app.
---

# Poimi control plane

`Scripts/poimi.sh` runs the **real** app on an iOS 26 simulator, already in a known state, on an
isolated in-memory store and the deterministic fake library — never real photos. You drive it with
**actions** — each one a control a user can reach, calling the same method that control calls — through
a file mailbox, and read its state as JSON. It runs with its UI (`AppRootView`) or **headless** (no UI;
the stores and album session only). DEBUG-only (`App/PoimiApp/Control/`, D39,
`docs/plans/control-plane.md`).

## Rules

- **Launch into the state, don't tap your way there.** Pick a fixture + route.
- **Read state, not pixels, for what the app holds** (counts, statuses, route, scan phase).
- **`accepted` ≠ finished. Follow every `send` with a `wait`.** An accepted action has only been
  admitted; the scan / export / naming it starts runs after the reply. Wait on the state you expect,
  on `idle == true`, or on `settledSeq >= <the reply's seq>`.
- **`wait`, never `sleep`.**
- **An action is only what a user could do from where the app is.** If you get `notShown`, navigate
  to the screen that has that control (the album list, the overview, the grid, the album's settings)
  — don't look for a way around it.
- **Taps prove wiring; a screenshot that someone looks at proves the look.** Actions call the methods
  the controls call, not the controls — semantic checks miss layout bugs.
- **Never add actions, state fields or fixture knobs just to make a check pass.** If a check needs
  something the app can't express, that's a finding: say so.
- **The vocabulary is `Scripts/poimi.sh schema`**: every action with its arguments and where its control
  is, the fixture ops, refusal reasons, error codes, the declared state paths and their types, fixtures
  and routes — printed by the app from the declarations it decodes with. This file doesn't copy them.

## Commands

```sh
Scripts/poimi.sh launch --fixture one-album [--route overview:album-1] [--headless] [--ipad]
Scripts/poimi.sh send '{"type":"nav.openAlbum","album":"album-1"}'   # → {"outcome":"accepted","seq":1}
Scripts/poimi.sh wait 'active.scan.phase == ready' 'idle == true' --timeout 20
Scripts/poimi.sh fixture flush                     # test levers (schema: fixtureOps)
Scripts/poimi.sh state '.albums'                   # state.json, or a jq expression over it
Scripts/poimi.sh detail '.days | keys'             # state-detail.json: the active album's days → photos
Scripts/poimi.sh schema | jq '.actions[] | {type, summary}'
Scripts/poimi.sh shot /tmp/poimi.png               # waits idle; then ALWAYS open the PNG and look
Scripts/poimi.sh reset mid-review                  # a reset is a relaunch (same device/host, no build)
Scripts/poimi.sh logs --last 2m                    # the app's OSLog (subsystem com.valtteriluoma.poimi)
```

A whole flow, the same with or without `--headless`:

```sh
P=Scripts/poimi.sh
$P launch --fixture one-album
$P send '{"type":"nav.openAlbum","album":"album-1"}'               && $P wait 'idle == true'
$P send '{"type":"nav.openReview","album":"album-1"}'              && $P wait 'idle == true'
$P send '{"type":"selection.toggleCluster","day":"2025-01-06"}'    && $P wait 'idle == true'
$P send '{"type":"done.toggle","day":"2025-01-06"}'                && $P wait 'idle == true'
$P fixture flush                                   # persist before checking what was SAVED
$P send '{"type":"nav.back"}'                                      && $P wait 'idle == true'
$P send '{"type":"nav.openExport"}'   && $P wait 'active.export.phase == done' 'idle == true'
$P state '.albums["album-1"].status'               # "exported"
```

- **`launch`** builds (incremental), installs only if the build differs, and returns once the route
  (and viewer) are applied. It exits 1 with the reason on a bad fixture/route/viewer or a route that
  can't apply. `--no-build` relaunches the last build; `--ipad` uses `iPad Pro 13-inch (M5)` (the split
  view, where the album list stays on screen); `--headless` shows a static host view instead of the UI.
  Override the devices with `SIM_NAME` / `IPAD_SIM_NAME`.
- **`send ACTION`** prints the outcome and exits 1 on `refused` (unless `--allow-refused`) or a bad
  request. `accepted` + `seq`: admitted. `refused` + `reason`: the app said no (reasons: `schema`).
  `noop`: already so (the UI's own guards, e.g. a second `nav.openAppSettings`). After an action, the
  app runs what the album screens on the path run when they appear (the overview's / grid's scan, the
  export screen's export) — with or without UI.
- **`wait PREDICATE…`** blocks **in the app** (Observation-driven, real deadline, 0–30 s). Predicates are
  `PATH OP VALUE` (`OP`: `== != >= <=`) or `PATH exists` / `PATH !exists` (present and not null).
  Values are typed: `10` is a number, `"10"` a string, a bare word (`ready`) a string, `true`/`null`
  JSON. A value whose type can't match the path's (`idle != "true"`), or an undeclared path, is an
  error at once. On timeout it prints each unmet predicate with what was observed (or `missing`). Full
  `jq` expressions aren't predicates — use `state 'jq…'` to inspect.
- **The mailbox is serial except for waits:** requests are handled one at a time in order, but a
  `wait` runs alongside, so an action is never held behind a wait. If no reply comes within
  `REPLY_TIMEOUT` (30 s; a wait gets its own timeout on top) and the app hasn't taken the request, the
  CLI withdraws it — so a retry can't run it twice; if the app took it, the CLI says so: check `state`
  before retrying.
- **`state` / `detail`** read the files the app writes; every reply is written only after `state.json`
  caught up, so right after a `send` or `wait`, `state` shows at least that reply's `rev`.
- **`fixture OP [ARGS]`** pulls test levers, not user actions — e.g. `flush`, `lifecycle.resume`,
  `library.failFetch '{"kind":"fetchFailed"}'`, `library.authorization '{"status":"denied"}'` (then
  `lifecycle.resume`; on `fresh`, `authorized` then `send auth.request`), and `selection.select` /
  `selection.clear` for selections no single control makes.
- Every command answers only for the current launch: it fails if the app quit, the simulator shut down,
  or the state is from another run (`staleRun`) — relaunch.
- **`shot`** waits for `idle == true`, settles briefly, captures. **Always look at the PNG.** If a system
  alert covers the app, relaunch with `--fresh`. Headless runs have nothing to look at.
- To tap/swipe the real controls, use the **iOS Simulator MCP** on the booted device, then re-read state.

## Screen state beyond routes

A route says which screen; these say where on it (each read back from `state.json`). There are no launch
flags for them: `launch` returns once the route has settled, so `send` the action next.

- **Overview filter** — `review.setFilter{filter}` → `active.overview.filter`. Kept while the album is
  open; `.all` again on the next open.
- **Grid page** — `active.grid.cluster` is the current cluster's first day (`null` with no grid).
  `review.goTo{day}` swipes to the cluster holding that day; `review.markDoneAndAdvance` is the current
  cluster's end-cap (done → the next unreviewed cluster; on a done cluster it reopens it and stays).
  The grid enters on the route's day, else the first unreviewed cluster, once per visit.
- **Viewer** — `nav.viewerPhoto` is the photo on screen, `nav.viewerEndOfSet` the end-of-set card.
  `viewer.page{direction:next|previous}` is the chevrons / a swipe (forward past a cluster's last photo
  marks it done, #128; next on the last photo opens the card); `viewer.page{photo}` is a filmstrip tap
  (never marks; only photos the strip shows). `viewer.pick` is Pick. With the card up only
  `viewer.keepReviewing`, `viewer.dismiss` (Back to grid) and `nav.openExport` (its Save to Photos)
  work. Dismissing moves the grid to the photo's cluster.
- **Auto-done toast** — `nav.viewerToast` = `{day, marks}` after a paged-past auto-mark (`null` when
  none); `viewer.undoAutoDone` is its Undo. With UI it hides after a few seconds; headless it stays
  until Undo or the next opening.
- **Modals** — `ui.present{modal, album?}` → `nav.sheet` (+ `nav.sheetAlbum` for a confirmation);
  `ui.confirm` is a confirmation's confirm button, `ui.dismiss` Cancel / swipe-down / Continue. A sheet
  or dialog covers everything (iPad too): other actions are `notShown` until it's dismissed — except
  the New album sheet's `albums.create`.

## Reading state

Aliases, never ids: albums `album-N` (monotonic, never reused in a run), photos `a-NNNN` (by capture
date), days `yyyy-mm-dd`. Titles only as `titleLength`. Every path and type: `schema`'s `statePaths`.

- **`idle == true` means no work the app can see is in flight**: the launch finished, every accepted
  action settled (`settledSeq >= lastSeq`), and no scan, trip naming, export or fake thumbnail load
  (`pending.thumbnails`) is running or pending for a screen on the path.
- **`idle` does not wait for debounced persistence.** Under control the debounce is a day long, so a
  pick leaves `pending.selectionFlush == true` until a flush; the in-memory picks are already what the
  UI shows. Call `fixture flush` before checking what was *persisted* (`albums.*` of a closed album, a
  relaunch).

## Isolation

A control launch never touches the real store, `UserDefaults` (its own suite), What's New or the App
Store review prompt, and runs in UTC. Each launch wipes and re-seeds, so a fixture is always its exact
start state; a normal launch deletes the control state files.
