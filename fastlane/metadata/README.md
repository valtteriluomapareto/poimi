# App Store metadata (repo = source of truth) — #236

These `.txt` files are the **source of truth** for Poimi's App Store Connect *text* metadata. The
`upload_metadata` fastlane lane (see `fastlane/Fastfile`, run via the `upload-screenshots.yml` workflow)
pushes them to the **editable** App Store version — text only, no binary, no screenshots, no submission.

## What is repo-managed (edit here → PR → run the lane)

Per locale (`en-US/`, `fi/`):

| File | ASC field | Limit | Notes |
| --- | --- | --- | --- |
| `description.txt` | Description | 4000 | Conversion copy; **not** search-indexed. First ~170 chars show above "more". |
| `keywords.txt` | Keywords | 100 | Comma-separated, **no spaces after commas**. Editable only on an editable version. |
| `marketing_url.txt` | Marketing URL | — | Version-localization field. |
| `support_url.txt` | Support URL | — | Version-localization field. |

All four are **version-localization** fields. (The **App-Information** fields — name, subtitle, privacy
URL — are deliberately *not* here; see below.)

## What is NOT managed here — leave it in App Store Connect

**Do not add files for these** — the lane never writes a field it has no file for, and adding one hands
that field to the repo (a surprise on the next run):

- **The whole App-Information group — app `name`, `subtitle`, `privacy` URL.** These are
  `AppInfoLocalization` fields, and deliver's app-info write returns **`No data` on a brand-new app's
  first version** (a known deliver limitation — the version-localization fields above upload fine). We
  keep them in ASC: set the **name** to `Poimi: Photo Album Curation`, the **subtitle** (prime ASO — do
  the keyword work here), and the **privacy URL** (`https://valtteriluomapareto.github.io/poimi/privacy`,
  required at review). *Revisit adding subtitle/privacy to the lane after the app's first version exists.*
- **Promotional text** — the live-edit escape hatch (editable anytime without a new version); keep it in
  ASC for launch/campaign tweaks so a lane run can't revert them.
- **Release notes / "What's New"** — invalid on a first version; add per-update later.
- Pricing, availability, age rating, the **App Privacy** nutrition label, categories, App Review
  Information (demo/notes), in-app purchases.

## Sharp edges (read before editing)

- **An EMPTY file wipes the ASC field.** A *missing* file = unmanaged (safe); a *present-but-empty* file
  PUTs an empty value. The lane's pre-flight refuses to run if any managed file is empty.
- **In-review lock.** All managed fields (`description` / `keywords` / `marketing_url` / `support_url`)
  are version-localization fields, writable only while the version is in **"Prepare for Submission."** A
  lane run once it's "Waiting for Review"/"In Review" will error on them.
- **Drift.** This is the source of truth — a hand-edit of a managed field in the ASC UI is **reverted**
  on the next `upload_metadata` run. Edit here, not there (or pull ASC → repo first if you must).
- **Keyword pooling.** Apple indexes name + subtitle + keywords together — don't repeat words across
  them. The name carries *Photo / Album / Curation*, so those are wasted if reused in subtitle/keywords.

## Status

The English + Finnish copy here is a **first draft** — the polished, ASO'd, natively-reviewed copy is a
separate follow-up (4-lens review, like the hero-screenshot headlines). The Finnish especially needs a
native pass.
