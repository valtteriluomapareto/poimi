#!/usr/bin/env bash
#
# check-version.sh
#
# Version-hygiene guard (issue #135 scope extension). The app's canonical marketing
# version is MARKETING_VERSION in App/PoimiApp.xcodeproj/project.pbxproj — the single
# source of truth (it feeds CFBundleShortVersionString, which the About screen reads
# via Bundle.main). It appears 4× (app + test target, each Debug + Release) and MUST
# stay identical across all of them; a human bumps it deliberately (Scripts/bump-version.sh),
# never the release lane. The build number (CURRENT_PROJECT_VERSION / CFBundleVersion)
# is a separate, auto-injected run number and is intentionally NOT checked here.
#
# This guard asserts:
#   • every MARKETING_VERSION occurrence is byte-identical (no Debug/Release/app/test drift);
#   • that value is semver `MAJOR.MINOR.PATCH` (^\d+\.\d+\.\d+$).
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

[ -f "${PBXPROJ}" ] || fail "Missing ${PBXPROJ}."

# Extract the value of every `MARKETING_VERSION = <value>;` line (trim spaces + trailing ;).
values="$(grep -oE 'MARKETING_VERSION = [^;]+;' "${PBXPROJ}" \
    | sed -E 's/MARKETING_VERSION = //; s/;$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"

[ -n "${values}" ] || fail "No MARKETING_VERSION found in project.pbxproj."

count="$(printf '%s\n' "${values}" | grep -c .)"
unique="$(printf '%s\n' "${values}" | sort -u)"
unique_count="$(printf '%s\n' "${unique}" | grep -c .)"

if [ "${unique_count}" -ne 1 ]; then
    echo "::error::MARKETING_VERSION drift across configs — all occurrences must match. Found:"
    printf '%s\n' "${values}"
    fail "MARKETING_VERSION is inconsistent (${unique_count} distinct values across ${count} occurrences); use Scripts/bump-version.sh to keep them in sync."
fi

version="${unique}"
if ! printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "MARKETING_VERSION '${version}' is not semver MAJOR.MINOR.PATCH."
fi

echo "OK: MARKETING_VERSION is a consistent semver '${version}' across all ${count} occurrences."
