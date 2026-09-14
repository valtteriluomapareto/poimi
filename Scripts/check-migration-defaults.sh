#!/usr/bin/env bash
#
# check-migration-defaults.sh
#
# Tripwire for the stored-property defaults that SwiftData uses to BACKFILL existing rows during
# automatic lightweight migration (#273 review follow-up).
#
# Historical fixtures now test includePhotos backfill directly (MigrationFixtureTests, #290).
# The 1.0.2 fixture already contains includeVideos and locationEnabled, so it cannot exercise their
# original column backfill. Keep these remaining tripwires until equivalent behavioral coverage exists
# (for example, fixtures predating those attributes). Pure baseline-decoder tests do not cover this.
# See docs/deploy/migration-testing.md for fixture generation and the install-over-prior-build check.
#
# Pure-bash, no toolchain dependency, mirroring the other Scripts/check-*.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODEL="${REPO_ROOT}/App/PoimiApp/Persistence/CurationProject.swift"

fail() {
    echo "::error::$1"
    echo "FAIL: $1"
    exit 1
}

[ -f "${MODEL}" ] || fail "Missing ${MODEL}."

# Each entry: "<property>=<required default>|<what breaks if it changes>".
# Only stored properties whose default is what migration backfills into PRE-EXISTING rows belong here.
EXPECTED=(
    "includeVideos=false|every pre-#125 album would silently start including videos (#125)"
    "locationEnabled=true|every pre-#130 album would lose trip/place grouping (#130)"
)

for entry in "${EXPECTED[@]}"; do
    spec="${entry%%|*}"
    consequence="${entry##*|}"
    prop="${spec%%=*}"
    want="${spec##*=}"

    # The stored declaration, e.g. `var includeVideos: Bool = false` (ignores computed vars, which have
    # no `=` initializer, and the `MediaSelection` accessors of the same name).
    line="$(grep -E "^[[:space:]]*var ${prop}: Bool = " "${MODEL}" || true)"
    [ -n "${line}" ] || fail "CurationProject.${prop} is no longer a stored Bool with a default — migration backfill is undefined. ${consequence}"

    got="$(echo "${line}" | sed -E 's/.*= *([a-z]+).*/\1/')"
    [ "${got}" = "${want}" ] || fail "CurationProject.${prop} defaults to '${got}', expected '${want}' — ${consequence}. If this change is deliberate, verify the upgrade on device (install over a prior build) and update this guard."
done

echo "OK: migration-backfill defaults unchanged (${#EXPECTED[@]} checked)."
