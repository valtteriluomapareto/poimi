# Localization plan — multi-locale UI + automated translation & release notes

**Status:** plan / not yet built. Tracks [#95]. How Poimi supports multiple languages while
**minimizing manual maintenance** — translation and release notes automated via GitHub Actions +
Claude + open CLI tools, dependency-minimal. The open decisions at the end are logged as `D39+` once
confirmed; this doc is the proposal.

## Goals

- Ship Poimi in multiple locales/languages.
- **Minimize manual maintenance** — no hand-translating each UI string; consistency without re-deciding.
- **Automate release notes** across languages (today: a lot of manual work on every update).

## Foundation — a String Catalog (the enabler)

Migrate user-facing strings to **`Localizable.xcstrings`** (the Xcode 15+/iOS 26-native String
Catalog). Everything downstream depends on this:

- It's a single **JSON** file Xcode auto-populates from `Text("…")` / `String(localized:)`, tracking a
  per-locale translation *state*. So a script can find exactly which keys are untranslated per locale
  and write translations back — the machine surface that makes automation possible.
- The base / development language is **English** (the current UI). **"Poimi"** (the app name) is never
  translated.

### Groundwork (one-time)

- **String audit** — externalize every user-facing string. Most are already `Text("…")` (auto-extracted
  for free); the real work is the **interpolated** ones (`"\(picked) of \(count) kept"`,
  `"\(remaining) left"`) → localized format strings (the catalog handles positional args + plural
  variations). Dates/numbers are already locale-safe via `FormatStyle`.
- **Glossary + style guide** (`localization/glossary.md`, `localization/style.md`) — the versioned
  translation prompt AND the reviewer's rubric: brand terms untranslated ("Poimi"); the
  **album-not-yearbook** rule per language; tone (calm, plain, human).
- **CI guard** — a "no hardcoded user-facing string" check (in the spirit of the four existing guards)
  + **pseudolocalization** in CI (Accented / Double-Length) to catch un-externalized strings + truncation.

## Workflow ① — UI string translation (`.github/workflows/localize.yml`)

Trigger: a push to `main` touching `Localizable.xcstrings` (or manual / scheduled).

1. **Diff** the catalog → the per-locale set of new/missing/`"new"`-state keys — the **delta only**, so
   cost scales with *changes*, not with the number of languages.
2. Feed the delta + each key's comment + the glossary + style guide to **Claude** → translations, with
   **placeholders / format specifiers preserved**.
3. **Write back** into the catalog; **validate** — placeholder counts match the source, nothing missing,
   a length heuristic for UI-critical keys.
4. Open a **PR** (`chore(i18n): fr, de, …`). A **second Claude pass reviews** it (back-translation,
   tone, fit) and comments; a human approves. (Approve-not-write is the maintenance win.)

## Workflow ② — release notes (`.github/workflows/release-notes.yml`)

Trigger: a GitHub Release published (or a tag).

1. Claude **drafts the English notes from the merged PRs / commits** since the last tag (semi-automates
   even the English) — or hand-edit them.
2. **Translate** to every locale → `fastlane/metadata/<locale>/release_notes.txt`.
3. **`fastlane deliver`** / the App Store Connect API uploads the metadata, behind a **manual-approval
   GitHub environment** — a store-facing push is never fully unattended.

## Claude's roles

- **Translator (CI, headless):** with the repo checked out it sees the *whole* catalog + prior
  translations + the glossary, so terminology stays consistent and it reasons about UI context ("this
  is a button — keep it short"). Better than naive per-string API calls.
- **Reviewer:** a QA pass on the translation PR.
- **Release-notes author:** a diff → English notes → N languages.

## Tools (dependency-minimal)

- **`xcodebuild -exportLocalizations` / `-importLocalizations`** — the official XLIFF round-trip, if
  preferred over editing `.xcstrings` directly.
- **`fastlane deliver`** — App Store metadata + release notes (the mature, standard choice).
- **`jq` + a small script** — query / patch the catalog JSON (no new library — fits dependency-minimalism).
- **Xcode pseudolocalization** (Accented / Double-Length) — CI truncation + un-externalized-string check.
- **Claude** in CI (headless Claude Code, or a script on the Anthropic API) — translate + review + notes.

## Guardrails

- **Placeholders / format specifiers preserved** — validated, not trusted.
- **Glossary** — brand terms untranslated; terminology consistency; the no-yearbook rule per language.
- **Length budget** for UI-critical strings (buttons, the tally) + pseudoloc as the net.
- **Human-in-the-loop** — translations land as PRs; store pushes are gated.
- **RTL** (Arabic / Hebrew, if targeted) — SwiftUI largely handles it; verify layout.

## Low-maintenance by design

Deltas only · glossary-driven consistency · approve-not-write PRs · notes generated from the changelog
· pseudoloc as the regression net.

## Phasing

- **Phase 1 — foundation:** String Catalog migration + string audit + glossary/style + the CI guard +
  pseudoloc. Still English-only, but every string externalized.
- **Phase 2 — translation workflow:** `localize.yml` + the Claude translator + validation + reviewer;
  add the first locales.
- **Phase 3 — release notes:** `release-notes.yml` + `fastlane deliver` / ASC API + the approval gate.

## Open decisions (recommended defaults — confirm before building)

1. **Initial locales** — *recommend* base `en` + **`fi`** to start (founder's language / likely first
   market), then expand to a tier-1 set (`de` / `fr` / `es` / `ja` / …). Cost is per-delta, so adding
   languages later is cheap.
2. **Trust model** — *recommend* **always PR-review** translations initially; move to
   auto-merge-behind-checks for low-risk keys once trust builds.
3. **ASC automation timing** — *recommend* build the **in-repo half first** (catalog + release-notes
   files, Phases 1–2); wire `fastlane deliver` + the ASC API-key secret + the gate in Phase 3.

## Risks / notes

- The **string audit** is the real up-front cost — it touches every user-facing view.
- **Plurals / grammatical gender** — the catalog's variations handle plurals; some languages need care
  (Claude + the catalog's variation support).
- **Machine-translation quality** — the glossary + the reviewer pass + human approval are the
  mitigations; not fully hands-off for a shipping product, but close.
