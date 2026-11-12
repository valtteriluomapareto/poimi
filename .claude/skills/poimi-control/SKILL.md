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
- **Taps prove wiring; a screenshot that someone looks at proves the look.** After `shot`, open the
  PNG and actually look at it. Semantic checks miss layout bugs.
- **Never add state fields or fixture knobs just to make a check pass.**
- **`wait`, never `sleep`.** Block on predicates; `shot` already waits for `.idle == true`.

## Commands

```sh
Scripts/poimi.sh launch --fixture mid-review --route review:album-1   # add --build after code changes
Scripts/poimi.sh launch --fixture one-album --route overview:album-1 --ipad
Scripts/poimi.sh launch --fixture mid-review --route review:album-1:2025-07-05 --viewer a-0210
Scripts/poimi.sh wait '.idle == true' '.active.scan.phase == "ready"' --timeout 20
Scripts/poimi.sh state                 # whole state.json;  state '.albums'  for a jq expression
Scripts/poimi.sh detail '.days | keys' # state-detail.json: the active album's days → photo aliases
Scripts/poimi.sh shot /tmp/poimi.png   # waits idle + a short settle, then simctl screenshot
Scripts/poimi.sh logs --last 2m        # the app's OSLog (subsystem com.valtteriluoma.poimi)
```

- `launch` builds only when there is no built app yet — pass **`--build` after changing Swift code**.
  It returns once the route (and viewer) are applied, and refuses (exit 1, with the reason) a bad
  fixture/route/viewer.
- If a **system alert** covers the app in a screenshot (typically a Photos prompt left behind by a
  normal launch such as the `xcodebuild test` host — control runs never touch PhotoKit), relaunch with
  **`--fresh`** (a clean simulator boot).
- `wait` exits 1 on timeout and prints each unmet predicate with its observed value + the last state.
- `--ipad` uses `iPad Pro 13-inch (M5)` (the 2-column split view); later commands talk to the same
  simulator. Override with `SIM_NAME` / `IPAD_SIM_NAME`.
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

## Routes

`overview:<album>`, `review:<album>[:<yyyy-mm-dd>]` (opens the grid on that day's cluster),
`export:<album>` (runs the export against the fake), `settings:<album>`, `appsettings`.
`--viewer <asset alias>` opens the photo viewer once the review scan is ready (review routes only).

## Reading `state.json`

Aliases, never ids: albums are `album-N` (monotonic, never reused), photos are `a-NNNN` (by capture
date, then seed order, undated last), days are `yyyy-mm-dd`. Titles appear only as `titleLength`.

Key paths: `.app.rootPhase` (`onboarding|recovery|albums`), `.app.launchError`, `.nav.screen`
(`albums|overview|review|export|settings|appSettings|onboarding|recovery`), `.nav.path`, `.nav.sheet`
(`"viewer"` or null), `.nav.viewerPhoto`, `.albums["album-1"].status|picked|target`,
`.active.scan.phase` (`none|idle|scanning|ready|empty|failed`), `.active.scan.clusters`,
`.active.selection.count`, `.active.done.days|clusters|of`, `.idle`, `.rev` (bumps only when content
changes), `.run` (per launch).

**`idle` (slice A) means:** the launch bootstrap finished (authorization read, route + viewer applied)
and no review scan is running or still pending for the screen on top. It does **not** yet cover
debounced flushes, trip naming, an export run by the export screen, or thumbnail loads — those are
`null` under `.pending` ("not observable yet"; slice B/C of the plan fill them in). Don't treat a
`null` as `false`.

## Isolation

A control launch never touches the real store, `UserDefaults` (its own suite), What's New or the App
Store review prompt (both pre-marked done), and runs in UTC. Each launch wipes and re-seeds, so a
fixture is always its exact start state; nothing persists into a normal launch.
