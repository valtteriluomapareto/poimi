#!/usr/bin/env bash
#
# poimi.sh — the control plane's command line (#296, docs/plans/control-plane.md).
#
# Launch Poimi on a simulator straight into a named fixture + route, read its state as JSON, wait on
# predicates over that state, and screenshot it. DEBUG-only and fake-only: the app runs on an
# isolated in-memory store and the deterministic fake library, never your photos.
#
#   Scripts/poimi.sh launch [--fixture NAME] [--route ROUTE] [--viewer ALIAS] [--ipad] [--no-build] [--fresh]
#   Scripts/poimi.sh state [JQ-EXPR]                 # print state.json (or a jq expression over it)
#   Scripts/poimi.sh detail [JQ-EXPR]                # print state-detail.json (active album, per day)
#   Scripts/poimi.sh wait PREDICATE... [--timeout S] # block until every jq predicate is true
#   Scripts/poimi.sh shot OUT.png                    # wait settled, short settle, screenshot — then LOOK
#   Scripts/poimi.sh logs [--last 2m]                # the app's OSLog lines
#
# Fixtures, routes and the state.json fields: the `poimi-control` skill
# (.claude/skills/poimi-control/SKILL.md). A bad fixture/route is refused with the app's own message.
#
# Environment: SIM_NAME (default "iPhone 17 Pro"), IPAD_SIM_NAME (default "iPad Pro 13-inch (M5)"),
# SHOT_SETTLE (seconds after idle before a screenshot, default 1).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/sim.sh
. "${SCRIPT_DIR}/lib/sim.sh"

WORK_DIR="${REPO_ROOT}/build/poimi"
BUILD_LOG="${WORK_DIR}/build.log"
SIM_FILE="${WORK_DIR}/sim"     # the simulator the last launch used
RUN_FILE="${WORK_DIR}/run"     # that launch's run id (state.json `.run`)
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
IPAD_SIM_NAME="${IPAD_SIM_NAME:-iPad Pro 13-inch (M5)}"
SHOT_SETTLE="${SHOT_SETTLE:-1}"

die() { echo "poimi: $*" >&2; exit 1; }
log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

require_jq() {
    command -v jq >/dev/null 2>&1 \
        || die "jq is required (it ships with macOS 15+; otherwise 'brew install jq')."
}

# (No `producer | grep -q` below: under `pipefail`, grep -q exiting early SIGPIPEs the producer and
# the pipeline reports failure even on a match. Capture first, then match.)

sim_state() {   # Booted / Shutdown / … for a UDID
    local devices
    devices="$(xcrun simctl list devices)"
    printf '%s\n' "${devices}" | sed -n "s/.*($1) (\([A-Za-z]*\)).*/\1/p"
}

app_running() {
    local services
    services="$(xcrun simctl spawn "$1" launchctl list 2>/dev/null || true)"
    [[ "${services}" == *"UIKitApplication:${POIMI_BUNDLE_ID}"* ]]
}

# The app's data container on a sim (empty if the app isn't installed).
container() {
    xcrun simctl get_app_container "$1" "${POIMI_BUNDLE_ID}" "${2:-data}" 2>/dev/null || true
}

# --- the session (state / detail / wait / shot talk to what `launch` started) -----------------

# Prints the session's simulator after checking it can answer for THIS launch: launched, booted,
# app installed and still running. A stale state.json from an earlier run can never pass.
session_sim() {
    [ -s "${SIM_FILE}" ] && [ -s "${RUN_FILE}" ] || die "no launch yet — run 'Scripts/poimi.sh launch'."
    local sim state
    sim="$(cat "${SIM_FILE}")"
    state="$(sim_state "${sim}")"
    [ "${state}" = "Booted" ] || die "the simulator (${sim}) is ${state:-gone} — run 'Scripts/poimi.sh launch'."
    [ -n "$(container "${sim}")" ] || die "Poimi isn't installed on ${sim} — run 'Scripts/poimi.sh launch'."
    app_running "${sim}" \
        || die "Poimi isn't running on ${sim} (quit or crashed) — its state is stale. Relaunch, and see 'Scripts/poimi.sh logs'."
    printf '%s\n' "${sim}"
}

# The state file for the session, checked to belong to the recorded run.
session_file() {
    local sim file run
    sim="$(session_sim)" || exit 1   # bash 3.2: `set -e` does not reach into $(…)
    file="$(container "${sim}")/Documents/control/${1:-state.json}"
    [ -s "${file}" ] || die "no ${file##*/} — the app isn't a control launch any more. Relaunch."
    run="$(jq -r '.run' "${file}")"
    [ "${run}" = "$(cat "${RUN_FILE}")" ] \
        || die "${file##*/} is from run ${run}, not this session's $(cat "${RUN_FILE}") — relaunch."
    printf '%s\n' "${file}"
}

# --- launch ----------------------------------------------------------------------------------

# Whether a NORMAL (non-control) launch ran on this simulator since our last control launch on it —
# e.g. the `xcodebuild test` host, whose real-PhotoKit conformance test raises the system Photos
# prompt; SpringBoard keeps that alert up after the process exits, over the next app.
normal_launch_since_ours() {
    local sim="$1" marker="${WORK_DIR}/launched-$1" range lines
    if [ -s "${marker}" ]; then range=(--start "$(cat "${marker}")"); else range=(--last 1h); fi
    lines="$(xcrun simctl spawn "${sim}" log show "${range[@]}" --style compact \
        --predicate "subsystem == \"${POIMI_BUNDLE_ID}\" AND eventMessage CONTAINS \"using SystemPhotoLibrary\"" \
        2>/dev/null || true)"
    [[ "${lines}" == *"using SystemPhotoLibrary"* ]]
}

# Install the built app unless the identical build is already installed (another worktree's or an
# older build must never silently answer for this one).
install_if_changed() {
    local sim="$1" app="$2" installed bin
    installed="$(container "${sim}" app)"
    if [ -n "${installed}" ]; then
        local same=1
        for bin in PoimiApp PoimiApp.debug.dylib; do
            if [ -e "${app}/${bin}" ] && ! cmp -s "${app}/${bin}" "${installed}/${bin}"; then same=0; fi
        done
        [ "${same}" = "1" ] && return 0
    fi
    log "Installing PoimiApp"
    poimi_install_app "${sim}" "${app}"
}

cmd_launch() {
    local fixture="one-album" route="" viewer="" ipad=0 build=1 fresh=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture)  fixture="${2:?--fixture needs a name}"; shift 2 ;;
            --route)    route="${2:?--route needs a route}"; shift 2 ;;
            --viewer)   viewer="${2:?--viewer needs an asset alias}"; shift 2 ;;
            --ipad)     ipad=1; shift ;;
            --no-build) build=0; shift ;;
            --build)    build=1; shift ;;   # the default; accepted for old habits
            --fresh)    fresh=1; shift ;;
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
    rm -f "${SIM_FILE}" "${RUN_FILE}"   # no session until this launch has answered

    if [ "${fresh}" = "0" ] && [ "$(sim_state "${sim}")" = "Booted" ] && normal_launch_since_ours "${sim}"; then
        log "A normal Poimi launch ran on ${name} since the last control launch (its system alerts can linger)"
        fresh=1
    fi
    if [ "${fresh}" = "1" ]; then
        log "Clean boot: shutting ${name} down"
        xcrun simctl shutdown "${sim}" 2>/dev/null || true
    fi
    log "Booting ${name} (${sim})"
    poimi_boot_sim "${sim}"

    local app="${POIMI_DERIVED}/Build/Products/Debug-iphonesimulator/PoimiApp.app"
    if [ "${build}" = "1" ]; then
        log "Building PoimiApp (Debug, incremental) — log: ${BUILD_LOG#"${REPO_ROOT}"/}"
        app="$(poimi_build_app "${sim}" "${POIMI_DERIVED}" "${BUILD_LOG}")" || exit 1
    fi
    [ -d "${app}" ] || die "no built app at ${app#"${REPO_ROOT}"/} — launch without --no-build."
    install_if_changed "${sim}" "${app}"
    poimi_grant_privacy "${sim}"

    xcrun simctl terminate "${sim}" "${POIMI_BUNDLE_ID}" >/dev/null 2>&1 || true
    local file
    file="$(container "${sim}")/Documents/control/state.json"
    rm -f "${file}"

    local args=(-PoimiControl -PoimiFixture "${fixture}")
    [ -n "${route}" ] && args+=(-PoimiRoute "${route}")
    [ -n "${viewer}" ] && args+=(-PoimiViewer "${viewer}")
    log "Launching: ${args[*]}"
    date '+%Y-%m-%d %H:%M:%S' > "${WORK_DIR}/launched-${sim}"
    # TZ pins the process time zone to UTC from the first instruction (the app also sets it).
    SIMCTL_CHILD_TZ=UTC xcrun simctl launch "${sim}" "${POIMI_BUNDLE_ID}" "${args[@]}" >/dev/null

    # The app writes its first state.json only once the route (and viewer) are applied, so this
    # returns with the launch done — or with its launchError.
    local waited=0
    while [ ! -s "${file}" ]; do
        [ "${waited}" -ge 200 ] && die "no state.json within 40 s — see 'Scripts/poimi.sh logs'."
        app_running "${sim}" || [ "${waited}" -lt 10 ] || die "Poimi exited during launch — see 'Scripts/poimi.sh logs'."
        sleep 0.2
        waited=$((waited + 1))
    done
    printf '%s\n' "${sim}" > "${SIM_FILE}"
    jq -r '.run' "${file}" > "${RUN_FILE}"
    local error
    error="$(jq -r '.app.launchError // empty' "${file}")"
    [ -z "${error}" ] || die "launch refused: ${error}"
    jq -c '{run, fixture: .app.fixture, idiom: .app.idiom, screen: .nav.screen}' "${file}"
}

# --- state / detail --------------------------------------------------------------------------

cmd_state() {
    require_jq
    local file
    file="$(session_file "${2:-state.json}")" || exit 1
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
    local deadline=$(( $(date +%s) + timeout )) unmet=() file
    while :; do
        file="$(session_file)" || exit 1   # re-checked every poll: the app must stay alive and on this run
        local error
        error="$(jq -r '.app.launchError // empty' "${file}")"
        [ -z "${error}" ] || die "launch error: ${error}"
        unmet=()
        for predicate in "${predicates[@]}"; do
            local result status=0
            result="$(jq -e "${predicate}" "${file}" 2>&1 >/dev/null)" || status=$?
            case "${status}" in
                0) ;;
                1|4) unmet+=("${predicate}") ;;   # false/null, or no output: not (yet) true
                *) die "wait: '${predicate}' is not a valid jq predicate: ${result}" ;;
            esac
        done
        [ "${#unmet[@]}" -eq 0 ] && return 0
        [ "$(date +%s)" -ge "${deadline}" ] && break
        sleep 0.2
    done
    echo "poimi: wait timed out after ${timeout}s. Unmet:" >&2
    for predicate in "${unmet[@]}"; do
        echo "  ${predicate}    (observed: $(observed "${predicate}" "${file}"))" >&2
    done
    echo "Last state:" >&2
    cat "${file}" >&2
    return 1
}

# --- shot ------------------------------------------------------------------------------------

cmd_shot() {
    local out="${1:?shot needs an output .png path}"
    # `idle` is true/false, or null where slice A can't observe the screen (export) — wait for it to
    # be not-false, and say so when it's unknown.
    cmd_wait '.idle != false' --timeout 30
    local idle screen sim
    idle="$(cmd_state .idle)"
    if [ "${idle}" = "null" ]; then
        screen="$(cmd_state .nav.screen)"; screen="${screen//\"/}"
        log "idle is unknown on the ${screen} screen (slice A can't observe it); capturing after the settle"
    fi
    sleep "${SHOT_SETTLE}"   # a short visual settle (animations), after the semantic barrier
    mkdir -p "$(dirname "${out}")"
    sim="$(session_sim)" || exit 1
    xcrun simctl io "${sim}" screenshot "${out}" >/dev/null 2>&1 || die "simctl screenshot failed"
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
    [ -s "${SIM_FILE}" ] || die "no launch yet — run 'Scripts/poimi.sh launch'."
    local sim
    sim="$(cat "${SIM_FILE}")"
    [ "$(sim_state "${sim}")" = "Booted" ] || die "the simulator (${sim}) is not booted."
    xcrun simctl spawn "${sim}" log show \
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
