# Localization glossary — Poimi

The canonical translations of Poimi's key terms, so every locale stays consistent (#95). A translator
(human or `claude -p`) is fed this file with each translation batch. **English is the source.**

## Never translate
- **Poimi** — the app name. Keep it verbatim in every language, mid-sentence and as a title.
- **Photos** — when it means the Apple **Photos app / library** (a product name), keep the platform's
  own localized product name; do not invent a translation. (Lowercase "photos" = the images → translate.)
- **GitHub**, **iOS**, **Settings** (the iOS app) — platform/product names; use Apple's localized form
  where one exists, otherwise verbatim.

## Core terms (English → Finnish `fi`)
| English | Finnish (`fi`) | Notes |
| --- | --- | --- |
| album | albumi | **Never** *vuosikirja* / "yearbook" — Poimi has no yearbook/printing concept. |
| pick (verb) | poimia / valita | The core action — choosing a photo. "Poimi" is the imperative of *poimia*. |
| picked | poimittu / valittu | The selected state. |
| photo | kuva | |
| review | käydä läpi / arvioida | Going through a day's photos. |
| done (marked done) | valmis | A day/cluster the user has finished reviewing. |
| range / date range | ajanjakso | The album's period. |
| exclude / excluded | jättää pois / poissuljettu | Screenshots + excluded albums dropped from the source. |
| screenshot | kuvakaappaus | |
| export | vie / tallenna | Writing picks into a Photos album (one-way copy). |
| target / aim for | tavoite | The count you aim toward. |

> The `fi` column is the **starting** glossary; a native speaker refines it at baseline sign-off
> (Phase 2). Add a row when a new product term appears; keep the "never translate" list authoritative.
