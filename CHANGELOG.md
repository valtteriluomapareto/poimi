# Changelog

All notable, user-facing changes to Poimi, newest first. Hand-curated — only changes
worth telling users about, in plain language (not a commit log). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the app's
`MARKETING_VERSION` (the single source of truth in the Xcode project), semver.

## [Unreleased]

### Changed
- You can now choose what an album reviews: photos only, photos and videos, or
  videos only. Switching is just a lens — it never changes the picks or the days
  you've marked done.
- iPad: the photo viewer now opens much larger, filling the screen instead of a small
  centred window with a wide empty margin around it.
- Swiping to the next or previous day in the review grid lands on its photos
  instead of a screen of loading spinners: while you work on one day, the start
  of the days either side is loaded ahead of you.
- The Overview's pacing card no longer repeats its estimate twice: the small
  "projected ~N" label under the bar is gone, since the headline above it already
  says "At this pace: ~N photos".

## [1.0.2] — 2026-08-19

### Added
- A "What's New" screen that highlights what changed after you update the app.

### Fixed
- Setting an album's date range no longer gets stuck: you can now pick a start date
  later than the default end without the calendar greying out every later day.
- iPad: the app-settings button no longer opens a new Settings screen on every tap
  (it used to stack duplicates you had to back out of one at a time).

## [1.0.1] — 2026-08-07

### Changed
- New app icon.
- The review grid now runs edge-to-edge, all the way under the home indicator.

### Fixed
- VoiceOver announces the photo viewer's and completion screen's automatic
  transitions, and the text reads correctly under Reduce Transparency.

## [1.0.0] — 2026-08-06

### Added
- First public release. Hand-pick a year — or any date range — of your photo library
  into a single Apple Photos album: you choose every photo, toward a target count,
  with day- and trip-grouping to keep you oriented. Your library and originals are
  never changed; picks are copied into a new (or existing) Photos album on finish.
