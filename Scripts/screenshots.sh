#!/usr/bin/env bash
#
# screenshots.sh — capture deterministic screenshots of Poimi screens (issue #48).
#
# Boots an iOS 26 simulator, builds + installs the app, then for each screen in the DEBUG
# catalog (DebugScreen, in App/PoimiApp/Support/DebugScreen.swift) launches straight to it
# against the deterministic FakePhotoLibrary (-PoimiUseFakeLibrary -PoimiScreen <id>) and
# captures a PNG. The result is a folder of stable images to eyeball against the Paper
# designs — no manual navigation, reproducible in CI / agent runs.
#
# Usage:
#   Scripts/screenshots.sh                  # every screen in the catalog
#   Scripts/screenshots.sh library spike    # only the named screens
#   SIM_NAME="iPhone 17 Pro" Scripts/screenshots.sh
#
# Output: screenshots/<id>.png (git-ignored).
#
# This is the screenshot HARNESS (eyeball against designs), distinct from pixel-snapshot
# TESTING (deferred, D26). Everything it drives is DEBUG-only and release-inert (D30).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/App/PoimiApp.xcodeproj"
SCHEME="PoimiApp"
BUNDLE_ID="fi.paretosoftware.poimi"
CATALOG="${REPO_ROOT}/App/PoimiApp/Support/DebugScreen.swift"
OUT_DIR="${REPO_ROOT}/screenshots"
DERIVED="${REPO_ROOT}/build/screenshots-dd"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
RENDER_WAIT="${RENDER_WAIT:-4}"

log() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }

# 1. Resolve an iOS 26 '${SIM_NAME}' from the *available* devices (the set xcodebuild can
# target — picking a merely-"booted" device can yield an ineligible runtime). Boot is
# idempotent: a no-op if it's already up.
SIM_ID="$(xcrun simctl list devices available | awk -v name="${SIM_NAME}" '
    /^-- iOS 26/        { ok = 1; next }
    /^-- /              { ok = 0 }
    ok && index($0, name " (") {
        if (match($0, /\(([0-9A-Fa-f-]{36})\)/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
    }')"
[ -n "${SIM_ID}" ] || { echo "error: no available iOS 26 '${SIM_NAME}' simulator found." >&2; exit 1; }
# FRESH=1 → shut the device down first, clearing any stuck system alert (e.g. a leftover photo
# prompt from a prior non-harness run) so the capture starts from a clean SpringBoard.
if [ "${FRESH:-0}" = "1" ]; then
    log "FRESH: shutting ${SIM_NAME} down for a clean boot"
    xcrun simctl shutdown "${SIM_ID}" 2>/dev/null || true
fi
log "Booting ${SIM_NAME} (${SIM_ID})"
xcrun simctl boot "${SIM_ID}" 2>/dev/null || true
xcrun simctl bootstatus "${SIM_ID}" -b >/dev/null
log "Simulator ${SIM_ID} ready"

# 2. Which screens? Args, else every `case` in the DebugScreen enum (raw value == case name).
if [ "$#" -gt 0 ]; then
    SCREENS="$*"
else
    SCREENS="$(awk '/enum DebugScreen/{f=1} f && /^[[:space:]]*case [a-z]/{print $2} f && /^}/{exit}' "${CATALOG}")"
fi
[ -n "${SCREENS}" ] || { echo "error: no screens to capture." >&2; exit 1; }
log "Screens: $(echo ${SCREENS} | tr '\n' ' ')"

# 3. Build + install (Debug — the harness is DEBUG-only).
log "Building ${SCHEME} (Debug)"
xcodebuild build \
    -project "${PROJECT}" -scheme "${SCHEME}" -configuration Debug \
    -destination "id=${SIM_ID}" -derivedDataPath "${DERIVED}" \
    -quiet
APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/PoimiApp.app"
[ -d "${APP_PATH}" ] || { echo "error: built app not found at ${APP_PATH}" >&2; exit 1; }
log "Installing ${APP_PATH##*/}"
xcrun simctl install "${SIM_ID}" "${APP_PATH}"

# Pre-authorize photo privacy. The harness always runs against the fake (never real PhotoKit),
# but the simulator can present a leftover system photo-permission alert over the capture — this
# suppresses it so every screenshot is clean and deterministic.
xcrun simctl privacy "${SIM_ID}" grant photos "${BUNDLE_ID}" 2>/dev/null || true

# 4. Capture each screen.
mkdir -p "${OUT_DIR}"
for screen in ${SCREENS}; do
    log "Capturing '${screen}'"
    xcrun simctl terminate "${SIM_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
    xcrun simctl launch "${SIM_ID}" "${BUNDLE_ID}" -PoimiUseFakeLibrary -PoimiScreen "${screen}" >/dev/null
    sleep "${RENDER_WAIT}"   # let the .task load + SwiftUI settle before the snapshot
    xcrun simctl io "${SIM_ID}" screenshot "${OUT_DIR}/${screen}.png" >/dev/null
done

log "Done — $(echo ${SCREENS} | wc -w | tr -d ' ') screenshot(s) in ${OUT_DIR}/"
ls -1 "${OUT_DIR}"
