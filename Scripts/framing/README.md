# App Store screenshot framing (#230)

Composites a raw App Store screenshot (from `Scripts/appstore-screenshots.sh`) into a **real device
bezel** + a branded background + a hero headline, at the exact App Store resolution. This is the
framing step of the screenshot pipeline (frameit was evaluated and dropped — a `sharp` compositor
gives exact sizes + full brand control with no device-frame-availability fighting).

## Setup (once)

```sh
npm install            # sharp
./fetch-frames.sh      # download device bezels — gitignored, from fastlane/frameit-frames
```

## Use

```sh
node frame.mjs <raw.png> <out.png> "<hero line 1>" "<hero line 2>"
```

- **Bezel:** iPhone 17 Pro Max (1470×3000); screen rect `(75, 66, 1320×2868)` from frameit-frames
  `offsets.json`. Output: an **opaque** PNG at **1320×2868** (6.9″).
- **Font:** Helvetica placeholder — embed **Inter** for the real set to match the brand.
- **iPad 13″** bezel + a landscape path are still TODO (add the frame to `fetch-frames.sh` + a device
  entry here).

Bezels come from [fastlane/frameit-frames](https://github.com/fastlane/frameit-frames) and are **not**
committed to this repo (Apple device likeness).
