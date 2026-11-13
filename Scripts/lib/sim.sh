#!/usr/bin/env bash
#
# sim.sh — simulator helpers shared by the dev scripts (screenshots.sh, poimi.sh). Source it; it
# defines functions only. Callers set REPO_ROOT before sourcing.
#
#   poimi_resolve_sim <name>              print the UDID of an available iOS 26 '<name>' (empty if none)
#   poimi_boot_sim <udid>                 boot (idempotent) and wait until booted
#   poimi_build_app <udid> <derived> <log>  Debug build for that sim; prints the .app path
#   poimi_install_app <udid> <app>        install the built app
#   poimi_grant_privacy <udid>            pre-grant photos so no system alert covers a capture
#

POIMI_PROJECT="${REPO_ROOT}/App/PoimiApp.xcodeproj"
POIMI_SCHEME="PoimiApp"
POIMI_BUNDLE_ID="com.valtteriluoma.poimi"
# One DerivedData for the dev scripts (screenshots.sh, poimi.sh), so they share incremental builds.
POIMI_DERIVED="${REPO_ROOT}/build/dev-dd"

# Resolve an iOS 26 device by name from the *available* devices (the set xcodebuild can target —
# picking a merely-"booted" device can yield an ineligible runtime).
poimi_resolve_sim() {
    xcrun simctl list devices available | awk -v name="$1" '
        /^-- iOS 26/        { ok = 1; next }
        /^-- /              { ok = 0 }
        ok && index($0, name " (") {
            if (match($0, /\(([0-9A-Fa-f-]{36})\)/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
        }'
}

poimi_boot_sim() {
    xcrun simctl boot "$1" 2>/dev/null || true
    xcrun simctl bootstatus "$1" -b >/dev/null
}

# Debug build (the harness + control plane are DEBUG-only). Keeps the full log (no -quiet, so a
# failed run is self-diagnosing) and surfaces its tail on failure.
poimi_build_app() {
    local sim_id="$1" derived="$2" build_log="$3"
    mkdir -p "${derived}"
    if ! xcodebuild build \
            -project "${POIMI_PROJECT}" -scheme "${POIMI_SCHEME}" -configuration Debug \
            -destination "id=${sim_id}" -derivedDataPath "${derived}" \
            > "${build_log}" 2>&1; then
        echo "error: build failed — last 40 lines of ${build_log}:" >&2
        tail -40 "${build_log}" >&2
        return 1
    fi
    local app="${derived}/Build/Products/Debug-iphonesimulator/PoimiApp.app"
    [ -d "${app}" ] || { echo "error: built app not found at ${app}" >&2; return 1; }
    printf '%s\n' "${app}"
}

poimi_install_app() {
    xcrun simctl install "$1" "$2"
}

# Pre-authorize photo privacy. The dev scripts always run against the fake (never real PhotoKit),
# but the simulator can present a leftover system photo-permission alert over the app — this
# suppresses it so every capture is clean and deterministic.
poimi_grant_privacy() {
    xcrun simctl privacy "$1" grant photos "${POIMI_BUNDLE_ID}" 2>/dev/null || true
}
