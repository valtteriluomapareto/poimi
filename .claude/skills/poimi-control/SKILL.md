---
name: poimi-control
description: Launch, inspect, screenshot or drive the Poimi iOS app on a simulator through its DEBUG control plane (Scripts/poimi.sh) — put it into a named fixture + route, read its state as JSON, wait on predicates, and capture a screenshot. Use whenever you need to run Poimi, see a screen, check what the app holds after a change, or verify a UI change works in the real app.
---

# Poimi control plane

`Scripts/poimi.sh` runs the **real** app (`AppRootView`) on an iOS 26 simulator, already in a known
state, on an isolated in-memory store and the deterministic fake library — never real photos. It is
DEBUG-only (`App/PoimiApp/Control/`, decision D39, plan `docs/plans/control-plane.md`).

## Rules

- **Launch into the state, don't tap your way there.** Pick a fixture + route.
- **Read `state.json`, not pixels, for what the app holds** (counts, statuses, route, scan phase).
- **Taps prove wiring; a screenshot that someone looks at proves the look.** Semantic checks miss
  layout bugs.
- **Never add state fields or fixture knobs just to make a check pass.**
- **`wait`, never `sleep`.** Block on predicates.

## Commands

```sh
Scripts/poimi.sh launch --fixture mid-review --route review:album-1
Scripts/poimi.sh wait '.idle == true' '.active.scan.phase == "ready"' --timeout 20
Scripts/poimi.sh state                  # whole state.json;  state '.albums'  for a jq expression
Scripts/poimi.sh detail '.days | keys'  # state-detail.json: the active album's days → photo aliases
Scripts/poimi.sh shot /tmp/poimi.png    # then ALWAYS open the PNG and look at it
Scripts/poimi.sh logs --last 2m         # the app's OSLog (subsystem com.valtteriluoma.poimi)
```

- **`launch`** builds (incremental — a no-op when nothing changed), installs only if the build
  differs from what's on the simulator, and returns once the route (and viewer) are applied. It exits
  1 with the reason on a bad fixture/route/viewer, or a route that can't apply (e.g. any route on
  `fresh`/`denied`, which start before the album library). `--no-build` relaunches the last build.
  `--ipad` uses `iPad Pro 13-inch (M5)` (the split view). Override with `SIM_NAME` / `IPAD_SIM_NAME`.
- **`state` / `detail` / `wait` / `shot`** answer only for the current launch: they fail if the app
  has quit, the simulator is shut down, or the state file is from another run — relaunch then.
- **`wait`** exits 1 on timeout and prints each unmet predicate with its observed value + the last state.
- **`shot`** waits for `.idle != false`, settles briefly, captures. **Always look at the PNG** — that
  is the only check of the look. If a **system alert** covers the app, relaunch with `--fresh` (a
  clean simulator boot). `launch` already does this automatically when a normal Poimi launch — e.g.
  the `xcodebuild test` host, whose real-PhotoKit conformance test raises the Photos prompt — ran on
  that simulator since the last control launch.
- To tap/swipe after launching, use the **iOS Simulator MCP** on the booted device — that exercises
  the real buttons. Then re-read `state.json`.

## Fixtures (`ControlFixture`)

| name | state |
|---|---|
| `fresh` | photo access not determined → onboarding; no albums |
| `denied` | access denied → recovery screen; no albums |
| `empty-library` | authorized, empty library, `album-1` (its scan is the empty state) |
| `one-album` | the 2025 year library (368 photos over 26 days), `album-1` untouched (target 80) |
| `four-statuses` | `album-1` exported, `album-2` edited since export (3 to add), `album-3` in progress, `album-4` not started |
| `mid-review` | `album-1`: 34 of 80 picked, the first 4 days done |
| `exported` | `album-1` fully reviewed and exported, in sync with its Photos album |
| `scale` | 10,000 photos, `album-1` with 200 picks |
| `located` | a located 2025 library (home base + planted trips), `album-1` — trips form and get fake place names |

## Routes

| route | lands on |
|---|---|
| `overview:<album>` | the album overview |
| `review:<album>[:<yyyy-mm-dd>]` | the review grid, on that day's cluster when a day is given |
| `export:<album>` | the export screen — which **runs the export** (against the fake) |
| `settings:<album>` | the album settings |
| `appsettings` | app settings |

`--viewer <asset alias>` (review routes only) opens the photo viewer once the scan is ready. The photo
may be on a different day than the route's — the viewer pages the whole album; the grid underneath
stays on the route's day.

## Reading `state.json`

Aliases, never ids: albums are `album-N` (monotonic, never reused in a run; `albums` is sorted by
alias), photos are `a-NNNN` (by capture date, then seed order, undated last), days are `yyyy-mm-dd`.
Titles appear only as `titleLength`.

Key paths: `.app.rootPhase` (`onboarding|recovery|albums`), `.app.launchError`, `.nav.screen`
(`albums|overview|review|export|settings|appSettings|onboarding|recovery`), `.nav.path`, `.nav.sheet`
(`"viewer"` or null), `.nav.viewerPhoto`, `.albums["album-1"].status|picked|target`,
`.active.scan.phase` (`none|idle|scanning|ready|empty|failed`), `.active.scan.clusters|trips`,
`.active.selection.count`, `.active.done.days|clusters|of`, `.idle`, `.rev` (bumps when either file's
content changes), `.run` (per launch).

**`idle` (slice A)** is `false` until the launch bootstrap finished (authorization read, route +
viewer applied) and while a review scan runs or is still pending for the screen on top; **`null`
(unknown) on the export screen**, whose export runs in view state slice A can't see; `true`
otherwise. It never covers debounced flushes, trip naming or thumbnail loads — those are `null` under
`.pending` ("not observable yet"; slices B/C fill them in). Don't treat a `null` as `false` or `true`.

## Isolation

A control launch never touches the real store, `UserDefaults` (its own suite), What's New or the App
Store review prompt (both pre-marked done), and runs in UTC. Each launch wipes and re-seeds, so a
fixture is always its exact start state; a normal launch deletes the control state files.
