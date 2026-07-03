# Localization style guide — Poimi

How Poimi's UI copy should read in any language (#95). Fed to the translator with the [glossary](glossary.md).

## Voice & tone
- **Calm, plain, human.** Notes-app calm, not marketing-loud. Short declarative sentences.
- **Sentence case** for everything — titles, buttons, labels (not Title Case, not ALL CAPS).
- **No exclamation marks.** The one celebratory moment ("Your album is ready") earns its warmth from
  the words, not punctuation.
- **Second person, active.** "Choose the best", "You pick every photo" — the human is in control (the
  product truth: *you* pick, not an algorithm).
- **No jargon, no yearbook/print language.** The output is an *album*; there is no printing.

## UI mechanics (hard rules)
- **Buttons/labels are short.** They live in tight controls (Pick, Select all, Export, the tally). If a
  translation is much longer than the English, shorten it — a clipped button is a bug (verify on the
  tight screens per locale).
- **Preserve every format specifier EXACTLY** — `%@`, `%lld`, `%1$@`, `%2$@` — same identity, type, and
  **order**. `%@ of %@` reordered breaks meaning; use the positional forms when reordering is needed.
- **Preserve `^[…](inflect: true)`** automatic-grammar markup verbatim (it drives plural/case agreement).
- **Numbers** appear as **either** `%@` (a locale-formatted count, already grouped — e.g. "1,847") **or**
  `%lld` (a plain integer — e.g. "of %lld", "Photo %lld of %lld"). Preserve whichever the source uses —
  never swap one for the other, and never add your own digits.
- **Keep `Poimi` verbatim** and preserve the platform product names (see the glossary).

## Plurals
- Author the CLDR plural categories the target language needs (en/fi = `one`/`other`; ru/pl = 3–4;
  ar = 6) in the catalog's `variations.plural`, not a flat `other`.

## Quality gate
- A **native speaker signs off the baseline** per locale (Phase 2) before it ships; Claude drafts +
  self-review only covers small **deltas over a verified baseline**.
