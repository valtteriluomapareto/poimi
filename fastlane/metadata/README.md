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
| `subtitle.txt` | Subtitle | 30 | Search-indexed + shown under the name. |
| `marketing_url.txt` | Marketing URL | — | Version-localization field. |
| `support_url.txt` | Support URL | — | Version-localization field. |
| `privacy_url.txt` | Privacy URL | — | **App Information** (app-level); editable anytime. Required at review. |

## What is NOT managed here — leave it in App Store Connect

**Do not add files for these** — the lane never writes a field it has no file for, and adding one hands
that field to the repo (a surprise on the next run):

- **App name** — set in ASC to `Poimi: Photo Album Curation` (keyword-bearing; a set-once brand field).
- **Promotional text** — the live-edit escape hatch (editable anytime without a new version); keep it in
  ASC for launch/campaign tweaks so a lane run can't revert them.
- **Release notes / "What's New"** — invalid on a first version; add per-update later.
- Pricing, availability, age rating, the **App Privacy** nutrition label, categories, App Review
  Information (demo/notes), in-app purchases.

## Sharp edges (read before editing)

- **An EMPTY file wipes the ASC field.** A *missing* file = unmanaged (safe); a *present-but-empty* file
  PUTs an empty value. The lane's pre-flight refuses to run if any managed file is empty.
- **In-review lock.** `description` / `keywords` / `subtitle` / `marketing_url` / `support_url` are
  writable only while the version is in **"Prepare for Submission."** `privacy_url` (and promo text) stay
  editable. A lane run while the version is in review will error on the locked fields.
- **Drift.** This is the source of truth — a hand-edit of a managed field in the ASC UI is **reverted**
  on the next `upload_metadata` run. Edit here, not there (or pull ASC → repo first if you must).
- **Keyword pooling.** Apple indexes name + subtitle + keywords together — don't repeat words across
  them. The name carries *Photo / Album / Curation*, so those are wasted if reused in subtitle/keywords.

## Status

The English + Finnish copy here is a **first draft** — the polished, ASO'd, natively-reviewed copy is a
separate follow-up (4-lens review, like the hero-screenshot headlines). The Finnish especially needs a
native pass.
