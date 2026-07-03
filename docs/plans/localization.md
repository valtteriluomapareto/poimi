# Localization plan — multi-locale UI + automated translation & release notes

**Status: PHASE 0 BUILT (2026-07-03); rest still deferred.** Tracks [#95]. Revised after a 3-persona +
Codex review (see PR #96). The precondition ("don't build until the v1 English UI is stable") is now
**met** — Phase 2 (#30–#43) is complete + the surface has settled — so **Phase 0 shipped**: the String
Catalog (`App/PoimiApp/Resources/Localizable.xcstrings`) exists + is in the app target + is populated by
extraction (`xcodebuild -exportLocalizations`), and **localizable-by-default** is a documented
convention (CLAUDE.md). Still deferred (Phase 1+): the retro-audit of any un-extracted strings, the
**DEBUG-string cleanup** (DebugScreen `Text` → `Text(verbatim:)` so dev strings leave the catalog),
`fi` registration, `InfoPlist` localization, the glossary, and all translation/CI automation — built
only when release-frequency × locale-count justifies each step.

**What IS worth doing now** is only the near-zero-cost foundation (create the String Catalog + make new
strings localizable-by-default). Everything else is staged behind "v1 English shipped," and the *first*
translation engine is a **manual script run at release**, not CI — the pipeline is graduated to only when
release-frequency × locale-count justifies it. Decisions logged as `D39+` once confirmed.

## Goals
- Ship Poimi in multiple locales/languages.
- **Minimize manual maintenance** — translate only deltas; consistency without re-deciding.
- **Automate release notes + store metadata** across languages.

## Foundation — a String Catalog (the enabler)
Adopt **`Localizable.xcstrings`** (the Xcode 15+ String Catalog — *build-time tooling*, not an iOS-26
runtime feature; runs back to old iOS. iOS 26 is just our floor). It's a JSON file Xcode auto-populates
from `Text("…")` / `String(localized:)`, tracking a per-locale translation *state* — the machine surface
that makes delta-detection + automation possible. Base/development language is **English**;
**"Poimi"** (display name) is never translated.

**The real audit surface is the *non-`Text`* strings.** Correcting the first draft: `Text("\(x) of \(y) kept")`
auto-extracts fine as a **format key** (`%lld of %lld kept`) — that's the *easy* part. The miss-risk is
the **~21 `accessibilityLabel/Value/Hint` sites** (plain interpolated `String`s → do **not**
auto-extract → each needs `String(localized:)`), plus **variable/composed `Text(title)`** whose value
must be localized at its source. The app target already has `SWIFT_EMIT_LOC_STRINGS = YES`, so
extraction is ready once the catalog exists.

**Invariant:** user-facing strings live in the **app layer only**; `Curation` stays string-free
(reinforces D14/D21 — today it has only a dev-facing `debugDescription`).

## Scope — localize more than release notes
1. **`Localizable.xcstrings`** — the UI.
2. **`InfoPlist` strings** — the **`NSPhotoLibraryUsageDescription`** permission prompt is user-facing
   and **App Review requires it localized** (a separate catalog/`.strings` surface; a first-draft omission).
3. **App Store metadata per locale** — subtitle, **keywords** (our docs flag discoverability given the
   opaque name), description, promo, *and* release notes — not release notes alone.
4. **Localized screenshots** — reuse the DEBUG screenshot harness with `-AppleLanguages (fi)` to eyeball
   real translations + capture per-locale App Store shots.
5. **`knownRegions` / `CFBundleLocalizations`** gain each target locale (setup step).

## Phasing (reframed: minimal now, graduate later)
- **Phase 0 — ✅ DONE (2026-07-03):** created `Localizable.xcstrings` + added to the target (populated
  by `-exportLocalizations`); adopted **localizable-by-default** (CLAUDE.md convention — new screens use
  `Text`/`String(localized:)`, DEBUG strings use `Text(verbatim:)`); stated the Curation-string-free
  invariant. English-only.
- **Phase 1 — in progress.** The **bulk retro-audit is ✅ DONE (2026-07-03):** the composed UI strings
  + a11y helpers now use `String(localized:, comment:)`, and every `Text("a" + "b")` (which resolves to
  the *verbatim* overload → wouldn't localize) is now a single localizable literal (`"""` where long);
  **"Poimi" stays verbatim** (app name). The catalog covers the resolved surface (~166 keys). **Still
  pending in Phase 1:** register `fi` in `knownRegions`; `InfoPlist.xcstrings` for the Photos-permission
  prompt; the **glossary + style guide** (`localization/glossary.md`, `style.md`); and the DebugScreen
  `Text` → `Text(verbatim:)` cleanup (dev strings still in the catalog).
- **Phase 2 — MANUAL translation MVP (no CI):** a script run **at release**: export → detect delta →
  Claude translates the delta (fed the catalog + glossary explicitly) → import → validate → open a PR;
  **native-speaker sign-off** on each new locale's baseline. Delivers ~all the value with none of the
  CI cost.
- **Phase 3 — CI, only when volume justifies:** `localize.yml` (below) with the completeness gate +
  a real pseudoloc pass.
- **Phase 4 — release notes + store metadata:** Claude drafts English notes from the changelog →
  translate → upload via **`fastlane deliver`** behind a manual-approval gate.

## The write path (deterministic — do NOT hand-edit the JSON)
- **Delta detection = read-only** parse of the `.xcstrings` JSON (`jq`/script) → the per-locale set of
  new/missing keys.
- **Write-back = the official XLIFF round-trip**: `xcodebuild -exportLocalizations -project … -localizationPath …`
  → translate the XLIFF → `-importLocalizations`. Xcode owns the mutation (a raw `jq` write drifts from
  Xcode's normalization → churn/conflicts). **Extract/refresh the catalog in CI before diffing** (new
  `Text()` only lands on a build). Serialize the workflow (`concurrency` group) + rebase — a source-string
  change racing a translation PR conflicts on the single catalog.

## Translation engine (Claude)
- **Manual MVP / headless Claude Code:** with the repo checked out it *sees* the catalog + prior
  translations + glossary → consistent terminology + UI-aware brevity.
- **A raw Anthropic-API script does NOT auto-see the repo** — it must explicitly read + pass the
  catalog/glossary in the prompt.
- **CI (Phase 3):** `ANTHROPIC_API_KEY` secret, **minimal `contents`/`pull-requests` permissions**, and a
  **guard against secret exposure on fork-PR triggers**.

## Trust & QA gates (before shipping any non-English locale)
- **Native-speaker baseline sign-off, per locale.** Claude-translate + Claude-review is a same-model
  echo chamber, and a non-speaker "approval" only confirms placeholders — a fluent-but-wrong string would
  ship. Require a human who reads the language to sign off the **baseline** (+ high-visibility strings:
  onboarding, permission prompt, App Store copy); small **deltas over a verified baseline** may then ride
  the auto-review.
- **Hard completeness gate for *shipped* locales** — iOS silently falls back to English, so a partial
  locale ships English-mixed with no error. Distinguish **in-progress** (fallback OK, not shipped) from
  **shipped** (100% coverage, **CI-blocking**).
- **Real truncation verification** — a length heuristic passes strings that still clip a fixed-width
  button (Pick / Select all / the tally). Add a per-locale **screenshot/device pass** of the tight
  screens for launch locales. NB reconcile with **D26** (pixel-snapshot testing deferred): a *narrow*
  localization-screenshot check or a manual per-locale pass, not the full snapshot tier.
- **Plural-category validation** — generate + validate the catalog's `variations.plural` cases per
  target language's CLDR rules (Arabic = 6 forms), not a flat `other`.
- **Placeholder validation = exact identity/type/ORDER**, not counts (`%1$@`/`%2$@` swapped passes a
  count check); preserve plural-variation structure.
- **Back-translation + uncertainty flags** — round-trip (target→English, diff vs source) to catch meaning
  drift; have the translator flag idioms/ambiguous source → route only those to a human.
- **Meaning-drift re-flag** — tie the catalog **`comment:` (context) field** to re-flagging: a changed
  comment re-opens the key (a same-text/shifted-meaning string otherwise stays wrong + unflagged).
- **Periodic full-catalog reviewer pass** — deltas-only lets tone drift; a scheduled full pass keeps voice
  consistent.
- **Tests for the new scripts** — the delta-detection + write-back + validation are the code the repo
  owns, and this project ships tests with code. Fixture-based: `.xcstrings` in each state (new/edited key,
  missing plural category, mismatched placeholder, complete) + the release-notes plumbing.

## Tools (dependency-minimal)
- **`xcodebuild -exportLocalizations`/`-importLocalizations`** — the **primary** write path (XLIFF).
- **`jq` + a small script** — read-only delta detection + validation (no new library).
- **`fastlane deliver`** — App Store metadata + release notes. **Preferred over a hand-rolled ASC-API
  script**: it's dev/release tooling (never in the shipped binary), so the app's dependency-minimalism rule
  (about the app's SPM deps) doesn't apply — and it already solves the fragile plumbing (ES256-JWT auth, the
  editable-version lookup, `appStoreVersionLocalizations`, locale-code mapping `en-US`/`en-GB`, the
  first-version-skips-notes wrinkle). A hand-rolled ASC-API script is the fallback only if avoiding the Ruby
  dep outweighs the plumbing it saves (not recommended). Needs a `Deliverfile`/metadata bootstrap.
- **Xcode pseudolocalization** (Accented / Double-Length) — but only useful with a **concrete screenshot/UI
  test pass** under those languages; as a bare mention it catches nothing.
- **Claude** — headless Claude Code (repo-aware) or an API script (fed the content).

## Cut / simplified from the first draft (per the review)
- **No custom "no hardcoded user-facing string" CI guard** — fiddly + false-positive-prone in SwiftUI
  (user-facing `Text` vs SF Symbol names vs a11y ids vs debug strings). Pseudoloc + the review habit catch
  un-externalized strings for far less maintenance.
- **fastlane is the ASC recommendation** (reversed from the first draft): it's dev tooling, not a shipped
  SPM dep — the minimalism rule is about the app binary — and a hand-rolled ASC-API script just
  re-implements the JWT + version-state plumbing `deliver` already solves.
- **English-notes-from-commits** kept as a bonus, not a first build (writing 2–3 lines isn't the bottleneck).

## Decisions
1. **Initial locales — DECIDED: base `en` + `fi`.** Expand to a tier-1 set (`de`/`fr`/`es`/`ja`/…) later;
   cost is per-delta, so adding languages is cheap.
2. **Trust model — recommended: native-speaker baseline sign-off** per launch locale, then auto-review
   for incremental deltas over that verified baseline. (Lock at Phase 2.)
3. **ASC automation — recommended: in-repo half first** (catalog + notes files); wire the ASC-API upload
   + key + gate in Phase 4.
4. **Now vs deferred — UPDATED: Phase 0 built (2026-07-03), rest deferred.** With Phase 2 (#30–#43)
   complete the v1 English UI is stable, so Phase 0 (the catalog + localizable-by-default) shipped. The
   Phase 1+ code below stays **illustrative** (how each step would be built), not committed — built when
   each step's value justifies it.

## Implementation detail (illustrative — plan only, not committed)

Concrete sketches so this is build-ready when v1 English is stable. Paths assume `Scripts/localize/`.
**Helpers are stdlib-only** (shell + Python `xml.etree`/`json`/`re` — no pip toolchain); the translator is
**`claude -p`** (the sanctioned, repo-aware tool), not an SDK. Versions/paths below are **build-time
placeholders** (they'll drift before this is built), not pinned values.

### 1. Project bootstrap (Phase 1, one-time)
- In Xcode: **File ▸ New ▸ File ▸ String Catalog** → `App/PoimiApp/Resources/Localizable.xcstrings`, added
  to the app target. (`SWIFT_EMIT_LOC_STRINGS = YES` is already set, so a build auto-extracts.)
- Add **`fi`** to the project's localizations (Project ▸ Info ▸ Localizations) → writes `fi` into
  `knownRegions`. The **pbxproj is hand-authored** (no XcodeGen) — keep the diff to that one change +
  `plutil -lint` after (repo discipline).
- Add an **`InfoPlist.xcstrings`** for `NSPhotoLibraryUsageDescription` (+ any other Info.plist UI strings).
- **Author plurals** for the count strings — **English itself needs `one`/`other`** ("1 photo" / "2 photos"),
  today flat format strings; move them to the catalog's `variations.plural` (not just a flat `%lld`).
- Retro-audit the **non-`Text` strings** — every `accessibilityLabel/Value/Hint` and any `Text(variable)`:
  ```swift
  // before
  .accessibilityLabel("\(title). \(group.count) photos, \(selectedCount) selected.")
  // after — a localized format key (comment gives the translator context)
  .accessibilityLabel(String(localized: "\(title). \(group.count) photos, \(selectedCount) selected.",
                             comment: "Day-group header a11y summary"))
  ```

### 2. Delta detection + the XLIFF round-trip
```sh
xcodebuild -exportLocalizations -project App/PoimiApp.xcodeproj -localizationPath ./loc -exportLanguage fi
#   → ./loc/fi.xcloc/Localized Contents/fi.xliff   ;   … fill state="new" units (step 3) …
xcodebuild -importLocalizations -project App/PoimiApp.xcodeproj -localizationPath ./loc/fi.xcloc
```
- **Export re-extracts current source strings *into the XLIFF*** (so the delta reflects new `Text()` even
  if the committed `.xcstrings` is stale) — but it does **not** rewrite the committed catalog; that happens
  on **import**. `-exportLanguage fi` requires `fi` already in `knownRegions` (§1). A **brand-new locale's
  first export = the whole catalog** (full first run; per-delta after).
- The **delta = units with `state="new"`/`needs_review`** — untranslated units export with `<target>` =
  source + `state="new"`, *not* empty; key on state. **Gitignore `./loc`** so the export bundle isn't committed.
- (Report-only, plural-blind: `jq '… .localizations.fi.stringUnit.state …'` on the JSON has no `stringUnit`
  for plural-varied keys, so don't build the delta on it — the real delta is the XLIFF. Reading the JSON is
  fine; never *write* it by hand.)

### 3. Translate the XLIFF (`claude -p`)
`translate-xliff.py` (stdlib `xml.etree` — **handle the XLIFF 1.2 namespace** `urn:oasis:names:tc:xliff:document:1.2`)
collects `state="new"` units (`source` + `note`), shells out to **`claude -p`** with the glossary/style
prepended, writes `<target state="translated">` back, then `-importLocalizations`. The `claude -p` call is
an **injectable seam** (a stub translator for tests — §8), so no SDK/pip dep.
```
prompt (glossary + style prepended, from localization/glossary.md + style.md):
"Translate Poimi's iOS UI strings to Finnish (fi). Rules:
 - 'Poimi' is the APP NAME — never translate it.
 - Preserve every format specifier (%lld, %@, %1$@, %2$@) EXACTLY and IN THE SAME ORDER.
 - UI strings are buttons/labels — keep them short.  Tone: calm, plain, sentence case, no '!'.
 - <glossary: album = albumi, never 'vuosikirja'/yearbook; …>
 Return ONLY JSON {"<trans-unit id>": "<fi translation>"}."   ← the units passed as JSON
```
- **The first `fi` baseline doesn't need the script** — Xcode's catalog editor or a one-shot `claude -p`
  paste is simpler; `translate-xliff.py` earns its keep on **ongoing deltas**.

### 4. Validation (`validate.py`, gates the PR) — checks presence + format, NOT correctness (that's the native reviewer)
- **Placeholders — full printf grammar, identity + order.** The naive `%(?:\d+\$)?[@a-zA-Z]` is
  **INSUFFICIENT** — it mis-parses `%lld` (grabs `%l`) and misses width/`.precision`. Requirement: match
  flags/width/`.precision`/length-modifiers/conversion, e.g.
  `%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|j|t)?[@diouxXeEfgGaAcsSpn]`; **exclude `%%`**; source vs
  target must be an equal *sequence*. Require **positional args (`%1$@`)** in any source with ≥2 specifiers
  (else a word-order reorder of `%@ of %@` is undetectable).
- **Plurals**: `variations.plural` must carry every CLDR category the target needs. **en + fi are both
  `one`/`other` (near-trivial)** — this validator is really for future tier-1 locales (ar = 6, ru/pl = 3–4),
  whose extra categories **can't be added via the XLIFF round-trip** (no trans-units for them) → a
  direct-catalog path when those land. Source list: a small hardcoded CLDR table.
- **Completeness gate**: reads the `.xcstrings` **JSON state directly** (no heavy re-export); covers **both
  `Localizable` and `InfoPlist`**. For a **shipped** locale, any `new`/missing unit → **exit non-zero**
  (block); **in-progress** locales exempt (English fallback OK).

### The source of truth — `localization/locales.yml`
The gates above are prose without one config to mechanize "shipped vs in-progress" and "verified baseline":
```yaml
en: { status: source }
fi: { status: in-progress, baseline_signed_off_at: null }   # → status: shipped + a commit/tag once a native speaker signs off
```
`status` drives the completeness gate; `baseline_signed_off_at` gates *auto-review of deltas* vs
*native-review-required* (a null baseline ⇒ the whole locale needs human sign-off, not just the delta).

### 5. CI — `.github/workflows/localize.yml` (Phase 3)
```yaml
name: Localize
on:
  push: { branches: [main], paths: ['App/PoimiApp/**/*.swift', 'App/PoimiApp/**/*.xcstrings'] }
  workflow_dispatch:
concurrency: { group: localize, cancel-in-progress: false }   # one at a time → no catalog races
permissions: { contents: write, pull-requests: write }        # minimal scope
jobs:
  translate:
    runs-on: macos-15                # reuse ci.yml's runner + Xcode-select step — don't re-pin (these drift)
    steps:
      - uses: actions/checkout@v4    # (image / action versions are placeholders — copy ci.yml's at build time)
      - run: xcodebuild -exportLocalizations -project App/PoimiApp.xcodeproj -localizationPath ./loc -exportLanguage fi
      - run: python3 Scripts/localize/translate-xliff.py "./loc/fi.xcloc/Localized Contents/fi.xliff" --glossary localization/
        env: { ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }} }
      - run: xcodebuild -importLocalizations -project App/PoimiApp.xcodeproj -localizationPath ./loc/fi.xcloc
      - run: python3 Scripts/localize/validate.py
      - run: |                                                 # branch/PR for human (+ native) sign-off
          git diff --quiet -- 'App/PoimiApp/**/*.xcstrings' && { echo "no delta"; exit 0; }   # empty-delta guard
          git switch -c "i18n/auto-${{ github.run_id }}"
          git commit -am "chore(i18n): fi translations"
          git push -u origin HEAD                             # gh pr create needs the branch on the remote
          gh pr create -t "chore(i18n): fi translations" -b "Auto-translated delta — needs native-speaker review." -l i18n
        env: { GH_TOKEN: ${{ github.token }} }
```
(`./loc` is gitignored so the export bundle isn't swept into `commit -am`.)
> Secret guard: a `push`-to-`main` trigger doesn't run on fork PRs, so the API key isn't exposed to
> forks. If a `pull_request` trigger is ever added, gate the translate step on
> `github.event.pull_request.head.repo.full_name == github.repository`.

### 6. Release notes + store metadata (Phase 4) — use `fastlane deliver`
- English notes: `claude -p` over `git log <lastTag>..HEAD` (merged PR titles) → 2–3 lines → translate to
  each locale (same engine) → write `fastlane/metadata/<locale>/{release_notes,subtitle,keywords,description}.txt`.
- **Upload with `fastlane deliver`** behind a **manual-approval environment**. `fastlane` is dev/release
  tooling (never in the shipped binary), so the app's dependency-minimalism rule doesn't apply — and it
  already solves the plumbing a hand-rolled script would re-implement: ES256-JWT auth, **creating/finding
  the editable `PREPARE_FOR_SUBMISSION` version** (it may not exist between releases — you must create it
  first), traversing `appStoreVersionLocalizations` → `whatsNew`, locale-code mapping (`en-US`/`en-GB`), and
  the *skips-notes-on-a-first-version* wrinkle. (A hand-rolled ASC-API script is the fallback only if the
  Ruby dep is unacceptable — not recommended.)

### 7. Manual MVP (Phase 2 — the whole loop, run by hand at release)
```sh
Scripts/localize/translate.sh fi   # = export → translate-xliff.py (claude -p) → import → validate.py
# then: review the diff, get a native-speaker OK on a new locale's baseline, commit, open a PR.
```

### 8. Tests (stdlib, ship with the scripts; translator stubbed)
Fixture `.xcstrings`/XLIFF, asserting both fail AND pass/ignore paths:
- **delta detection**: finds `new`/`needs_review` units, **ignores already-`translated` keys** (the core
  "only deltas" promise), and handles a plural key.
- **completeness gate**: **fails a partial *shipped* locale**, **passes an *in-progress* one**, covers `InfoPlist`.
- **placeholder validator**: rejects a dropped / added / type-changed / reordered specifier — incl. a
  **`%lld` fixture** (would have caught the regex bug); accepts `%%`.
- **plural validator**: rejects a missing category; **accepts a complete one**.
- **release-notes plumbing**: changelog extraction + file placement (LLM output stubbed).
The `claude -p` call is an **injectable stub** (echo/pseudo translator) so the export→translate→import
round-trip is testable without a live API call.

## Risks / notes
- The **retro string audit** is the real up-front cost (a11y strings especially) — deferred to Phase 1
  so it isn't re-done as unbuilt screens land.
- **Machine-translation quality** — glossary + native baseline sign-off + human gate are the mitigations;
  close to hands-off for *deltas*, never fully hands-off for a *new locale's baseline*.
- **RTL / grammatical gender** — parked; if Arabic/Hebrew enter scope, add a mirrored-layout pass.
