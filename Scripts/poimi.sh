#!/usr/bin/env bash
#
# poimi.sh — the control plane's command line (#296, docs/plans/control-plane.md).
#
# Launch Poimi on a simulator straight into a named fixture + route, drive it with the same actions as
# the user, read its state as JSON, wait on predicates over that state, and screenshot it. DEBUG-only
# and fake-only: the app runs on an isolated in-memory store and the deterministic fake library, never
# your photos.
#
#   Scripts/poimi.sh launch [--fixture NAME] [--route ROUTE] [--viewer ALIAS] [--ipad] [--headless]
#                           [--no-build] [--fresh]
#   Scripts/poimi.sh send ACTION-JSON [--allow-refused] # e.g. '{"type":"nav.openAlbum","album":"album-1"}'
#   Scripts/poimi.sh wait PREDICATE... [--timeout S]   # e.g. 'active.scan.phase == ready' 'idle == true'
#   Scripts/poimi.sh fixture OP [ARGS-JSON]             # test levers: flush, lifecycle.resume, library.*
#   Scripts/poimi.sh reset FIXTURE [LAUNCH-OPTIONS]     # relaunch on a fixture (same device/host, no build)
#   Scripts/poimi.sh state [JQ-EXPR]                    # print state.json (current as of the last reply)
#   Scripts/poimi.sh detail [JQ-EXPR]                   # print state-detail.json (active album, per day)
#   Scripts/poimi.sh schema                             # actions, fixture ops, refusals, state paths, …
#   Scripts/poimi.sh shot OUT.png                       # wait idle, short settle, screenshot — then LOOK
#   Scripts/poimi.sh logs [--last 2m]                   # the app's OSLog lines
#
# The vocabulary is `Scripts/poimi.sh schema`; how to use it: the `poimi-control` skill
# (.claude/skills/poimi-control/SKILL.md). A bad fixture/route is refused with the app's own message.
#
# Environment: SIM_NAME (default "iPhone 17 Pro"), IPAD_SIM_NAME (default "iPad Pro 13-inch (M5)"),
# SHOT_SETTLE (seconds after idle before a screenshot, default 1), REPLY_TIMEOUT (seconds a request
# waits for its reply, default 30; a `wait` gets its own timeout on top).
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
MODE_FILE="${WORK_DIR}/mode"   # that launch's device/host options (--ipad / --headless), for `reset`
ID_FILE="${WORK_DIR}/next-id"  # the next mailbox request number (per launch)
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
IPAD_SIM_NAME="${IPAD_SIM_NAME:-iPad Pro 13-inch (M5)}"
SHOT_SETTLE="${SHOT_SETTLE:-1}"
REPLY_TIMEOUT="${REPLY_TIMEOUT:-30}"

die() { echo "poimi: $*" >&2; exit 1; }
log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

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
    local fixture="one-album" route="" viewer="" ipad=0 headless=0 build=1 fresh=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture)  fixture="${2:?--fixture needs a name}"; shift 2 ;;
            --route)    route="${2:?--route needs a route}"; shift 2 ;;
            --viewer)   viewer="${2:?--viewer needs an asset alias}"; shift 2 ;;
            --ipad)     ipad=1; shift ;;
            --headless) headless=1; shift ;;
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
    rm -f "${SIM_FILE}" "${RUN_FILE}" "${MODE_FILE}"   # no session until this launch has answered
    echo 1 > "${ID_FILE}"   # the app wipes Documents/control/ at launch, so numbering restarts

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
    [ "${headless}" = "1" ] && args+=(-PoimiHeadless)
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
    { [ "${ipad}" = "1" ] && echo --ipad; [ "${headless}" = "1" ] && echo --headless; true; } > "${MODE_FILE}"
    local error
    error="$(jq -r '.app.launchError // empty' "${file}")"
    [ -z "${error}" ] || die "launch refused: ${error}"
    jq -c '{run, fixture: .app.fixture, host: .app.host, idiom: .app.idiom, screen: .nav.screen}' "${file}"
}

# `reset FIXTURE [launch options]`: a reset is a RELAUNCH (the app builds its store and library once per
# launch) — on the same device and host as the last launch, without rebuilding.
cmd_reset() {
    local fixture="${1:?reset needs a fixture name}"
    shift
    local mode=()
    if [ -s "${MODE_FILE}" ]; then
        while IFS= read -r line; do [ -n "${line}" ] && mode+=("${line}"); done < "${MODE_FILE}"
    fi
    cmd_launch --no-build --fixture "${fixture}" ${mode[@]+"${mode[@]}"} "$@"
}

# --- the mailbox (send / fixture / wait / schema talk to the running app) ---------------------------

# The next request number, safe when two shells send at once (a mkdir lock around the counter).
next_request_id() {
    local lock="${WORK_DIR}/id.lock" tries=0 id
    until mkdir "${lock}" 2>/dev/null; do
        tries=$((tries + 1))
        [ "${tries}" -ge 200 ] && die "request-id lock ${lock} is stuck (remove it if no poimi.sh is running)"
        sleep 0.01
    done
    id="$(cat "${ID_FILE}" 2>/dev/null || echo 1)"
    echo $((id + 1)) > "${ID_FILE}"
    rmdir "${lock}"
    printf '%s\n' "${id}"
}

# Write one request into the app's mailbox and print its reply (the whole envelope, compact).
#   $1 = the command's JSON fields (an object, merged into {v, id, run}); $2 = seconds to wait for the reply
# The app handles requests one at a time in order, except waits (which run alongside). If no reply comes
# in time and the app hasn't taken the request yet, it's withdrawn — so a retry can't run it twice.
mailbox() {
    local body="$1" patience="${2:-${REPLY_TIMEOUT}}" sim dir run id tmp reply waited=0
    sim="$(session_sim)" || exit 1
    dir="$(container "${sim}")/Documents/control"
    run="$(cat "${RUN_FILE}")"
    id="$(next_request_id)" || exit 1
    tmp="${dir}/.req-${id}.tmp"
    reply="${dir}/res-${id}.json"
    # Temp name + rename, so the app never reads half a request.
    jq -cn --argjson body "${body}" --arg run "${run}" --argjson id "${id}" \
        '{v: 1, id: $id, run: $run} + $body' > "${tmp}" || die "could not build the request"
    mv "${tmp}" "${dir}/req-${id}.json"
    local limit=$(( patience * 20 ))
    while [ ! -s "${reply}" ]; do
        if [ "${waited}" -ge "${limit}" ]; then
            if mv "${dir}/req-${id}.json" "${dir}/.withdrawn-${id}" 2>/dev/null; then
                rm -f "${dir}/.withdrawn-${id}"
                die "request ${id} wasn't taken within ${patience} s — withdrawn, nothing ran. See 'Scripts/poimi.sh logs'."
            fi
            die "request ${id} was taken but not answered within ${patience} s — it may still run; check 'state' before retrying."
        fi
        if [ $(( waited % 40 )) -eq 39 ]; then
            app_running "${sim}" || die "Poimi isn't running any more — see 'Scripts/poimi.sh logs'."
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
    jq -c . "${reply}"
    rm -f "${reply}"
}

# Exit 1 with the error when a reply isn't ok; otherwise print its data.
reply_data() {
    local reply="$1"
    if [ "$(printf '%s' "${reply}" | jq -r '.ok')" != "true" ]; then
        printf '%s' "${reply}" | jq -r '"poimi: \(.error.code): \(.error.message)"' >&2
        return 1
    fi
    printf '%s' "${reply}" | jq -c '.data'
}

cmd_send() {
    require_jq
    local action="" allow_refused=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --allow-refused) allow_refused=1; shift ;;
            *) [ -z "${action}" ] || die "send: one action at a time"; action="$1"; shift ;;
        esac
    done
    [ -n "${action}" ] || die "send: give an action, e.g. '{\"type\":\"nav.openAlbum\",\"album\":\"album-1\"}'"
    printf '%s' "${action}" | jq -e 'type == "object"' >/dev/null 2>&1 || die "send: the action must be a JSON object"
    local reply data
    reply="$(mailbox "$(jq -cn --argjson action "${action}" '{cmd: "send", action: $action}')")" || exit 1
    data="$(reply_data "${reply}")" || exit 1
    printf '%s\n' "${data}"
    if [ "$(printf '%s' "${data}" | jq -r '.outcome')" = "refused" ] && [ "${allow_refused}" = "0" ]; then
        exit 1
    fi
}

cmd_fixture() {
    require_jq
    local op="${1:?fixture needs an op (see 'Scripts/poimi.sh schema')}" args="${2:-}"
    [ -n "${args}" ] || args='{}'
    printf '%s' "${args}" | jq -e 'type == "object"' >/dev/null 2>&1 || die "fixture: args must be a JSON object"
    local reply data
    reply="$(mailbox "$(jq -cn --arg op "${op}" --argjson args "${args}" '{cmd: "fixture", fixture: ({op: $op} + $args)}')")" \
        || exit 1
    data="$(reply_data "${reply}")" || exit 1
    printf '%s\n' "${data}"
    [ "$(printf '%s' "${data}" | jq -r '.outcome')" != "refused" ] || exit 1
}

cmd_schema() {
    require_jq
    local reply
    reply="$(mailbox '{"cmd":"schema"}')" || exit 1
    reply_data "${reply}" | jq .
}



# --- state / detail --------------------------------------------------------------------------

cmd_state() {
    require_jq
    local file
    file="$(session_file "${2:-state.json}")" || exit 1
    jq "${1:-.}" "${file}"
}

# --- wait ------------------------------------------------------------------------------------

# One predicate, `PATH OP VALUE` or `PATH exists` / `PATH !exists`, as the app's JSON predicate.
# OP is == != >= <=. VALUE is JSON when it parses as JSON (10, true, null, "10" — typed: 10 ≠ "10"),
# otherwise a bare string (ready). A leading `.` on the path is fine (jq habit).
predicate_json() {
    local text="$1" path op raw value
    if [[ "${text}" =~ ^[[:space:]]*\.?([A-Za-z0-9_.-]+)[[:space:]]+(!?exists)[[:space:]]*$ ]]; then
        path="${BASH_REMATCH[1]}"
        value=true
        [ "${BASH_REMATCH[2]}" = "!exists" ] && value=false
        jq -cn --arg path "${path}" --argjson value "${value}" '{path: $path, op: "exists", value: $value}'
        return
    fi
    [[ "${text}" =~ ^[[:space:]]*\.?([A-Za-z0-9_.-]+)[[:space:]]*(==|!=|>=|<=)[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] \
        || die "wait: '${text}' isn't PATH OP VALUE (OP: == != >= <=) or PATH exists / PATH !exists"
    path="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[3]}"
    case "${BASH_REMATCH[2]}" in
        "==") op=eq ;; "!=") op=ne ;; ">=") op=gte ;; "<=") op=lte ;;
    esac
    if value="$(printf '%s' "${raw}" | jq -c . 2>/dev/null)" && [ -n "${value}" ]; then
        jq -cn --arg path "${path}" --arg op "${op}" --argjson value "${value}" '{path: $path, op: $op, value: $value}'
    else
        jq -cn --arg path "${path}" --arg op "${op}" --arg value "${raw}" '{path: $path, op: $op, value: $value}'
    fi
}

# Block IN THE APP (Observation-driven, real deadline) until every predicate holds. Paths are the
# declared state paths (`Scripts/poimi.sh schema`); an undeclared one fails at once.
cmd_wait() {
    require_jq
    local timeout=15 predicates=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
            *) predicates+=("$(predicate_json "$1")") || exit 1; shift ;;
        esac
    done
    [ "${#predicates[@]}" -gt 0 ] || die "wait: give at least one predicate, e.g. 'idle == true'"
    [[ "${timeout}" =~ ^[0-9]+$ ]] && [ "${timeout}" -le 30 ] || die "wait: --timeout is whole seconds, 0–30"
    local list body reply
    list="$(printf '%s\n' "${predicates[@]}" | jq -cs .)"
    body="$(jq -cn --argjson predicates "${list}" --argjson ms $((timeout * 1000)) \
        '{cmd: "wait", predicates: $predicates, timeoutMs: $ms}')"
    reply="$(mailbox "${body}" $((timeout + REPLY_TIMEOUT)))" || exit 1
    [ "$(printf '%s' "${reply}" | jq -r '.ok')" = "true" ] && return 0
    if [ "$(printf '%s' "${reply}" | jq -r '.error.code')" = "unmet" ]; then
        echo "poimi: wait timed out after ${timeout}s. Unmet:" >&2
        printf '%s' "${reply}" | jq -r '.error.unmet[]
            | "  \(.path) \(.op) \(.expected | tojson)    (observed: \(if .present then (.observed | tojson) else "missing" end))"' >&2
        echo "Last state: Scripts/poimi.sh state" >&2
    else
        printf '%s' "${reply}" | jq -r '"poimi: \(.error.code): \(.error.message)"' >&2
    fi
    return 1
}

# --- shot ------------------------------------------------------------------------------------

cmd_shot() {
    local out="${1:?shot needs an output .png path}"
    local sim
    if grep -qx -- --headless "${MODE_FILE}" 2>/dev/null; then log "headless run: the screenshot shows the static host view"; fi
    # The semantic barrier: every action settled, no scan / naming / export / thumbnail load in flight.
    cmd_wait 'idle == true' --timeout 30
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
    launch)   cmd_launch "$@" ;;
    reset)    cmd_reset "$@" ;;
    send)     cmd_send "$@" ;;
    fixture)  cmd_fixture "$@" ;;
    schema)   cmd_schema ;;
    state)    cmd_state "${1:-.}" ;;
    detail)   cmd_state "${1:-.}" state-detail.json ;;
    wait)     cmd_wait "$@" ;;
    shot)     cmd_shot "$@" ;;
    logs)     cmd_logs "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '${command}' (see Scripts/poimi.sh --help)" ;;
esac
