# App Store screenshot framing (#230)

Composites the raw App Store screenshots (from `Scripts/appstore-screenshots.sh`) into a **real device
bezel** + a branded background + an **Inter** hero headline, at the exact App Store resolution. This is
the framing step of the screenshot pipeline (frameit was evaluated and dropped — a `sharp` compositor
gives exact sizes + full brand control with no device-frame-availability fighting).

## Setup (once)

```sh
npm install            # sharp
./fetch-assets.sh      # download the device bezel + Inter font (gitignored)
```

## Use

```sh
# Frame the whole captured set (per-screen / per-locale headlines live in frame-all.mjs):
node frame-all.mjs

# …or one screenshot:
node frame.mjs <raw.png> <out.png> "<hero line 1>" "<hero line 2>"
```

- **Devices (both portrait):** iPhone 17 Pro Max → **1320×2868** (6.9″) and iPad Pro 13″ → **2064×2752**
  (13″). Each entry in `frame.mjs`'s `DEVICES` map carries its bezel + screen rect (from frameit-frames
  `offsets.json`) + canvas; output is an **opaque** PNG at the accepted App Store size. Only a
  **landscape** path is still TODO.
- **Font:** Inter ExtraBold via libvips text + `fontfile` (no system install needed). Both headline
  lines share one size (scaled down so the wider one fits the canvas).
- **Geometry** (`deviceY`, `titleTop`, screen rects, `shadowRF`) is hand-tuned against the specific
  fetched bezel versions — re-eyeball it if you swap a bezel.

## Upload to App Store Connect

The final framed set is **committed** under `screenshots/appstore/framed/<locale>/` (the only tracked
part of `screenshots/`) so CI can ship it without a Mac. Both upload paths run the same
`upload_screenshots` fastlane lane — screenshots only, no binary / metadata / review submission:

**Via CI (preferred).** Commit the regenerated framed set, then run the manual
`.github/workflows/upload-screenshots.yml` (Actions → **Upload screenshots** → Run workflow) and approve
the `testflight` reviewer gate. No local ASC key needed — it reuses the TestFlight lane's secrets.

**Locally.** With the ASC API key in the env:
```sh
export ASC_KEY_ID=<key-id> ASC_ISSUER_ID=<issuer-id>
export ASC_KEY_CONTENT_BASE64="$(base64 -i AuthKey_XXXX.p8)"   # macOS: single-line output
bundle exec fastlane upload_screenshots    # needs the local fastlane bundle — see testflight-setup.md §3.2
```

Prerequisite: an **editable App Store version** must exist in App Store Connect (a version in "Prepare
for Submission" — screenshots attach to it). ASC infers the device slot from the image dimensions and the
`<locale>` folders map to ASC localizations; the `NN_` prefix sets display order. `overwrite_screenshots`
**clears all existing screenshot slots for en-US + fi first**, so always upload a COMPLETE set (both
devices, both locales). The lane also pre-checks every image is an accepted size (1320×2868 / 2064×2752)
and aborts on a missing set — it never pushes a partial/empty upload. Full lane + auth details:
[docs/deploy/testflight-setup.md](../../docs/deploy/testflight-setup.md) §5.5.

End to end: `Scripts/appstore-screenshots.sh` (capture) → `node Scripts/framing/frame-all.mjs` (frame) →
commit `screenshots/appstore/framed/` → the `upload-screenshots` CI workflow (or `fastlane upload_screenshots`).

Assets are fetched, not committed: the **bezels** from
[fastlane/frameit-frames](https://github.com/fastlane/frameit-frames) (Apple device likeness, via the
`gh` CLI — needs `gh auth login`), and **Inter** (SIL OFL) from Google Fonts. Run `./fetch-assets.sh`.
