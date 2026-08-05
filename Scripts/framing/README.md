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

Assets are fetched, not committed: the **bezels** from
[fastlane/frameit-frames](https://github.com/fastlane/frameit-frames) (Apple device likeness, via the
`gh` CLI — needs `gh auth login`), and **Inter** (SIL OFL) from Google Fonts. Run `./fetch-assets.sh`.
