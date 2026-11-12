#!/usr/bin/env bash
#
# poimi.sh — the control plane's command line (#296, docs/plans/control-plane.md §4 slice A).
#
# Launch Poimi on a simulator straight into a named fixture + route, read its state as JSON, wait on
# predicates over that state, and screenshot it. DEBUG-only and fake-only: the app runs on an
# isolated in-memory store and the deterministic fake library, never your photos.
#
#   Scripts/poimi.sh launch [--fixture NAME] [--route ROUTE] [--viewer ALIAS] [--ipad] [--build] [--fresh]
#   Scripts/poimi.sh state [JQ-EXPR]                 # print state.json (or a jq expression over it)
#   Scripts/poimi.sh detail [JQ-EXPR]                # print state-detail.json (active album, per day)
#   Scripts/poimi.sh wait PREDICATE... [--timeout S] # block until every jq predicate is true
#   Scripts/poimi.sh shot OUT.png                    # wait idle, short settle, simctl screenshot
#   Scripts/poimi.sh logs [--last 2m]                # the app's OSLog lines
#
# Fixtures: fresh, denied, empty-library, one-album, four-statuses, mid-review, exported, scale.
# Routes:   overview:album-1 | review:album-1[:2025-07-05] | export:album-1 | settings:album-1 | appsettings
#
# Examples:
#   Scripts/poimi.sh launch --fixture mid-review --route review:album-1
#   Scripts/poimi.sh wait '.idle == true' '.active.scan.phase == "ready"'
#   Scripts/poimi.sh state .active
#   Scripts/poimi.sh shot /tmp/grid.png
#
# Environment: SIM_NAME (default "iPhone 17 Pro"), IPAD_SIM_NAME (default "iPad Pro 13-inch (M5)"),
# SHOT_SETTLE (seconds after idle before a screenshot, default 1). The simulator `launch` picked is
# remembered (build/poimi/sim) so later commands talk to the same device.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/sim.sh
. "${SCRIPT_DIR}/lib/sim.sh"

WORK_DIR="${REPO_ROOT}/build/poimi"
DERIVED="${WORK_DIR}/dd"
BUILD_LOG="${WORK_DIR}/build.log"
SIM_FILE="${WORK_DIR}/sim"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
IPAD_SIM_NAME="${IPAD_SIM_NAME:-iPad Pro 13-inch (M5)}"
SHOT_SETTLE="${SHOT_SETTLE:-1}"

die() { echo "poimi: $*" >&2; exit 1; }
log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

require_jq() {
    command -v jq >/dev/null 2>&1 \
        || die "jq is required (it ships with macOS 15+; otherwise 'brew install jq')."
}

# The simulator for this command: the one the last `launch` used, else SIM_NAME.
current_sim() {
    if [ -s "${SIM_FILE}" ]; then cat "${SIM_FILE}"; return; fi
    local id
    id="$(poimi_resolve_sim "${SIM_NAME}")"
    [ -n "${id}" ] || die "no available iOS 26 '${SIM_NAME}' simulator."
    printf '%s\n' "${id}"
}

# The app's data container on the current sim (empty if the app isn't installed).
container() {
    xcrun simctl get_app_container "$1" "${POIMI_BUNDLE_ID}" data 2>/dev/null || true
}

state_file() {
    local data
    data="$(container "$1")"
    [ -n "${data}" ] || die "Poimi isn't installed on the simulator — run 'Scripts/poimi.sh launch --build'."
    printf '%s/Documents/control/%s\n' "${data}" "${2:-state.json}"
}

# --- launch ----------------------------------------------------------------------------------

cmd_launch() {
    local fixture="one-album" route="" viewer="" ipad=0 build=0 fresh=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture) fixture="${2:?--fixture needs a name}"; shift 2 ;;
            --route)   route="${2:?--route needs a route}"; shift 2 ;;
            --viewer)  viewer="${2:?--viewer needs an asset alias}"; shift 2 ;;
            --ipad)    ipad=1; shift ;;
            --build)   build=1; shift ;;
            --fresh)   fresh=1; shift ;;
            *) die "launch: unknown option '$1' (see Scripts/poimi.sh --help)" ;;
        esac
    done
    require_jq

    local name="${SIM_NAME}"
    [ "${ipad}" = "1" ] && name="${IPAD_SIM_NAME}"
    local sim
    sim="$(poimi_resolve_sim "${name}")"
    [ -n "${sim}" ] || die "no available iOS 26 '${name}' simulator."
    mkdir -p "${WORK_DIR}"
    printf '%s\n' "${sim}" > "${SIM_FILE}"

    # --fresh: a clean boot clears a stuck system alert — typically a Photos prompt left by a NORMAL
    # launch (e.g. the `xcodebuild test` host, which runs on real PhotoKit), not by a control run.
    if [ "${fresh}" = "1" ]; then
        log "Fresh: shutting ${name} down for a clean boot"
        xcrun simctl shutdown "${sim}" 2>/dev/null || true
    fi
    log "Booting ${name} (${sim})"
    poimi_boot_sim "${sim}"

    local app="${DERIVED}/Build/Products/Debug-iphonesimulator/PoimiApp.app"
    if [ "${build}" = "1" ] || [ ! -d "${app}" ]; then
        log "Building PoimiApp (Debug) — log: ${BUILD_LOG#"${REPO_ROOT}"/}"
        app="$(poimi_build_app "${sim}" "${DERIVED}" "${BUILD_LOG}")" || exit 1
        build=1
    fi
    if [ "${build}" = "1" ] || [ -z "$(container "${sim}")" ]; then
        log "Installing PoimiApp"
        poimi_install_app "${sim}" "${app}"
    fi
    poimi_grant_privacy "${sim}"

    # Never let a previous launch's state answer for this one.
    xcrun simctl terminate "${sim}" "${POIMI_BUNDLE_ID}" >/dev/null 2>&1 || true
    local file
    file="$(state_file "${sim}")"
    rm -f "${file}"

    local args=(-PoimiControl -PoimiFixture "${fixture}")
    [ -n "${route}" ] && args+=(-PoimiRoute "${route}")
    [ -n "${viewer}" ] && args+=(-PoimiViewer "${viewer}")
    log "Launching: ${args[*]}"
    # TZ pins the process time zone to UTC from the first instruction (the app also sets it).
    SIMCTL_CHILD_TZ=UTC xcrun simctl launch "${sim}" "${POIMI_BUNDLE_ID}" "${args[@]}" >/dev/null

    # The app writes its first state.json only once the route (and viewer) are applied, so this
    # returns with the launch done — or with its launchError.
    local waited=0
    while [ ! -s "${file}" ]; do
        [ "${waited}" -ge 200 ] && die "no state.json within 40 s — is this a Debug build? (try --build)"
        sleep 0.2
        waited=$((waited + 1))
    done
    local error
    error="$(jq -r '.app.launchError // empty' "${file}")"
    [ -z "${error}" ] || die "launch refused: ${error}"
    jq -c '{run, fixture: .app.fixture, idiom: .app.idiom}' "${file}"
}

# --- state / detail --------------------------------------------------------------------------

cmd_state() {
    require_jq
    local file
    file="$(state_file "$(current_sim)" "${2:-state.json}")"
    [ -s "${file}" ] || die "no ${file##*/} yet — launch with 'Scripts/poimi.sh launch'."
    jq "${1:-.}" "${file}"
}

# --- wait ------------------------------------------------------------------------------------

# The observed value for a predicate: its left operand when it is a simple comparison
# (`.a.b == x` → `.a.b`), otherwise the predicate's own value.
observed() {
    local predicate="$1" file="$2" lhs
    lhs="$(printf '%s' "${predicate}" | sed -nE 's/^[[:space:]]*([^=!<>[:space:]]+)[[:space:]]*(==|!=|>=|<=|>|<).*$/\1/p')"
    jq -c "${lhs:-${predicate}}" "${file}" 2>/dev/null || echo "?"
}

cmd_wait() {
    require_jq
    local timeout=15 predicates=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
            *) predicates+=("$1"); shift ;;
        esac
    done
    [ "${#predicates[@]}" -gt 0 ] || die "wait: give at least one jq predicate, e.g. '.idle == true'"
    local file
    file="$(state_file "$(current_sim)")"
    local deadline=$(( $(date +%s) + timeout )) unmet=()
    while :; do
        unmet=()
        if [ -s "${file}" ]; then
            local error
            error="$(jq -r '.app.launchError // empty' "${file}" 2>/dev/null || true)"
            [ -z "${error}" ] || die "launch error: ${error}"
            for predicate in "${predicates[@]}"; do
                local result status=0
                result="$(jq -e "${predicate}" "${file}" 2>&1 >/dev/null)" || status=$?
                case "${status}" in
                    0) ;;
                    1) unmet+=("${predicate}") ;;
                    *) die "wait: '${predicate}' is not a valid jq predicate: ${result}" ;;
                esac
            done
        else
            unmet=("${predicates[@]}")
        fi
        [ "${#unmet[@]}" -eq 0 ] && return 0
        [ "$(date +%s)" -ge "${deadline}" ] && break
        sleep 0.2
    done
    echo "poimi: wait timed out after ${timeout}s. Unmet:" >&2
    for predicate in "${unmet[@]}"; do
        if [ -s "${file}" ]; then
            echo "  ${predicate}    (observed: $(observed "${predicate}" "${file}"))" >&2
        else
            echo "  ${predicate}    (no state.json)" >&2
        fi
    done
    if [ -s "${file}" ]; then
        echo "Last state:" >&2
        cat "${file}" >&2
    fi
    return 1
}

# --- shot ------------------------------------------------------------------------------------

cmd_shot() {
    local out="${1:?shot needs an output .png path}"
    cmd_wait '.idle == true' --timeout 30
    sleep "${SHOT_SETTLE}"   # a short visual settle (animations), after the semantic idle barrier
    mkdir -p "$(dirname "${out}")"
    xcrun simctl io "$(current_sim)" screenshot "${out}" >/dev/null 2>&1 || die "simctl screenshot failed"
    echo "${out}"
}

# --- logs ------------------------------------------------------------------------------------

cmd_logs() {
    local last="2m"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --last) last="${2:?--last needs a duration like 2m}"; shift 2 ;;
            *) die "logs: unknown option '$1'" ;;
        esac
    done
    xcrun simctl spawn "$(current_sim)" log show \
        --predicate "subsystem == \"${POIMI_BUNDLE_ID}\"" --last "${last}" --style compact
}

command="${1:-}"
[ "$#" -gt 0 ] && shift
case "${command}" in
    launch) cmd_launch "$@" ;;
    state)  cmd_state "${1:-.}" ;;
    detail) cmd_state "${1:-.}" state-detail.json ;;
    wait)   cmd_wait "$@" ;;
    shot)   cmd_shot "$@" ;;
    logs)   cmd_logs "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '${command}' (see Scripts/poimi.sh --help)" ;;
esac
