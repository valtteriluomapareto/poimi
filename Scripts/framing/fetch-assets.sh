#!/usr/bin/env bash
#
# fetch-assets.sh — download the device bezels + fonts the compositor needs (#230). These are
# gitignored (Apple device likeness; keep the repo light) — fetch them once locally. Idempotent.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMES="${DIR}/frames"
FONTS="${DIR}/fonts"
mkdir -p "${FRAMES}" "${FONTS}"

# --- Device bezels (fastlane/frameit-frames): local filename | exact name in latest/ ---
FRAME_ROWS=(
    "iphone-17-pro-max.png|Apple iPhone 17 Pro Max Silver.png"
    "ipad-pro-13.png|Apple iPad Pro (12.9-inch) (4th generation) Silver.png"
)
for row in "${FRAME_ROWS[@]}"; do
    out="${row%%|*}"; name="${row#*|}"
    if [ -f "${FRAMES}/${out}" ]; then echo "have frames/${out}"; continue; fi
    url="$(gh api "repos/fastlane/frameit-frames/contents/latest" \
        --jq ".[] | select(.name==\"${name}\") | .download_url" 2>/dev/null || true)"
    [ -n "${url}" ] || { echo "error: '${name}' not found in fastlane/frameit-frames/latest" >&2; exit 1; }
    echo "fetching frames/${out} ← ${name}"
    curl -fsSL "${url}" -o "${FRAMES}/${out}"   # -f: fail on HTTP error instead of saving the error body
done

# --- Fonts (SIL OFL — freely redistributable; fetched to keep the repo light) ---
if [ -f "${FONTS}/Inter.ttf" ]; then
    echo "have fonts/Inter.ttf"
else
    echo "fetching fonts/Inter.ttf (Inter variable, Google Fonts)"
    curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz%2Cwght%5D.ttf" \
        -o "${FONTS}/Inter.ttf"
fi

echo "done — assets in ${FRAMES}/ and ${FONTS}/"
