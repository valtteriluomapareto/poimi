#!/usr/bin/env bash
#
# appstore-screenshots.sh — capture RAW App Store screenshots (issue #230).
#
# Distinct from Scripts/screenshots.sh (which eyeballs single screens against Paper designs at one
# device size). This captures the marketing hero screens at the exact App Store device resolutions,
# in each locale, against the deterministic fake — filling the grid/viewer with the owner's REAL
# photos (pushed onto the sim at runtime; never committed, never in any built artifact — #230, D30).
#
# Pipeline: this produces RAW screenshots. Framing (device bezel + branded background + localized hero
# text) is a SEPARATE step (fastlane frameit or a sharp compositor — decided by the thin-slice run).
#
# Real photos: drop them in ./screenshots-assets/ (gitignored). Name them 01.jpg, 02.jpg, … — they are
# assigned to grid/viewer cells in filename order (see FakeThumbnailProvider). If the folder is empty
# the capture renders LOUD magenta error tiles (never a pretty fake), so a broken run is obvious.
#
# Usage:
#   Scripts/appstore-screenshots.sh                       # full matrix (all devices × locales × screens)
#   DEVICES=iphone69 LOCALES=en SCREENS=scanning \
#       Scripts/appstore-screenshots.sh                   # the thin-slice go/no-go (one framed shot)
#   Scripts/appstore-screenshots.sh --list                # print the device/locale/screen matrix, exit
#
# Output: screenshots/appstore/<asc-locale>/<NN>_<screen>.png  (git-ignored). Layout matches what
# fastlane `deliver` expects: one folder per ASC locale, numeric prefix = store display order.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/App/PoimiApp.xcodeproj"
SCHEME="PoimiApp"
BUNDLE_ID="com.valtteriluoma.poimi"
PHOTOS_SRC="${REPO_ROOT}/screenshots-assets"
OUT_DIR="${REPO_ROOT}/screenshots/appstore"
DERIVED="${REPO_ROOT}/build/appstore-screenshots-dd"
BUILD_LOG="${DERIVED}/build.log"
READY_TIMEOUT="${READY_TIMEOUT:-30}"
RENDER_SETTLE="${RENDER_SETTLE:-2}"     # real JPEG decode is slower than flat tiles — settle longer

log() { printf '\033[36m[appstore-shots]\033[0m %s\n' "$*" >&2; }

# --- Matrix -----------------------------------------------------------------------------------------
# device key | simulator device name | expected "WxH" (App Store accepted size for the slot)
DEVICE_TABLE=(
    "iphone69|iPhone 16 Pro Max|1320x2868"
    "ipad13|iPad Pro 13-inch (M4)|2064x2752"
)
# locale key | -AppleLanguages code | -AppleLocale | ASC folder code (fastlane deliver)
LOCALE_TABLE=(
    "en|en|en_US|en-US"
    "fi|fi|fi_FI|fi"
)
# Hero screens in store display order. NOTE (#230 review): grid = `scanning` (the real review grid,
# not the chrome-less `thumbs` debug view); albums = `shell` (AppRootView + seeded albums, not the
# `library` text inspector). `pacing` is a placeholder — add a DebugScreen case that shows the
# over-target projection, or reuse `overview`, before the full run.
SCREEN_ORDER=(scanning overview export shell)

DEVICES="${DEVICES:-iphone69 ipad13}"
LOCALES="${LOCALES:-en fi}"
SCREENS="${SCREENS:-${SCREEN_ORDER[*]}}"

lookup() { local key="$1"; shift; for row in "$@"; do [ "${row%%|*}" = "${key}" ] && { echo "${row}"; return 0; }; done; return 1; }
screen_index() { local s="$1" i=1; for x in "${SCREEN_ORDER[@]}"; do [ "$x" = "$s" ] && { printf '%02d' "$i"; return; }; i=$((i+1)); done; printf '99'; }

if [ "${1:-}" = "--list" ]; then
    echo "devices:  ${DEVICES}"; echo "locales:  ${LOCALES}"; echo "screens:  ${SCREENS}"
    echo; printf 'device table:\n'; printf '  %s\n' "${DEVICE_TABLE[@]}"
    exit 0
fi

# --- Real photos ------------------------------------------------------------------------------------
PHOTO_COUNT=0
if [ -d "${PHOTOS_SRC}" ]; then
    PHOTO_COUNT="$(find "${PHOTOS_SRC}" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) | wc -l | tr -d ' ')"
fi
if [ "${PHOTO_COUNT}" -eq 0 ]; then
    log "WARNING: no photos in ${PHOTOS_SRC}/ — screenshots will show magenta error tiles. Drop 01.jpg, 02.jpg, … there."
fi

# --- Build once (Debug — DEBUG-only harness) --------------------------------------------------------
mkdir -p "${DERIVED}"
log "Building ${SCHEME} (Debug) — log: ${BUILD_LOG}"
if ! xcodebuild build -project "${PROJECT}" -scheme "${SCHEME}" -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "${DERIVED}" \
        CODE_SIGNING_ALLOWED=NO > "${BUILD_LOG}" 2>&1; then
    echo "error: build failed — last 40 lines:" >&2; tail -40 "${BUILD_LOG}" >&2; exit 1
fi
APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/PoimiApp.app"
[ -d "${APP_PATH}" ] || { echo "error: built app not found at ${APP_PATH}" >&2; exit 1; }

# Wait until the launched screen logs `screenshot-ready: <id>`.
wait_for_ready() {
    local sim="$1" screen="$2" since="$3" waited=0
    while [ "${waited}" -lt "${READY_TIMEOUT}" ]; do
        if xcrun simctl spawn "${sim}" log show --start "${since}" \
                --predicate 'subsystem == "com.valtteriluoma.poimi"' 2>/dev/null \
                | grep -q "screenshot-ready: ${screen}"; then return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    return 1
}

# Push the real photos into the app's Documents/ScreenshotPhotos on a booted sim.
push_photos() {
    local sim="$1"
    [ "${PHOTO_COUNT}" -gt 0 ] || return 0
    local container; container="$(xcrun simctl get_app_container "${sim}" "${BUNDLE_ID}" data 2>/dev/null)" || return 0
    local dest="${container}/Documents/ScreenshotPhotos"
    rm -rf "${dest}"; mkdir -p "${dest}"
    find "${PHOTOS_SRC}" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) -exec cp {} "${dest}/" \;
}

# --- Capture --------------------------------------------------------------------------------------
for dkey in ${DEVICES}; do
    drow="$(lookup "${dkey}" "${DEVICE_TABLE[@]}")" || { echo "error: unknown device '${dkey}'" >&2; exit 1; }
    IFS='|' read -r _ SIM_NAME EXPECT <<< "${drow}"
    # Resolve the device UUID from the *available* list. Fixed-string match on "<name> (" so
    # "iPhone 16 Pro" doesn't also match "iPhone 16 Pro Max", and a UUID regex so parens in the name
    # (e.g. "iPad Pro 13-inch (M4)") don't confuse extraction. BSD awk (macOS) has no 3-arg match().
    SIM_LINE="$(xcrun simctl list devices available | grep -F "${SIM_NAME} (" | head -1 || true)"
    SIM_ID="$(printf '%s' "${SIM_LINE}" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)"
    [ -n "${SIM_ID}" ] || { echo "error: no available iOS 26 '${SIM_NAME}' simulator found (install it in Xcode)." >&2; exit 1; }

    log "Device ${dkey} → ${SIM_NAME} (${SIM_ID}), expect ${EXPECT}"
    xcrun simctl boot "${SIM_ID}" 2>/dev/null || true
    xcrun simctl bootstatus "${SIM_ID}" -b >/dev/null
    xcrun simctl install "${SIM_ID}" "${APP_PATH}"
    xcrun simctl privacy "${SIM_ID}" grant photos "${BUNDLE_ID}" 2>/dev/null || true
    push_photos "${SIM_ID}"

    # Clean 9:41 marketing status bar (the bash harness must set this itself — unlike fastlane snapshot).
    xcrun simctl status_bar "${SIM_ID}" override \
        --time "9:41" --batteryState charged --batteryLevel 100 \
        --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true

    for lkey in ${LOCALES}; do
        lrow="$(lookup "${lkey}" "${LOCALE_TABLE[@]}")" || { echo "error: unknown locale '${lkey}'" >&2; exit 1; }
        IFS='|' read -r _ LANG_CODE LOCALE_CODE ASC_CODE <<< "${lrow}"
        dest_dir="${OUT_DIR}/${ASC_CODE}"; mkdir -p "${dest_dir}"

        for screen in ${SCREENS}; do
            out="${dest_dir}/$(screen_index "${screen}")_${dkey}_${screen}.png"
            log "  ${ASC_CODE} · ${screen} → ${out##*/}"
            xcrun simctl terminate "${SIM_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
            since="$(date '+%Y-%m-%d %H:%M:%S')"
            xcrun simctl launch "${SIM_ID}" "${BUNDLE_ID}" \
                -PoimiUseFakeLibrary -PoimiScreenshotPhotos -PoimiScreen "${screen}" \
                -AppleLanguages "(${LANG_CODE})" -AppleLocale "${LOCALE_CODE}" >/dev/null
            if wait_for_ready "${SIM_ID}" "${screen}" "${since}"; then sleep "${RENDER_SETTLE}"; else
                echo "warning: '${screen}' never signalled ready within ${READY_TIMEOUT}s — capturing anyway." >&2
            fi
            xcrun simctl io "${SIM_ID}" screenshot "${out}" >/dev/null

            # Assert the captured PNG matches an App-Store-accepted size for this slot.
            got="$(sips -g pixelWidth -g pixelHeight "${out}" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
            if [ "${got}" != "${EXPECT}" ]; then
                echo "warning: ${out##*/} is ${got}, expected ${EXPECT} for ${dkey} — App Store Connect may reject it. Check the sim device / orientation." >&2
            fi
        done
    done

    xcrun simctl status_bar "${SIM_ID}" clear 2>/dev/null || true
done

log "Done. Raw screenshots under ${OUT_DIR}/ (per ASC locale). Next: frame + hero text (frameit / sharp)."
find "${OUT_DIR}" -type f -name '*.png' | sort
