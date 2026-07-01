# Localization plan — multi-locale UI + automated translation & release notes

**Status: DEFERRED SPEC — not build-it-now.** Tracks [#95]. Revised after a 3-persona + Codex review
(see PR #96). **Precondition: don't build the automation until the v1 English UI is stable** — export
(#39), select-mode (#91), settings (#41), iPad (#42) are unbuilt and the surface is still moving (the
accordion landed mid-Phase-2). Building translation infra now means maintaining it while what it
translates keeps changing.

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
- **Phase 0 — now, cheap:** create `Localizable.xcstrings` + add to the target; adopt
  **localizable-by-default** (every new screen uses `Text`/`String(localized:)` from the start); state
  the Curation-string-free invariant. English-only. Near-zero marginal cost; avoids a bigger retro.
- **Phase 1 — after v1 English is stable:** one **bulk retro-audit** (focus: the a11y/non-`Text`
  strings) + `InfoPlist` localization + register the first locales in `knownRegions` + write the
  **glossary + style guide** (`localization/glossary.md`, `style.md`).
- **Phase 2 — MANUAL translation MVP (no CI):** a script run **at release**: export → detect delta →
  Claude translates the delta (fed the catalog + glossary explicitly) → import → validate → open a PR;
  **native-speaker sign-off** on each new locale's baseline. Delivers ~all the value with none of the
  CI cost.
- **Phase 3 — CI, only when volume justifies:** `localize.yml` (below) with the completeness gate +
  a real pseudoloc pass.
- **Phase 4 — release notes + store metadata:** Claude drafts English notes from the changelog →
  translate → upload via the **App Store Connect API** behind a manual-approval gate.

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
- **App Store Connect API** (a small script) — **preferred over `fastlane`** to stay lean; `fastlane
  deliver` is an option but a heavy Ruby/gems dep (dev-only, so acceptable, but ASC-API is leaner). If
  fastlane: it needs a `Deliverfile`/metadata bootstrap, ASC locale-code mapping (`en-US` vs `en-GB`), an
  editable app version, and note it **skips release notes on a first App Store version**.
- **Xcode pseudolocalization** (Accented / Double-Length) — but only useful with a **concrete screenshot/UI
  test pass** under those languages; as a bare mention it catches nothing.
- **Claude** — headless Claude Code (repo-aware) or an API script (fed the content).

## Cut / simplified from the first draft (per the review)
- **No custom "no hardcoded user-facing string" CI guard** — fiddly + false-positive-prone in SwiftUI
  (user-facing `Text` vs SF Symbol names vs a11y ids vs debug strings). Pseudoloc + the review habit catch
  un-externalized strings for far less maintenance.
- **fastlane demoted** to optional (ASC API preferred).
- **English-notes-from-commits** kept as a bonus, not a first build (writing 2–3 lines isn't the bottleneck).

## Decisions
1. **Initial locales — DECIDED: base `en` + `fi`.** Expand to a tier-1 set (`de`/`fr`/`es`/`ja`/…) later;
   cost is per-delta, so adding languages is cheap.
2. **Trust model — recommended: native-speaker baseline sign-off** per launch locale, then auto-review
   for incremental deltas over that verified baseline. (Lock at Phase 2.)
3. **ASC automation — recommended: in-repo half first** (catalog + notes files); wire the ASC-API upload
   + key + gate in Phase 4.
4. **Now vs deferred — DECIDED: plan only.** No repo code yet (not even Phase 0) — this doc is the
   detailed, implementation-ready spec, revisited for build once the v1 English UI is stable. The code
   below is **illustrative** (how each step would be built), not committed files.

## Implementation detail (illustrative — plan only, not committed)

Concrete sketches so this is build-ready when v1 English is stable. Paths assume `Scripts/localize/`.

### 1. Project bootstrap (Phase 1, one-time)
- In Xcode: **File ▸ New ▸ File ▸ String Catalog** → `App/PoimiApp/Resources/Localizable.xcstrings`, added
  to the app target. (`SWIFT_EMIT_LOC_STRINGS = YES` is already set, so a build auto-extracts.)
- Add **`fi`** to the project's localizations (Project ▸ Info ▸ Localizations) → writes `fi` into
  `knownRegions` in `project.pbxproj`.
- Add an **`InfoPlist.xcstrings`** for `NSPhotoLibraryUsageDescription` (+ any other Info.plist UI strings).
- Retro-audit the **non-`Text` strings** — every `accessibilityLabel/Value/Hint` and any `Text(variable)`:
  ```swift
  // before
  .accessibilityLabel("\(title). \(group.count) photos, \(selectedCount) selected.")
  // after — a localized format key (comment gives the translator context)
  .accessibilityLabel(String(localized: "\(title). \(group.count) photos, \(selectedCount) selected.",
                             comment: "Day-group header a11y summary"))
  ```

### 2. Delta detection + the XLIFF round-trip
Export is Xcode-owned (safe); it also **re-extracts** strings from source, so it doubles as the refresh:
```sh
# Export → an .xcloc bundle per language; untranslated units have empty/`state="new"` <target>s.
xcodebuild -exportLocalizations \
  -project App/PoimiApp.xcodeproj \
  -localizationPath ./loc-export \
  -exportLanguage fi
# → ./loc-export/fi.xcloc/Localized Contents/fi.xliff

#  … fill empty <target>s (step 3) …

# Import back — Xcode writes the catalog canonically (no hand-edited JSON drift).
xcodebuild -importLocalizations \
  -project App/PoimiApp.xcodeproj \
  -localizationPath ./loc-export/fi.xcloc
```
The **delta** = the XLIFF trans-units with no/`new` target. (For read-only reporting, `.xcstrings` is JSON:
`jq -r '.strings|to_entries[]|select((.value.localizations.fi.stringUnit.state // "missing")|test("missing|new|needs_review"))|.key' Localizable.xcstrings` — but never write it by hand; use XLIFF import.)

### 3. Translate the XLIFF (Claude)
`translate-xliff.py` — parse the XLIFF, collect empty-target units (`source` + `note`), one Claude call,
write `<target>`s back. CI-portable (Anthropic API, fed the content explicitly — a raw script does *not*
auto-see the repo); headless `claude -p` is the repo-aware alternative for the manual MVP.
```python
# prompt (glossary + style prepended, from localization/glossary.md + style.md):
SYSTEM = """Translate Poimi's iOS UI strings to Finnish (fi). Rules:
- "Poimi" is the APP NAME — never translate it.
- Preserve every format specifier (%lld, %@, %1$@, %2$@) EXACTLY and IN THE SAME ORDER.
- UI strings are buttons/labels — keep them short.
- Tone: calm, plain, human; sentence case; no exclamation marks.
- <glossary + album=albumi, never 'vuosikirja'/yearbook, …>
Return ONLY JSON {"<trans-unit id>": "<fi translation>"}."""
# → anthropic.messages.create(model="claude-...", system=SYSTEM, messages=[{... the units as JSON ...}])
# → write each translation into the matching <target state="translated">, then xcodebuild -importLocalizations
```

### 4. Validation (`validate.py`, gates the PR)
- **Placeholders — identity + order**, not counts: `re.findall(r'%(?:\d+\$)?[@a-zA-Z]', s)` on source vs
  target must be an equal *sequence*.
- **Plurals**: any `variations.plural` key must carry every CLDR category the language needs (`fi`: `one`,
  `other`; e.g. `ar`: 6). Fail if a category is missing.
- **Completeness gate (shipped locales only)**: re-export after import; if any unit for a *shipped* locale
  is still empty/`new` → **exit non-zero** (block). *In-progress* locales are exempt (English fallback OK).

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
    runs-on: macos-15                                          # Xcode 26 image
    steps:
      - uses: actions/checkout@v4
      - run: sudo xcode-select -s /Applications/Xcode_26.app
      - run: xcodebuild -exportLocalizations -project App/PoimiApp.xcodeproj -localizationPath ./loc -exportLanguage fi
      - run: python3 Scripts/localize/translate-xliff.py "./loc/fi.xcloc/Localized Contents/fi.xliff" --glossary localization/
        env: { ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }} }
      - run: xcodebuild -importLocalizations -project App/PoimiApp.xcodeproj -localizationPath ./loc/fi.xcloc
      - run: python3 Scripts/localize/validate.py
      - run: |                                                 # branch/PR for human (+ native) sign-off
          git switch -c "i18n/auto-${{ github.run_id }}"
          git commit -am "chore(i18n): fi translations"
          gh pr create -t "chore(i18n): fi translations" -b "Auto-translated delta — needs native-speaker review." -l i18n
        env: { GH_TOKEN: ${{ github.token }} }
```
> Secret guard: a `push`-to-`main` trigger doesn't run on fork PRs, so the API key isn't exposed to
> forks. If a `pull_request` trigger is ever added, gate the translate step on
> `github.event.pull_request.head.repo.full_name == github.repository`.

### 6. Release notes + store metadata (Phase 4)
- English notes: `claude -p` over `git log <lastTag>..HEAD` (merged PR titles) → 2–3 lines → translate to
  each locale (same engine) → write `metadata/<locale>/release_notes.txt` (+ subtitle/keywords/description).
- Upload via the **App Store Connect API** (a script, no fastlane): ES256-JWT (issuer id + key id + `.p8`,
  `aud: appstoreconnect-v1`) → GET the editable `appStoreVersion` → PATCH each
  `appStoreVersionLocalizations/{id}` `whatsNew` (+ locale metadata). Behind a **manual-approval
  environment**. (`fastlane deliver` wraps all of this if the JWT/version-state plumbing isn't worth
  hand-rolling — the tradeoff is the heavy Ruby dep vs a ~100-line script. Note deliver *skips* notes on a
  first-ever version.)

### 7. Manual MVP (Phase 2 — the whole loop, run by hand at release)
```sh
Scripts/localize/translate.sh fi   # = export → translate-xliff.py (claude -p) → import → validate.py
# then: review the diff, get a native-speaker OK on a new locale's baseline, commit, open a PR.
```

### 8. Tests (ship with the scripts)
Fixture `.xcstrings`/XLIFF in each state — a new key, an edited key, a missing plural category, a
swapped-placeholder target, a complete locale — assert: delta detection finds exactly the untranslated
keys; the completeness gate fails a partial *shipped* locale and passes an in-progress one; the
placeholder/plural validators reject the bad fixtures. Plus the release-notes changelog-extraction +
file-placement plumbing (the LLM output isn't unit-testable; the plumbing is).

## Risks / notes
- The **retro string audit** is the real up-front cost (a11y strings especially) — deferred to Phase 1
  so it isn't re-done as unbuilt screens land.
- **Machine-translation quality** — glossary + native baseline sign-off + human gate are the mitigations;
  close to hands-off for *deltas*, never fully hands-off for a *new locale's baseline*.
- **RTL / grammatical gender** — parked; if Arabic/Hebrew enter scope, add a mirrored-layout pass.
