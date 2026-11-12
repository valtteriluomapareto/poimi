#!/usr/bin/env bash
#
# screenshots.sh — capture deterministic screenshots of Poimi screens (issue #48).
#
# Boots an iOS 26 simulator, builds + installs the app, then for each screen in the DEBUG
# catalog (DebugScreen, in App/PoimiApp/Support/DebugScreen.swift) launches straight to it
# against the deterministic FakePhotoLibrary (-PoimiUseFakeLibrary -PoimiScreen <id>) and
# captures a PNG. The result is a folder of stable images to eyeball against the Paper
# designs — no manual navigation, reproducible run-to-run.
#
# Each screen logs `screenshot-ready: <id>` once its content is on screen; this script waits
# for that signal (not a blind sleep) before snapshotting, so a PNG never races an async load.
#
# Usage:
#   Scripts/screenshots.sh                  # every screen in the catalog
#   Scripts/screenshots.sh library          # only the named screens (validated against catalog)
#   Scripts/screenshots.sh --list           # print the catalog screen ids and exit (no sim)
#   SIM_NAME="iPhone 17 Pro" Scripts/screenshots.sh
#   FRESH=1 Scripts/screenshots.sh          # clean boot first (clears a stuck system alert)
#   READY_TIMEOUT=30 RENDER_SETTLE=2 Scripts/screenshots.sh   # slower machines
#
# Output: screenshots/<id>.png (git-ignored).
#
# This is the screenshot HARNESS (eyeball against designs), distinct from pixel-snapshot
# TESTING (deferred, D26). Everything it drives is DEBUG-only and release-inert (D30).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/sim.sh
. "${SCRIPT_DIR}/lib/sim.sh"   # resolve / boot / build / install / privacy (shared with poimi.sh)
SCHEME="${POIMI_SCHEME}"
BUNDLE_ID="${POIMI_BUNDLE_ID}"
CATALOG_FILE="${REPO_ROOT}/App/PoimiApp/Support/DebugScreen.swift"
OUT_DIR="${REPO_ROOT}/screenshots"
DERIVED="${POIMI_DERIVED}"   # shared with poimi.sh, so the two reuse one incremental build
BUILD_LOG="${REPO_ROOT}/build/screenshots-build.log"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
READY_TIMEOUT="${READY_TIMEOUT:-20}"   # max seconds to wait for a screen's ready signal
RENDER_SETTLE="${RENDER_SETTLE:-1}"    # settle for the final frame once ready

log() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }

# Discover the catalog ids straight from the DebugScreen enum. Handles `case foo` and an
# explicit `case foo = "bar"` (printing the raw value `bar`), so it stays correct if a future
# case names its id explicitly. (The enum keeps one simple case per line — see its comment.)
catalog_ids() {
    awk '
        /enum DebugScreen[ :]/        { f = 1; next }
        f && /^[[:space:]]*}/         { exit }
        f && /^[[:space:]]*case[[:space:]]/ {
            line = $0
            if (match(line, /=[[:space:]]*"[^"]+"/)) {        # case foo = "bar"  → bar
                v = substr(line, RSTART, RLENGTH); gsub(/[=" \t]/, "", v); print v
            } else {                                          # case foo          → foo
                sub(/^[[:space:]]*case[[:space:]]+/, "", line); sub(/[[:space:],].*$/, "", line); print line
            }
        }
    ' "${CATALOG_FILE}"
}

# --list: just print the catalog (no simulator needed). Doubles as a sanity check on discovery.
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    catalog_ids
    exit 0
fi

CATALOG_IDS="$(catalog_ids)"
[ -n "${CATALOG_IDS}" ] || { echo "error: no screens found in ${CATALOG_FILE}." >&2; exit 1; }

# Which screens? Args (validated against the catalog so a typo can't silently mis-capture the
# wrong screen), else the whole catalog.
if [ "$#" -gt 0 ]; then
    SCREENS="$*"
    for screen in ${SCREENS}; do
        if ! printf '%s\n' ${CATALOG_IDS} | grep -qx "${screen}"; then
            echo "error: '${screen}' is not a catalog screen. Known: $(echo ${CATALOG_IDS} | tr '\n' ' ')" >&2
            exit 1
        fi
    done
else
    SCREENS="${CATALOG_IDS}"
fi

# Resolve an iOS 26 '${SIM_NAME}' from the *available* devices (the set xcodebuild can target —
# picking a merely-"booted" device can yield an ineligible runtime). Boot is idempotent.
SIM_ID="$(poimi_resolve_sim "${SIM_NAME}")"
[ -n "${SIM_ID}" ] || { echo "error: no available iOS 26 '${SIM_NAME}' simulator found." >&2; exit 1; }
# FRESH=1 → shut the device down first, clearing any stuck system alert (e.g. a leftover photo
# prompt from a prior non-harness run) so the capture starts from a clean SpringBoard.
if [ "${FRESH:-0}" = "1" ]; then
    log "FRESH: shutting ${SIM_NAME} down for a clean boot"
    xcrun simctl shutdown "${SIM_ID}" 2>/dev/null || true
fi
log "Booting ${SIM_NAME} (${SIM_ID})"
poimi_boot_sim "${SIM_ID}"
log "Screens: $(echo ${SCREENS} | tr '\n' ' ')"

# Build + install (Debug — the harness is DEBUG-only). The build log is kept; its tail is surfaced
# if the build fails.
log "Building ${SCHEME} (Debug) — log: ${BUILD_LOG}"
APP_PATH="$(poimi_build_app "${SIM_ID}" "${DERIVED}" "${BUILD_LOG}")" || exit 1
log "Installing ${APP_PATH##*/}"
poimi_install_app "${SIM_ID}" "${APP_PATH}"

# Pre-authorize photo privacy so a leftover system alert can't cover a capture.
poimi_grant_privacy "${SIM_ID}"

# Wait until the launched screen logs `screenshot-ready: <id>` (a `.notice`, so `log show` sees
# it). Returns non-zero if it never signals within READY_TIMEOUT.
wait_for_ready() {
    local screen="$1" since="$2" waited=0
    while [ "${waited}" -lt "${READY_TIMEOUT}" ]; do
        if xcrun simctl spawn "${SIM_ID}" log show --start "${since}" \
                --predicate 'subsystem == "com.valtteriluoma.poimi"' 2>/dev/null \
                | grep -q "screenshot-ready: ${screen}"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Capture each screen.
mkdir -p "${OUT_DIR}"
for screen in ${SCREENS}; do
    log "Capturing '${screen}'"
    xcrun simctl terminate "${SIM_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    xcrun simctl launch "${SIM_ID}" "${BUNDLE_ID}" -PoimiUseFakeLibrary -PoimiScreen "${screen}" >/dev/null
    if wait_for_ready "${screen}" "${since}"; then
        sleep "${RENDER_SETTLE}"
    else
        echo "warning: '${screen}' never signalled 'screenshot-ready' within ${READY_TIMEOUT}s — capturing anyway; the PNG may be blank/mid-render. Raise READY_TIMEOUT, or check the screen emits the signal." >&2
    fi
    xcrun simctl io "${SIM_ID}" screenshot "${OUT_DIR}/${screen}.png" >/dev/null
done

log "Done — $(echo ${SCREENS} | wc -w | tr -d ' ') screenshot(s) in ${OUT_DIR}/"
ls -1 "${OUT_DIR}"
