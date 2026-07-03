# Localization glossary — Poimi

The canonical translations of Poimi's key terms, so every locale stays consistent (#95). A translator
(human or `claude -p`) is fed this file with each translation batch. **English is the source.**

## Never translate
- **Poimi** — the app name. Keep it verbatim in every language, mid-sentence and as a title.
- **Photos** — when it means the Apple **Photos app / library** (a product name), keep the platform's
  own localized product name; do not invent a translation. (Lowercase "photos" = the images → translate.)
  In **`fi`** this resolves to **Kuvat** (Apple's Finnish name for the Photos app) — e.g. *Kuvat-albumi*,
  *Kuvat-kirjasto*, *Kuvat-sovellus*. **Open for native review** — some Finnish users know it as "Photos".
- **GitHub**, **iOS**, **Settings** (the iOS app) — platform/product names; use Apple's localized form
  where one exists, otherwise verbatim.

## Core terms (English → Finnish `fi`)
| English | Finnish (`fi`) | Notes |
| --- | --- | --- |
| album | albumi | **Never** *vuosikirja* / "yearbook" — Poimi has no yearbook/printing concept. |
| pick (verb) | poimia | The core action — choosing a photo. The **"Pick" button = *Poimi*** (the imperative — same word as the app name, deliberately on-brand). **Open for review**: some may prefer *Valitse* to avoid the app-name echo. |
| picked | poimittu | The selected state (badge / count). *Not started/in progress/done* status uses its own terms. |
| select (verb) | valita / Valitse | Kept **distinct from pick** — UI selection (select-all etc.), not the curation action. |
| photo | kuva | Lowercase, the image. Count + noun uses the partitive: *%lld kuvaa*. |
| kept | säilytetty | Completion stat — how many picks survived. |
| access (photo/library) | käyttöoikeus | *Full/Limited/Off/Not set* → *Täysi / Rajattu / Pois päältä / Ei asetettu*. |
| review | käydä läpi / arvioida | Going through a day's photos. |
| done (marked done) | valmis | A day/cluster the user has finished reviewing. |
| range / date range | ajanjakso | The album's period. |
| exclude / excluded | jättää pois / poissuljettu | Screenshots + excluded albums dropped from the source. |
| screenshot | kuvakaappaus | |
| export | vie / tallenna | Writing picks into a Photos album (one-way copy). |
| target / aim for | tavoite | The count you aim toward. |

> The `fi` column is a **drafted baseline (2026-07-03, Claude)** — the full v1 UI (174 keys) is translated
> in `Localizable.xcstrings` and eyeballed on every screen via the screenshot harness under `-AppleLanguages (fi)`.
> A **native speaker still signs off** before it ships (Phase 2). Items flagged "Open for review" above are the
> deliberate judgement calls. Add a row when a new product term appears; keep the "never translate" list authoritative.
