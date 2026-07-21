# Codebase checkup — the playbook

A periodic, **repeatable** deep-clean of the whole repo — one viewpoint (layer) at a time. This is the
durable how-to; the per-run tracking lives in a GitHub issue (the first run: **#213**). Read this, run a
layer, append to the run-log, move on.

**When to run:** before a release milestone, after a churn-heavy stretch, or on demand. **Cadence:** a
full sweep occasionally; between full sweeps, diff-scoped runs (see [Reproducibility](#reproducibility))
are cheap.

---

## Core principle — audit is cheap and always completes; fixing is capped and separate

**Decouple discovery from remediation.** Every layer ALWAYS produces a ranked findings report and
updates the [ledger](#standing-ledger) — cheap, low-risk, never stalls. Fixing is a *separate,
severity-gated, capped* step. A layer is **done** when its report + ledger update + the quick-win PR
land — NOT when the repo is spotless.

### Severity bar — what "fix now" means
- **Fix now** (in the layer's PR): a correctness bug · an invariant / privacy / security / license risk
  · a user-visible defect · a trivial, self-contained cleanup.
- **Defer** (→ a `checkup:<layer>` follow-up issue): everything else, including all taste / cohesion /
  naming / altitude findings. **Behaviour-preserving refactors are out of scope unless a concrete
  defect / invariant / a11y / perf issue justifies them.** *If it works, don't rewrite it for taste.*
- **Won't-fix**: record it in the [standing ledger](#standing-ledger) with a reason, so future runs
  don't re-litigate it.

### Guardrails
- Never break a hard invariant (Layer 1 is the rubric the rest are graded against).
- Scoped diffs, no drive-by reformatting; every behaviour-changing fix ships a failing-then-passing test.
- **Churn budget:** if a layer's accepted fixes exceed a soft cap (~8 files / a hard-to-review diff),
  ship what's coherent and file the rest as scoped issues — keep the PR reviewable.
- The **primary agent applies fixes directly** (Edit/Write + build). Subagents are for **investigation
  and review only**, never delegated development.

---

## The per-layer loop

1. **Rubric** — the checklist for this viewpoint ([skeletons below](#layers); finalise each layer's
   section as it runs).
2. **Skip-probe** — a one-command clean-check; if clean, log a skip in the run-log and advance (no
   fan-out).
3. **Investigate — exactly ONE pass per layer per run.** Effort-tiered (🕸 fan-out by module · 👤 single
   agent · ⚙ mechanical grep/CLI). Feed investigators the [ledger](#standing-ledger) + open `checkup:*`
   issues as *"already known — do not re-report,"* and on a repeat run **scope them to
   `git diff <last-checkup-sha>..HEAD`** (full sweep only every Nth run / before a release). Findings
   ranked, with `file:line` + rationale.
4. **Synthesize + triage** against the severity bar. **Anything uncovered later, while fixing, is filed
   for the NEXT run — never chased in the same pass** (this is what makes taste-heavy layers terminate).
5. **Adversarially verify ALL fix-now items** (a skeptic pass) — the low/medium findings are the most
   false-positive-prone.
6. **Fix** (primary agent; tests-with-fixes; churn budget).
7. **Verify green** — cheap inner loop (`Curation` tests + the 4 guards + `Scripts/tests/guard-selftests.sh`
   + SwiftLint) while iterating; the full Release build + sim-integration matrix at the per-PR gate.
8. **Commit** — one layer = one PR. 3-persona panel only for substantive fix PRs (code / tests / perf /
   a11y); docs / localization / design / git / mechanical PRs merge without the panel.
9. **Record + advance** — update the ledger + [run-log](#run-log). Advance only when green.

### P0 pre-flight (before Layer 1, every run)
A fast global reconnaissance, fixed **on the spot** regardless of layer: secret scan · dependency
license-compat · all 4 guards + the guard self-tests pass · build + tests green · a **test-trust
spot-check** (are the green tests meaningful, not tautological — so the bar is trustworthy *before* code
changes behind it) · any obvious crasher.

---

## Layers

🕸 fan-out (partition by module) · 👤 single agent · ⚙ mechanical. **Layer 1 is mandatory**; the rest are
skippable/reorderable per run (log why). Detailed, reality-grounded rubrics + pre-seeded findings live
in issue **#213** — the skeletons here are the operational checklist.

| # | Layer | Tier | Rubric headline |
|---|-------|------|-----------------|
| 0 | Harness | ⚙ | this playbook + `Scripts/tests/guard-selftests.sh` exist and pass |
| 1 | Architecture, invariants & concurrency | 👤 | invariants held **and guards fail on a violation**; decisions log reconciled with shipped code; Sendable/actor isolation; deps point at `Curation` |
| 2 | Tests & test-trust | 🕸 | tests assert the right thing (no tautologies); coverage of load-bearing seams; no flakiness; Fake/System conformance parity; store-durability (SIGTRAP/D15/D38) |
| 3 | Code files & clarity | 🕸 | length (SwiftLint `file_length` err @ 1000; DEBUG-harness carve-out); cohesion; self-explanatory; no stale comments; dead code |
| 4 | Performance & smoothness | 🕸 | no heavy work in a `body` (only grouping is guarded — rest is manual); no per-tap O(n); large-album hot paths |
| 5 | Accessibility & UX-state honesty | 🕸 | VoiceOver/Dynamic Type/Reduce Motion+Transparency/contrast (D9); empty/error surfaces actionable, revoked-access → recovery (#40) |
| 6 | Infra: scripts, CI, release, deps, security | 👤/⚙ | guards + self-tests; CI gates; build warnings; release flow (fastlane/testflight/version guards) maintainable; deps license-compat; no secrets; privacy invariants; pbxproj discipline; harness determinism |
| 7 | Localization | ⚙ | catalog-routed; fi coverage (currently 100%) → real debt is **terminology consistency** (#190 sweep); no orphaned keys |
| 8 | Design | 👤 | paper-index ↔ Paper (count + build-status); obsolete artboards; styleguide token adherence; ui-spec currency |
| 9 | Documentation & CLAUDE.md | 👤 | repo map lists every source dir; doc map lists every `docs/**`; fresh-agent onboarding sim; cross-refs valid |
| — | Git & backlog hygiene (closing) | ⚙ | merged-branch detection via `gh pr list --state merged --head`; groom issues; append the run-log |

**First run scope:** Layer 0 + P0 pre-flight + Layer 1, then **go/no-go** before Layers 2–9.

---

## Reproducibility

What makes run N+1 cheap:
- **This playbook** — the loop + rubrics + guardrails.
- **Standing ledger** (below) — per-layer won't-fix / accepted-as-is, fed to investigators as "do not
  re-report." Mirrors the `plan-review-decisions.md` deferred/open structure.
- **Run-log** (below) — per run: HEAD SHA + objective metrics. A later run diff-scopes investigators to
  `git diff <last-sha>..HEAD`; full sweep only every Nth run / before a release.
- **`checkup:<layer>` issue label** — deferred findings become tracked, already-known items.
- **Guard self-tests** — `Scripts/tests/guard-selftests.sh` proves each CI guard passes a clean tree AND
  fails an injected violation (a guard that silently stopped matching would pass CI forever).
- **`/checkup` skill** — extract only AFTER the first full run proves the loop (YAGNI until then).

---

## Standing ledger (won't-fix / accepted-as-is)

Investigators are handed this verbatim as "already known — do not re-report." Add an entry when a
finding is consciously accepted; remove it if the decision changes.

- _(Layer 1)_ — **Accepted concurrency escape hatches** (Swift 6 complete mode is on; these are the
  justified overrides, don't re-flag): `PlayerItemBox: @unchecked Sendable` (`ThumbnailProviding.swift`)
  — boxes a non-Sendable `AVPlayerItem`, touched only on main; `ThumbnailMemoryCache: @unchecked Sendable`
  (thread-safe `NSCache`); `nonisolated(unsafe) didAdd`/`placeholderID` (`SystemPhotoLibrary.swift`, read
  after a synchronous `performChanges`). All correctly justified in-comment.
- _(Layer 2)_ — none yet.
- _(Layer 3)_ — none yet.
- _(Layer 4)_ — none yet.
- _(Layer 5)_ — none yet.
- _(Layer 6)_ — none yet.
- _(Layer 7)_ — none yet.
- _(Layer 8)_ — none yet.
- _(Layer 9)_ — none yet.

---

## Run-log

Append one entry per run (newest first). Metrics are the cheap objective signals so drift is measurable
run-over-run.

### Run 1 — 2026-07 (Layer 0 + P0 pre-flight + Layer 1; go/no-go pending)
- **Baseline SHA:** `467a7ce` (main after Layer 0). Future runs diff-scope from here.
- **Scope:** Layer 0 (harness) + P0 pre-flight + Layer 1, then go/no-go before Layers 2–9.
- **Baseline metrics:** SwiftLint 71 warnings / 0 errors · files > 900 lines: 3 (`AlbumOverviewView` 993;
  `LocationSpikeProbe` 978 + `DebugScreen` 965 are DEBUG-harness) · none > 1000 · ~22k Swift LOC (App+Curation)
  · Curation 204 tests + the app/integration suite · **zero third-party deps** · **no secrets**.
- **P0 pre-flight:** clean — no secrets, deps license-compatible (none), all guards + self-tests green,
  main green. No P0 fixed on the spot.
- **Layer 1 (architecture, invariants & concurrency):** every invariant HELD; all guards + self-tests pass;
  **app target already builds Swift 6 complete-concurrency** (the compiler is the concurrency guard) — every
  actor seam clean.
  - **Fixed:** added the **D31 photos-sacrosanct guard** (was the only safety-critical invariant with no
    automated defense) + CI + self-tests; hardened the boundary denylist (**+MapKit/Contacts/CoreGraphics**)
    and the liquid-glass guard (**+`@available` attribute gate**), both with self-test cases; reconciled the
    decisions log (**D4/D33 → shipped; D37 → corrected** for the AppSchemaV2 new-entity automatic migration;
    D6 → resolved; a deferred/resolved inconsistency).
  - **Deferred → `checkup:layer-1`:** boundary allowlist rewrite; D30 nesting-depth + Fake/Stub/Mock content
    detection; D15 selection guard; identifier-convention guard; Mutex-over-NSLock; unjustified-@unchecked
    guard; liquid-glass block-comment stripping; a misleading `CandidateStore` "DETACHED" comment (→ Layer 2);
    CLAUDE.md / architecture.md / project-phases.md location drift (→ Layer 9).
  - **Accepted (won't-fix):** the concurrency escape hatches — see the ledger above.
- **Layer 7 (localization):** fi coverage 100% (unchanged); `Text(verbatim:)` audit clean (all DEBUG dev
  strings or formatted values).
  - **Fixed:** finished the **tarkistaa → läpikäydä** review-flow terminology sweep (#190) — 8 keys
    (filter "Läpikäytävät", the "…läpikäyty"/"…läpikäydyksi"/"…läpikäytävän" a11y + empty-state strings),
    now consistent with the läpikäy* forms already in the catalog. Left the literal "check access /
    connection" strings unchanged.
  - **Deferred → `checkup:layer-7`:** thorough orphan-key pruning via `xcodebuild -exportLocalizations`
    (a grep heuristic flagged ~7 likely orphans from the #190 verb-unification + day→cluster redesign —
    e.g. "Pick photo/video", "Mark as not done", day/cluster reopen variants — but confirm with the
    export tool before deleting; grep can't see wrapped/interpolated literals). "Review exclusions"
    sense-check (kept as "Tarkista poissulkemiset").
- **Layer 9 (documentation & CLAUDE.md):** a fresh-agent onboarding sim + doc-drift catalog found the
  docs lagged the whole v1.1 wave.
  - **Fixed:** CLAUDE.md — Status now records the v1.1 wave + the built-then-reverted locality caption;
    the stale **accordion** grid description → the shipped **paged-clusters pager**; repo map gains
    `Albums/`/`Setup/`/`Review/`/`Location/` + `GeocodedPlaceName`/`DoneStore`/location math; the
    **pbxproj id cursor** corrected (E0 = Location; next = F0 — a fresh agent would have collided);
    the Photos-sacrosanct invariant gets its guard line; guard count "four"→all + `check-photos-sacrosanct`;
    doc map gains the 6 missing docs; paper-index count made version-agnostic. architecture.md §7 +
    project-phases.md — location split (geocode/trip half SHIPPED #130; MapKit/`NamedLocation` half still
    v1.1), `NamedLocation`→`GeocodedPlaceName` where it's the real model, TestFlight/fastlane marked
    shipped (#135).
  - **Deferred → `checkup:layer-9`:** minor project-phases wording ("event/place names arrive with
    location" — trips already name); paper-index artboard-count accuracy is **Layer 8** (design).
