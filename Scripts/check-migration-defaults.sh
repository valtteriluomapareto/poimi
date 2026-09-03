#!/usr/bin/env bash
#
# check-migration-defaults.sh
#
# Tripwire for the stored-property defaults that SwiftData uses to BACKFILL existing rows during
# automatic lightweight migration (#273 review follow-up).
#
# Why a grep and not a test. `AppSchema.swift` records the standing decision: the app uses one shared
# model class per entity, integration tests run `inMemory` (fresh stores, opened directly at the current
# schema — they never migrate anything), and the in-place upgrade of an existing on-disk store is
# verified by installing OVER a prior build on device. A unit test would need two entities with the SAME
# name (an old and a new `CurationProject`) in one target, which SwiftData keys by entity name and Swift
# won't express — an attempt using a differently-named legacy model just writes rows of a different
# entity, finds nothing on reopen, and proves the opposite of what it claims.
#
# What this guards instead. A default flipped in the source is a one-token change with a silent,
# catastrophic effect: `includePhotos = false` would make EVERY album that existed before #273 come back
# reviewing videos only — the user opens a year of hand-picked work and finds it empty. The review that
# prompted this script proved the existing "guard" could not catch it: flipping that token passed all
# 331 tests, because the test exercised `ProjectStore.create`'s parameter default rather than the stored
# one. This is a placeholder for a real test, not a substitute — it catches the edit, not the behaviour.
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
    "includePhotos=true|every pre-#273 album would migrate to VIDEOS-ONLY and look empty (#273)"
    "includeVideos=false|every pre-#125 album would silently start including videos (#125)"
    "locationEnabled=true|every pre-#130 album would lose trip/place grouping (#130)"
)

for entry in "${EXPECTED[@]}"; do
    spec="${entry%%|*}"
    consequence="${entry##*|}"
    prop="${spec%%=*}"
    want="${spec##*=}"

    # The stored declaration, e.g. `var includePhotos: Bool = true` (ignores computed vars, which have
    # no `=` initializer, and the `MediaSelection` accessors of the same name).
    line="$(grep -E "^[[:space:]]*var ${prop}: Bool = " "${MODEL}" || true)"
    [ -n "${line}" ] || fail "CurationProject.${prop} is no longer a stored Bool with a default — migration backfill is undefined. ${consequence}"

    got="$(echo "${line}" | sed -E 's/.*= *([a-z]+).*/\1/')"
    [ "${got}" = "${want}" ] || fail "CurationProject.${prop} defaults to '${got}', expected '${want}' — ${consequence}. If this change is deliberate, verify the upgrade on device (install over a prior build) and update this guard."
done

echo "OK: migration-backfill defaults unchanged (${#EXPECTED[@]} checked)."
