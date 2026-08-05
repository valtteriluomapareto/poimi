#!/usr/bin/env bash
#
# fetch-frames.sh — download the device bezels the compositor needs, from fastlane/frameit-frames
# (#230). The frames are gitignored (Apple device likeness — not redistributed in this public repo);
# fetch them once locally. Idempotent.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frames"
mkdir -p "${DIR}"

# local filename | exact name in frameit-frames latest/
FRAMES=(
    "iphone-17-pro-max.png|Apple iPhone 17 Pro Max Silver.png"
)

for row in "${FRAMES[@]}"; do
    out="${row%%|*}"; name="${row#*|}"
    if [ -f "${DIR}/${out}" ]; then echo "have ${out}"; continue; fi
    url="$(gh api "repos/fastlane/frameit-frames/contents/latest" \
        --jq ".[] | select(.name==\"${name}\") | .download_url" 2>/dev/null || true)"
    [ -n "${url}" ] || { echo "error: '${name}' not found in fastlane/frameit-frames/latest" >&2; exit 1; }
    echo "fetching ${out} ← ${name}"
    curl -sSL "${url}" -o "${DIR}/${out}"
done
echo "done — bezels in ${DIR}/"
