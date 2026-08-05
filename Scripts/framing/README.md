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

- **Bezel:** iPhone 17 Pro Max (1470×3000); screen rect `(75, 66, 1320×2868)` from frameit-frames
  `offsets.json`. Output: an **opaque** PNG at **1320×2868** (6.9″).
- **Font:** Inter ExtraBold via libvips text + `fontfile` (no system install needed). Both headline
  lines share one size (scaled so the wider one fills the canvas).
- **iPad 13″** bezel + a landscape path are still TODO (add the frame to `fetch-assets.sh` + a device
  entry in `frame.mjs`).

Assets are fetched, not committed: the **bezel** from
[fastlane/frameit-frames](https://github.com/fastlane/frameit-frames) (Apple device likeness), and
**Inter** (SIL OFL) from Google Fonts.
