# App Store release notes / "What's New" (repo = source of truth) — #95 Phase 4

These `release_notes.txt` files are the **source of truth** for Poimi's App Store Connect *What's New*
text, **per release**. The `upload_release_notes` fastlane lane (see `fastlane/Fastfile`, run via the
`upload-screenshots.yml` workflow) pushes them to the **editable** App Store version's `whatsNew` field —
that field **only**, no binary, no screenshots, no other metadata, no submission.

Kept **separate** from `fastlane/metadata/` on purpose: `fastlane/metadata/*/*.txt` is **stable** store
text (description, keywords, URLs) uploaded by `upload_metadata`, whereas these notes **change every
release**. A sibling folder means an `upload_metadata` run never touches the notes, and an
`upload_release_notes` run never touches the stable metadata — each lane does exactly one thing.

## Layout

```
fastlane/release_notes/
  en-US/release_notes.txt
  fi/release_notes.txt
```

| File | ASC field | Limit | Notes |
| --- | --- | --- | --- |
| `<locale>/release_notes.txt` | What's New (`whatsNew`) | 4000 | Version-localization field; editable only on an editable ("Prepare for Submission") version. **Invalid on a first version** — deliver skips it there. |

## How to update (every release)

1. In the release PR (alongside the `Scripts/bump-version.sh` bump + the `CHANGELOG.md` `## [<version>]`
   section), rewrite **both** locales' `release_notes.txt` from that changelog section — the hand-curated,
   canonical per-version record (#182), **not** `git log`. App Store notes may be terser than the in-app
   *What's New* (#248); keep the wording consistent with the in-app highlights in `Localizable.xcstrings`.
2. Get a **native-speaker OK** on the Finnish (same gate as any shipped `fi` copy, #95).
3. During the release (§5.7), run **Upload to App Store → `upload_release_notes`** — after the build is
   attached, before Submit. It's draft-only + never submits.

## Sharp edges (read before editing)

- **An EMPTY file uploads nothing.** deliver *skips* an empty value (a no-op, not a wipe), so a blank file
  would silently ship no notes while the run reports success — the lane's pre-flight refuses to run if
  either present file is empty. (A *missing* locale file is safe/unmanaged.)
- **In-review lock.** `whatsNew` is a version-localization field — writable only while the version is
  "Prepare for Submission." A run once it's "Waiting for Review" / "In Review" errors.
- **First version.** Release notes are invalid on an app's first-ever version; deliver skips them (with a
  notice) rather than failing — so 1.0.0/1.0.1 had none, and 1.0.2 is the first update that carries them.
- **These track the CURRENT release.** The file holds the notes for whatever `MARKETING_VERSION` is being
  shipped; update it in the release PR so it never lags the bumped version.

## Status

The English + Finnish below are drafted by Claude from the CHANGELOG; the Finnish awaits a native-speaker
sign-off (owner is a Finnish speaker — same one-line gate as the in-app #248 copy).
