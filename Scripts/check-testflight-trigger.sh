#!/usr/bin/env bash
#
# check-testflight-trigger.sh
#
# Deploy-safety guard for issue #135. The TestFlight workflow uploads a signed build
# to App Store Connect using the protected `testflight` Environment's secrets. It MUST
# be reachable only by an explicit human `workflow_dispatch` (optionally a `v*` tag) —
# never automatically on `pull_request` or a branch `push`, which on a public repo with
# forking enabled would be an obvious path to exfiltrating signing secrets / shipping
# an unreviewed build.
#
# This guard asserts, on the trigger (`on:`) block of .github/workflows/testflight.yml:
#   • `workflow_dispatch` IS present.
#   • `pull_request` / `pull_request_target` are ABSENT.
#   • `push` is either absent OR tags-only (`tags:`, no `branches:`) — the optional `v*`
#     tag path. A branch `push` trigger fails the guard.
#
# It also asserts the export-compliance build setting
# `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` is present in project.pbxproj (from
# #136): without it every TestFlight build stalls in "Missing Compliance" and reaches
# no tester, so a regression that drops it should fail CI here.
#
# Pure-bash heuristic (no toolchain dependency), mirroring the other Scripts/check-*.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PBXPROJ="${REPO_ROOT}/App/PoimiApp.xcodeproj/project.pbxproj"

fail() {
    echo "::error::$1"
    echo "FAIL: $1"
    exit 1
}

# --- 1. Deploy workflows must be dispatch-only -----------------------------------
# Both the TestFlight lane and the screenshot-upload lane use the protected `testflight`
# Environment's App Store Connect secrets. On a public repo with forks, a pull_request or a
# branch push on either would be a path to exfiltrating those secrets — so BOTH must be
# reachable only by an explicit human workflow_dispatch. (testflight.yml additionally allows
# the optional v* tag-push path; upload-screenshots.yml is dispatch-only.)
check_dispatch_only() {
    local wf="$1" label="$2" allow_tag_push="$3"
    local on_block code
    [ -f "${wf}" ] || fail "Missing ${wf} — ${label} is required."

    # Extract the top-level `on:` block: from the `on:` line up to (but not including) the next
    # top-level key (a non-space char in column 1). Whole-line comments are dropped so prose
    # mentioning a trigger cannot trip the checks.
    on_block="$(awk '
        /^[[:space:]]*#/ { next }
        /^on:([[:space:]]|$)/ { collecting = 1; print; next }
        collecting && /^[^[:space:]]/ { collecting = 0 }
        collecting { print }
    ' "${wf}")"
    [ -n "${on_block}" ] || fail "Could not find an 'on:' trigger block in ${wf}."

    # Strip inline comments so `# pull_request` in a note doesn't match.
    code="$(printf '%s\n' "${on_block}" | sed 's/#.*$//')"

    printf '%s\n' "${code}" | grep -Eq '(^|[[:space:]])workflow_dispatch:' \
        || fail "${label} must be triggerable by workflow_dispatch."

    if printf '%s\n' "${code}" | grep -Eq '(^|[[:space:]])pull_request(_target)?:'; then
        fail "${label} must NOT be triggered by pull_request — deploy secrets would be exposed."
    fi

    if printf '%s\n' "${code}" | grep -Eq '(^|[[:space:]])push:'; then
        if [ "${allow_tag_push}" = "tags" ]; then
            if printf '%s\n' "${code}" | grep -Eq '(^|[[:space:]])branches:'; then
                fail "${label} must NOT be triggered by a branch push — workflow_dispatch (+ optional v* tag) only."
            fi
            printf '%s\n' "${code}" | grep -Eq '(^|[[:space:]])tags:' \
                || fail "${label} has a 'push:' trigger without 'tags:' — only a tags-only push (v*) is allowed."
        else
            fail "${label} must NOT be triggered by push — workflow_dispatch only."
        fi
    fi
}

check_dispatch_only "${REPO_ROOT}/.github/workflows/testflight.yml"         "testflight.yml"         "tags"
check_dispatch_only "${REPO_ROOT}/.github/workflows/upload-screenshots.yml" "upload-screenshots.yml" "none"

# --- 2. Export-compliance build setting (from #136) ------------------------------
# Require the key set to NO on BOTH app configs (Debug + Release), not just present:
# a stray key with the wrong value (or on only one config) still stalls builds in
# "Missing Compliance". The app target has two configs, so assert >= 2 occurrences of
# the `= NO;` value.
[ -f "${PBXPROJ}" ] || fail "Missing ${PBXPROJ}."
compliance_count="$(grep -c 'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;' "${PBXPROJ}" || true)"
if [ "${compliance_count}" -lt 2 ]; then
    fail "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO must be set on both app configs (found ${compliance_count}) — TestFlight builds would stall in 'Missing Compliance' (#136)."
fi

echo "OK: testflight.yml + upload-screenshots.yml are workflow_dispatch-only (no pull_request / branch push); export-compliance = NO on ${compliance_count} configs."
